use crate::cookies::CookieJar;
use crate::dns::{Dns, Lookup, Resolver, SystemLookup};
use crate::policy::{NetworkPermissions, private_literal_or_local};
use crate::url::UrlParts;
use async_compression::tokio::bufread::GzipDecoder;
use bytes::Bytes;
use futures_util::{TryStreamExt, future::BoxFuture};
use http::{HeaderMap, HeaderName, HeaderValue, Method, Request, Uri, header};
use http_body_util::{BodyExt, Full};
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::{Client, connect::HttpConnector};
use hyper_util::rt::{TokioExecutor, TokioTimer};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::task::{Context, Poll, Wake, Waker};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, BufReader};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};
use tokio_util::io::StreamReader;
use tower_service::Service;

pub const MAX_RESPONSE_BYTES: usize = 16 << 20;
type Transport = HttpsConnector<HttpConnector<Resolver>>;
type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone)]
struct Connector(Transport);

impl Service<Uri> for Connector {
    type Response = <Transport as Service<Uri>>::Response;
    type Error = BoxError;
    type Future = BoxFuture<'static, Result<Self::Response, BoxError>>;

    fn poll_ready(&mut self, context: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.0.poll_ready(context)
    }

    fn call(&mut self, uri: Uri) -> Self::Future {
        let future = self.0.call(uri);
        Box::pin(async move {
            tokio::time::timeout(Duration::from_secs(10), future)
                .await
                .map_err(|_| {
                    BoxError::from(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "connection timeout",
                    ))
                })?
        })
    }
}

struct Pool {
    client: Client<Connector, Full<Bytes>>,
    allow_private: bool,
    allow_http_fallback: bool,
    permits: Mutex<HashMap<String, Weak<Semaphore>>>,
}

impl Pool {
    fn new(
        tls: rustls::ClientConfig,
        dns: Arc<Dns>,
        allow_private: bool,
        allow_http_fallback: bool,
    ) -> Self {
        let mut http = HttpConnector::new_with_resolver(Resolver { dns, allow_private });
        http.enforce_http(false);
        http.set_connect_timeout(Some(Duration::from_secs(10)));
        http.set_happy_eyeballs_timeout(Some(Duration::from_millis(300)));
        http.set_keepalive(Some(Duration::from_secs(30)));
        // Go's dialer default: small request/control writes are not held back
        // by Nagle while waiting for a delayed ACK.
        http.set_nodelay(true);
        let connector = HttpsConnectorBuilder::new()
            .with_tls_config(tls)
            .https_or_http()
            .enable_http1()
            .enable_http2()
            .wrap_connector(http);
        let client = Client::builder(TokioExecutor::new())
            .pool_timer(TokioTimer::new())
            .pool_idle_timeout(Duration::from_secs(60))
            .pool_max_idle_per_host(10)
            .http1_max_buf_size(10 << 20)
            // Go's 4 MiB per-stream window doubles one stream's ceiling per
            // RTT. The 5 MiB connection window, and so peak buffering per
            // connection, stays hyper's default.
            .http2_initial_stream_window_size(4 << 20)
            .build(Connector(connector));
        Self {
            client,
            allow_private,
            allow_http_fallback,
            permits: Mutex::default(),
        }
    }

    async fn acquire(&self, uri: &Uri) -> OwnedSemaphorePermit {
        let key = format!(
            "{}://{}",
            uri.scheme_str().unwrap_or(""),
            uri.authority().map_or("", |authority| authority.as_str())
        );
        let semaphore = {
            let mut permits = self.permits.lock().expect("HTTP connection limit lock");
            if permits.len() > 256 {
                permits.retain(|_, semaphore| semaphore.strong_count() > 0);
            }
            match permits.get(&key).and_then(Weak::upgrade) {
                Some(semaphore) => semaphore,
                None => {
                    let semaphore = Arc::new(Semaphore::new(20));
                    permits.insert(key, Arc::downgrade(&semaphore));
                    semaphore
                }
            }
        };
        semaphore
            .acquire_owned()
            .await
            .expect("HTTP semaphore is never closed")
    }
}

/// These options belong to the native backend, never to extension JavaScript.
pub struct NetworkOptions {
    pub extra_root_pem: Vec<u8>,
    pub lookup: Arc<dyn Lookup>,
    pub doh_upstreams: Vec<String>,
}

impl Default for NetworkOptions {
    fn default() -> Self {
        Self {
            extra_root_pem: Vec::new(),
            lookup: Arc::new(SystemLookup),
            doh_upstreams: vec![
                "https://1.1.1.1/dns-query".into(),
                "https://8.8.8.8/dns-query".into(),
            ],
        }
    }
}

/// A shared pool and resolver with bounded executor threads. Sessions isolate
/// cookies and permissions while reusing TCP/TLS connections across extensions.
pub struct NetworkService {
    runtime: Option<Runtime>,
    tls: rustls::ClientConfig,
    dns: Arc<Dns>,
    pool: Mutex<Arc<Pool>>,
    generation: AtomicU64,
    checks: Arc<CheckWake>,
}

#[derive(Default)]
struct CheckWake(Notify);

impl Wake for CheckWake {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.notify_waiters();
    }
}

impl NetworkService {
    fn run<T>(
        &self,
        generation: u64,
        timeout: Duration,
        check: impl Fn() -> Result<(), String>,
        operation: impl Future<Output = Result<T, String>>,
    ) -> Result<T, String> {
        check()?;
        if tokio::runtime::Handle::try_current().is_ok() {
            return Err("blocking HTTP host called from async executor".into());
        }
        self.runtime
            .as_ref()
            .expect("network runtime")
            .block_on(async {
                tokio::pin!(operation);
                let timeout = tokio::time::sleep(timeout);
                tokio::pin!(timeout);
                // The first check runs below; an immediate first tick would
                // only repeat it before the operation is polled.
                let period = Duration::from_millis(10);
                let mut heartbeat =
                    tokio::time::interval_at(tokio::time::Instant::now() + period, period);
                loop {
                    // Create before checking: notify_waiters also reaches a Notified
                    // future that has not been polled yet, closing the lost-wake gap.
                    let changed = self.checks.0.notified();
                    check()?;
                    if self.generation.load(Ordering::Acquire) != generation {
                        return Err("network policy changed".into());
                    }
                    tokio::select! {
                        biased;
                        _ = changed => {}
                        _ = heartbeat.tick() => {}
                        _ = &mut timeout => return Err("HTTP request timeout exceeded".into()),
                        result = &mut operation => { check()?; return result; }
                    }
                }
            })
    }

    /// Recheck active HTTP calls when the owner's cancellation state changes.
    /// Waking does not itself cancel anything or retain the network runtime.
    pub fn cancellation_waker(&self) -> Waker {
        Waker::from(Arc::clone(&self.checks))
    }

    pub fn new() -> io::Result<Arc<Self>> {
        Self::with_options(NetworkOptions::default())
    }

    pub fn with_options(options: NetworkOptions) -> io::Result<Arc<Self>> {
        let roots = rustls_pemfile::certs(&mut options.extra_root_pem.as_slice())
            .collect::<Result<Vec<_>, _>>()?;
        if !options.extra_root_pem.is_empty() && roots.is_empty() {
            return Err(io::Error::other("no certificates in extra root PEM"));
        }
        let tls = crate::tls::configuration(&roots)?;
        let runtime = Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(16)
            .thread_name("extension-network")
            .enable_all()
            .build()?;
        let (dns, pool) = {
            let _entered = runtime.enter();
            let dns = Arc::new(Dns::new(
                tls.clone(),
                options.lookup,
                &options.doh_upstreams,
            )?);
            let pool = Arc::new(Pool::new(tls.clone(), Arc::clone(&dns), false, false));
            (dns, pool)
        };
        Ok(Arc::new(Self {
            runtime: Some(runtime),
            tls,
            dns,
            pool: Mutex::new(pool),
            generation: AtomicU64::new(0),
            checks: Arc::default(),
        }))
    }

    /// Called only for the app's explicit private-network preference. Replacing
    /// the pool prevents old private connections surviving a policy change.
    pub fn set_allow_private_network(&self, allow: bool) {
        let mut pool = self.pool.lock().expect("HTTP pool lock");
        if pool.allow_private == allow {
            return;
        }
        let _entered = self.runtime.as_ref().expect("network runtime").enter();
        *pool = Arc::new(Pool::new(
            self.tls.clone(),
            Arc::clone(&self.dns),
            allow,
            pool.allow_http_fallback,
        ));
        self.generation.fetch_add(1, Ordering::AcqRel);
        drop(pool);
        self.checks.0.notify_waiters();
    }

    /// Native compatibility requests may retry HTTPS over HTTP. Extension
    /// sessions retain their manifest policy. TLS verification is never disabled.
    pub fn set_network_compatibility_options(&self, allow_http: bool, _insecure_tls: bool) {
        let mut pool = self.pool.lock().expect("HTTP pool lock");
        if pool.allow_http_fallback == allow_http {
            return;
        }
        let _entered = self.runtime.as_ref().expect("network runtime").enter();
        *pool = Arc::new(Pool::new(
            self.tls.clone(),
            Arc::clone(&self.dns),
            pool.allow_private,
            allow_http,
        ));
        // As with Go's transport update, active requests retain their options.
        // In particular this must not cancel unrelated extension downloads.
    }

    pub fn reset_connections(&self) {
        let mut pool = self.pool.lock().expect("HTTP pool lock");
        let _entered = self.runtime.as_ref().expect("network runtime").enter();
        *pool = Arc::new(Pool::new(
            self.tls.clone(),
            Arc::clone(&self.dns),
            pool.allow_private,
            pool.allow_http_fallback,
        ));
        // Existing requests retain their pool; a reconnect is not a policy
        // change and must not cancel unrelated in-flight downloads.
    }

    pub fn session(
        self: &Arc<Self>,
        permissions: NetworkPermissions,
        timeout: Duration,
    ) -> Arc<NetworkSession> {
        Arc::new(NetworkSession {
            service: Arc::clone(self),
            permissions: Some(permissions),
            native_media: false,
            follow_redirects: true,
            timeout,
            cookies: Mutex::default(),
        })
    }

    /// App-owned HTTPS requests, such as the extension registry. This is never
    /// exposed to JavaScript; extension sessions always retain their allowlist.
    pub fn native_session(self: &Arc<Self>, timeout: Duration) -> Arc<NetworkSession> {
        Arc::new(NetworkSession {
            service: Arc::clone(self),
            permissions: None,
            native_media: false,
            follow_redirects: true,
            timeout,
            cookies: Mutex::default(),
        })
    }

    /// Provider artwork uses explicit HTTP or HTTPS URLs and no cookie jar,
    /// matching the native media client. DNS/private-network policy and the
    /// connection pool are still shared. Never exposed to extension JavaScript.
    pub fn native_media_session(self: &Arc<Self>, timeout: Duration) -> Arc<NetworkSession> {
        Arc::new(NetworkSession {
            service: Arc::clone(self),
            permissions: None,
            native_media: true,
            follow_redirects: true,
            timeout,
            cookies: Mutex::default(),
        })
    }
}

impl Drop for NetworkService {
    fn drop(&mut self) {
        // libc DNS calls cannot be interrupted. Futures are cancelled promptly;
        // do not make native teardown wait for a stalled OS resolver thread.
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct HttpRequest {
    pub url: String,
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub default_json: bool,
    #[serde(default = "default_user_agent")]
    pub user_agent: String,
}

fn default_user_agent() -> String {
    "Spotiflac-Extension/1.0".to_owned()
}

#[derive(Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub status_text: String,
    pub url: String,
    pub headers: BTreeMap<String, Vec<String>>,
    pub body: Vec<u8>,
}

struct ResponseBody {
    reader: Box<dyn AsyncRead + Unpin + Send>,
    small_http1: bool,
    _permit: OwnedSemaphorePermit,
}

/// A pull-based media response. Read and progress callbacks run on the caller's
/// worker; JavaScript never executes inside the Tokio executor. Dropping this
/// response immediately releases its body and per-origin permit.
pub struct HttpStream {
    /// Response metadata. The body is delivered exclusively through `read`.
    pub response: HttpResponse,
    body: Option<ResponseBody>,
    service: Arc<NetworkService>,
    _pool: Arc<Pool>,
    generation: u64,
    started: Instant,
    last_progress: Instant,
    timeout: Duration,
    stall_timeout: Duration,
    failure: Option<String>,
}

impl HttpStream {
    /// Read at most 64 KiB without collecting the response in memory. Errors
    /// close the stream so callers cannot accidentally resume a failed reader.
    pub fn read(
        &mut self,
        buffer: &mut [u8],
        check: impl Fn() -> Result<(), String>,
    ) -> Result<usize, String> {
        if let Some(error) = &self.failure {
            return Err(error.clone());
        }
        let result = (|| {
            check()?;
            if self.service.generation.load(Ordering::Acquire) != self.generation {
                return Err("network policy changed".into());
            }
            let Some(body) = self.body.as_mut() else {
                return Ok(0);
            };
            if buffer.is_empty() {
                return Ok(0);
            }
            let total = self.timeout.saturating_sub(self.started.elapsed());
            let idle = self
                .stall_timeout
                .saturating_sub(self.last_progress.elapsed());
            if total.is_zero() {
                return Err("HTTP request timeout exceeded".into());
            }
            if idle.is_zero() {
                return Err(self.stall_message());
            }
            let size = buffer.len().min(64 << 10);
            let count = self
                .service
                .run(self.generation, total.min(idle), &check, async {
                    body.reader
                        .read(&mut buffer[..size])
                        .await
                        .map_err(|error| error.to_string())
                })
                .map_err(|error| {
                    if error == "HTTP request timeout exceeded" && idle <= total {
                        self.stall_message()
                    } else {
                        error
                    }
                })?;
            if count > 0 {
                self.last_progress = Instant::now();
            }
            Ok(count)
        })();
        match &result {
            Err(error) => {
                self.body = None;
                self.failure = Some(error.clone());
            }
            Ok(0) if !buffer.is_empty() => self.body = None,
            _ => {}
        }
        result
    }

    /// Release an unwanted body (a range probe or retryable error). A small
    /// HTTP/1.1 body is finished within 20 ms so its connection can return to
    /// the pool; HTTP/2, compressed, large or slow bodies are dropped at once.
    pub fn discard(&mut self, check: impl Fn() -> Result<(), String>) {
        let Some(mut body) = self.body.take() else {
            return;
        };
        if !body.small_http1 || self.failure.is_some() {
            return;
        }
        let _ = self
            .service
            .run(self.generation, Duration::from_millis(20), &check, async {
                let mut buffer = [0; 2048];
                let mut received = 0;
                loop {
                    let count = body
                        .reader
                        .read(&mut buffer)
                        .await
                        .map_err(|error| error.to_string())?;
                    received += count;
                    if count == 0 || received > 2048 {
                        return Ok(());
                    }
                }
            });
    }

    fn stall_message(&self) -> String {
        format!(
            "download stalled: no data received for {}s (network timeout)",
            self.stall_timeout.as_secs()
        )
    }
}

pub struct NetworkSession {
    service: Arc<NetworkService>,
    permissions: Option<NetworkPermissions>,
    native_media: bool,
    follow_redirects: bool,
    timeout: Duration,
    cookies: Mutex<CookieJar>,
}

impl NetworkSession {
    /// Account-owned media must not carry metadata cookies or follow a redirect
    /// outside its descriptor. Keep the original manifest/DNS/TLS permissions.
    pub fn direct_media(&self) -> Self {
        Self {
            service: Arc::clone(&self.service),
            permissions: self.permissions.clone(),
            native_media: true,
            follow_redirects: false,
            timeout: self.timeout,
            cookies: Mutex::default(),
        }
    }

    pub fn reset_connections(&self) {
        self.service.reset_connections();
    }

    /// Browser authorization endpoints need HTTPS and private-address checks,
    /// but may use an identity provider outside the extension API allowlist.
    pub fn validate_auth_url(
        &self,
        input: &str,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<UrlParts, String> {
        check()?;
        let url = UrlParts::parse(input).ok_or_else(|| "invalid auth URL".to_owned())?;
        if url.scheme != "https" {
            return Err("invalid auth URL: only https is allowed".into());
        }
        if url.hostname.is_empty() {
            return Err("invalid auth URL: hostname is required".into());
        }
        if url.has_credentials {
            return Err("invalid auth URL: embedded credentials are not allowed".into());
        }
        let (allow, generation) = {
            let pool = self.service.pool.lock().expect("HTTP pool lock");
            (
                pool.allow_private,
                self.service.generation.load(Ordering::Acquire),
            )
        };
        if !allow {
            let uri = url.request_uri()?;
            let private = private_literal_or_local(&url.hostname)
                || uri.host().is_some_and(private_literal_or_local);
            let private = private
                || self.service.run(generation, self.timeout, check, async {
                    Ok(self.service.dns.has_private_address(&url.hostname).await)
                })?;
            if private {
                return Err("invalid auth URL: private/local network is not allowed".into());
            }
        }
        Ok(url)
    }

    pub fn clear_cookies(&self) {
        self.cookies.lock().expect("cookie jar lock").clear();
    }

    pub fn validate_url(&self, url: &str) -> Result<(), String> {
        let allow = self
            .service
            .pool
            .lock()
            .expect("HTTP pool lock")
            .allow_private;
        self.validate_target(url, allow, false).map(|_| ())
    }

    fn validate_target(
        &self,
        input: &str,
        allow_private: bool,
        redirect: bool,
    ) -> Result<UrlParts, String> {
        if let Some(permissions) = &self.permissions {
            return permissions.validate(input, allow_private, redirect);
        }
        let url = UrlParts::parse(input).ok_or_else(|| "invalid URL".to_owned())?;
        NetworkPermissions {
            domains: vec![url.hostname],
            allow_http: self.native_media,
        }
        .validate(input, allow_private, redirect)
    }

    /// Blocking host call, run from the dedicated JS worker or a native worker.
    /// The heartbeat observes cancellation while DNS, TLS, headers or body wait.
    pub fn request(
        &self,
        request: HttpRequest,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<HttpResponse, String> {
        check()?;
        if tokio::runtime::Handle::try_current().is_ok() {
            return Err("blocking HTTP host called from async executor".into());
        }
        let (pool, generation) = {
            let pool = self.service.pool.lock().expect("HTTP pool lock");
            (
                Arc::clone(&pool),
                self.service.generation.load(Ordering::Acquire),
            )
        };
        self.service.run(
            generation,
            self.timeout,
            check,
            self.execute(request, &pool),
        )
    }

    /// Streaming downloads share DNS, TLS, cookies, redirects and connection
    /// limits with API requests, but preserve identity content encoding and use
    /// the native transfer's wall-clock/stall limits rather than API timeout.
    pub fn open_stream(
        &self,
        request: HttpRequest,
        timeout: Duration,
        stall_timeout: Duration,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<HttpStream, String> {
        self.open_stream_with_encoding(request, timeout, stall_timeout, false, &check)
    }

    /// API-style gzip decoding with pull-based reads. The caller enforces its
    /// own decoded-body size limit without raising the buffered API limit.
    pub fn open_response_stream(
        &self,
        request: HttpRequest,
        check: impl Fn() -> Result<(), String>,
    ) -> Result<HttpStream, String> {
        self.open_stream_with_encoding(request, self.timeout, self.timeout, true, &check)
    }

    fn open_stream_with_encoding(
        &self,
        request: HttpRequest,
        timeout: Duration,
        stall_timeout: Duration,
        compression: bool,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<HttpStream, String> {
        let started = Instant::now();
        let (pool, generation) = {
            let pool = self.service.pool.lock().expect("HTTP pool lock");
            (
                Arc::clone(&pool),
                self.service.generation.load(Ordering::Acquire),
            )
        };
        let (response, body) = self.service.run(
            generation,
            timeout.min(stall_timeout),
            check,
            self.execute_stream(request, &pool, compression),
        )?;
        Ok(HttpStream {
            response,
            body: Some(body),
            service: Arc::clone(&self.service),
            _pool: pool,
            generation,
            started,
            last_progress: started,
            timeout,
            stall_timeout,
            failure: None,
        })
    }

    async fn execute(&self, request: HttpRequest, pool: &Pool) -> Result<HttpResponse, String> {
        let (mut response, body) = self.execute_stream(request, pool, true).await?;
        body.reader
            .take((MAX_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut response.body)
            .await
            .map_err(|error| error.to_string())?;
        if response.body.len() > MAX_RESPONSE_BYTES {
            return Err(format!(
                "response body exceeds {MAX_RESPONSE_BYTES} byte limit; use file.download for large media"
            ));
        }
        Ok(response)
    }

    async fn execute_stream(
        &self,
        request: HttpRequest,
        pool: &Pool,
        compression: bool,
    ) -> Result<(HttpResponse, ResponseBody), String> {
        let mut url = self.validate_target(&request.url, pool.allow_private, false)?;
        let original = url.clone();
        let mut method = Method::from_bytes(if request.method.is_empty() {
            b"GET"
        } else {
            request.method.as_bytes()
        })
        .map_err(|_| format!("net/http: invalid method {:?}", request.method))?;
        let mut body = Bytes::from(request.body);
        let mut headers = HeaderMap::new();
        for (name, value) in request.headers {
            let name =
                HeaderName::from_bytes(name.as_bytes()).map_err(|error| error.to_string())?;
            if name == header::HOST
                || name == header::CONTENT_LENGTH
                || name == header::TRANSFER_ENCODING
            {
                continue;
            }
            headers.insert(
                name,
                HeaderValue::from_str(&value).map_err(|error| error.to_string())?,
            );
        }
        if headers
            .get(header::USER_AGENT)
            .is_none_or(|value| value.is_empty())
        {
            headers.insert(
                header::USER_AGENT,
                request
                    .user_agent
                    .parse()
                    .map_err(|error: http::header::InvalidHeaderValue| error.to_string())?,
            );
        }
        if request.default_json
            && headers
                .get(header::CONTENT_TYPE)
                .is_none_or(|value| value.is_empty())
        {
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/json"),
            );
        }
        let explicit_referer = headers
            .get(header::REFERER)
            .filter(|value| !value.is_empty())
            .cloned();
        for redirects in 0..10 {
            let uri = url.request_uri()?;
            let mut permit = pool.acquire(&uri).await;
            let mut outgoing = headers.clone();
            let cookies = if self.native_media {
                String::new()
            } else {
                self.cookies.lock().expect("cookie jar lock").header(&url)
            };
            if !cookies.is_empty() {
                let value = outgoing
                    .get(header::COOKIE)
                    .and_then(|value| value.to_str().ok())
                    .filter(|value| !value.is_empty())
                    .map_or_else(|| cookies.clone(), |value| format!("{value}; {cookies}"));
                outgoing.insert(
                    header::COOKIE,
                    value
                        .parse()
                        .map_err(|error: http::header::InvalidHeaderValue| error.to_string())?,
                );
            }
            let gzip = compression
                && outgoing
                    .get(header::ACCEPT_ENCODING)
                    .is_none_or(|value| value.is_empty())
                && outgoing
                    .get(header::RANGE)
                    .is_none_or(|value| value.is_empty())
                && method != Method::HEAD;
            if gzip {
                outgoing.insert(header::ACCEPT_ENCODING, HeaderValue::from_static("gzip"));
            }
            let mut req = Request::builder()
                .method(method.clone())
                .uri(uri)
                .body(Full::new(body.clone()))
                .map_err(|error| error.to_string())?;
            *req.headers_mut() = outgoing.clone();
            let response = tokio::time::timeout(Duration::from_secs(45), pool.client.request(req))
                .await
                .map_err(|_| "HTTP response header timeout exceeded".to_owned())
                .and_then(|result| result.map_err(|error| error_chain(&error)));
            let mut response_url = url.clone();
            // Nonempty bodies are buffered and can be replayed, as Go's GetBody
            // permits. Treat an empty body like a nil Go request body.
            let can_replay = matches!(
                method,
                Method::GET | Method::HEAD | Method::OPTIONS | Method::DELETE
            ) || !body.is_empty();
            let response = match response {
                Err(_)
                    if pool.allow_http_fallback
                        && self.permissions.is_none()
                        && url.scheme == "https"
                        && can_replay =>
                {
                    response_url.scheme = "http".into();
                    let uri = response_url.request_uri()?;
                    // The hostname is unchanged; the shared connector still
                    // resolves and checks every destination against private-IP policy.
                    drop(permit);
                    permit = pool.acquire(&uri).await;
                    let mut retry = Request::builder()
                        .method(method.clone())
                        .uri(uri)
                        .body(Full::new(body.clone()))
                        .map_err(|error| error.to_string())?;
                    *retry.headers_mut() = outgoing;
                    tokio::time::timeout(Duration::from_secs(45), pool.client.request(retry))
                        .await
                        .map_err(|_| "HTTP response header timeout exceeded".to_owned())?
                        .map_err(|error| error_chain(&error))?
                }
                result => result?,
            };
            if !self.native_media {
                self.cookies
                    .lock()
                    .expect("cookie jar lock")
                    .store(&url, response.headers());
            }
            let status = response.status();
            if !self.follow_redirects && matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
                return Err("media redirect blocked: request a fresh descriptor".into());
            }
            if matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308)
                && let Some(location) = response
                    .headers()
                    .get(header::LOCATION)
                    .filter(|value| !value.is_empty())
            {
                let location = location.to_str().map_err(|error| error.to_string())?;
                let target = url
                    .resolve(location)
                    .ok_or_else(|| "invalid redirect URL".to_owned())?;
                if target.has_credentials {
                    return Err("invalid URL: embedded credentials are not allowed".into());
                }
                self.validate_target(&target.display_url(), pool.allow_private, true)?;
                if redirects < 9 {
                    update_explicit_cookies(&mut headers, response.headers());
                    if matches!(status.as_u16(), 301..=303) {
                        if method != Method::GET && method != Method::HEAD {
                            method = Method::GET;
                        }
                        body = Bytes::new();
                        for name in [
                            header::CONTENT_ENCODING,
                            header::CONTENT_LANGUAGE,
                            header::CONTENT_LOCATION,
                            header::CONTENT_TYPE,
                        ] {
                            headers.remove(name);
                        }
                    }
                    if !forward_sensitive_headers(&original.hostname, &target.hostname) {
                        for name in [
                            header::AUTHORIZATION,
                            header::WWW_AUTHENTICATE,
                            header::COOKIE,
                            header::PROXY_AUTHORIZATION,
                            header::PROXY_AUTHENTICATE,
                        ] {
                            headers.remove(name);
                        }
                        headers.remove("cookie2");
                    }
                    if url.scheme == "https" && target.scheme == "http" {
                        headers.remove(header::REFERER);
                    } else if let Some(value) = &explicit_referer {
                        headers.insert(header::REFERER, value.clone());
                    } else if let Ok(value) = url.display_url().parse() {
                        headers.insert(header::REFERER, value);
                    }
                    url = target;
                    // A small HTTP/1.1 redirect body can return this connection
                    // to the pool. Never wait for an unbounded/slow body or drain
                    // HTTP/2 streams, whose connections are already multiplexed.
                    if response.version() == http::Version::HTTP_11
                        && response
                            .headers()
                            .get(header::CONTENT_LENGTH)
                            .and_then(|value| value.to_str().ok())
                            .and_then(|value| value.parse::<usize>().ok())
                            .is_some_and(|length| length <= 2048)
                    {
                        let mut body = response.into_body();
                        let _ = tokio::time::timeout(Duration::from_millis(20), async {
                            let mut received = 0;
                            while let Some(Ok(frame)) = body.frame().await {
                                received += frame.data_ref().map_or(0, Bytes::len);
                                if received > 2048 {
                                    break;
                                }
                            }
                        })
                        .await;
                    }
                    continue;
                }
            }
            let mut response_headers = response.headers().clone();
            let decompress = gzip
                && response_headers
                    .get(header::CONTENT_ENCODING)
                    .is_some_and(|value| value.as_bytes().eq_ignore_ascii_case(b"gzip"));
            // Same bound as redirect bodies: only an uncompressed HTTP/1.1
            // body of at most 2 KiB may be finished by `HttpStream::discard`.
            let small_http1 = !decompress
                && response.version() == http::Version::HTTP_11
                && response_headers
                    .get(header::CONTENT_LENGTH)
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| value.parse::<usize>().ok())
                    .is_some_and(|length| length <= 2048);
            let stream = response
                .into_body()
                .into_data_stream()
                .map_err(io::Error::other);
            let reader = StreamReader::new(stream);
            let reader: Box<dyn AsyncRead + Unpin + Send> = if decompress {
                response_headers.remove(header::CONTENT_ENCODING);
                response_headers.remove(header::CONTENT_LENGTH);
                let mut decoder = GzipDecoder::new(BufReader::new(reader));
                decoder.multiple_members(true);
                Box::new(decoder)
            } else {
                Box::new(reader)
            };
            let mut headers = BTreeMap::new();
            for name in response_headers.keys() {
                headers.insert(
                    canonical_header(name.as_str()),
                    response_headers
                        .get_all(name)
                        .iter()
                        .map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned())
                        .collect(),
                );
            }
            return Ok((
                HttpResponse {
                    status: status.as_u16(),
                    status_text: status.canonical_reason().unwrap_or("").into(),
                    url: response_url.display_url(),
                    headers,
                    body: Vec::new(),
                },
                ResponseBody {
                    reader,
                    small_http1,
                    _permit: permit,
                },
            ));
        }
        unreachable!("last redirect returns its response")
    }
}

fn update_explicit_cookies(headers: &mut HeaderMap, response: &HeaderMap) {
    let Some(original) = headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
    else {
        return;
    };
    let names: Vec<_> = response
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .filter_map(|value| cookie::Cookie::parse(value).ok())
        .map(|cookie| cookie.name().to_owned())
        .collect();
    let mut changed = false;
    let mut remaining: Vec<_> = original
        .split(';')
        .map(str::trim)
        .filter(|pair| {
            let remove = pair
                .split_once('=')
                .is_some_and(|(name, _)| names.iter().any(|replaced| replaced == name));
            changed |= remove;
            !remove
        })
        .collect();
    if changed {
        remaining.sort_unstable();
        let value = remaining
            .join("; ")
            .parse()
            .expect("existing HTTP cookie header");
        headers.insert(header::COOKIE, value);
    }
}

fn forward_sensitive_headers(original: &str, target: &str) -> bool {
    let original = original.to_lowercase();
    let target = target.to_lowercase();
    original == target
        || (!target.contains([':', '%']) && target.ends_with(&format!(".{original}")))
}

fn canonical_header(name: &str) -> String {
    name.split('-')
        .map(|word| {
            let mut bytes = word.as_bytes().to_vec();
            if let Some(first) = bytes.first_mut() {
                first.make_ascii_uppercase();
            }
            String::from_utf8(bytes).expect("ASCII HTTP header name")
        })
        .collect::<Vec<_>>()
        .join("-")
}

fn error_chain(error: &dyn std::error::Error) -> String {
    let mut message = error.to_string();
    if let Some(source) = error.source() {
        message.push_str(": ");
        message.push_str(&error_chain(source));
    }
    message
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::poll_fn;
    use std::sync::{atomic::AtomicBool, mpsc};

    #[test]
    fn direct_media_keeps_manifest_permissions_and_https_requirement() {
        let service = NetworkService::new().unwrap();
        let original = service.session(
            NetworkPermissions {
                domains: vec!["cdn.example.test".into()],
                allow_http: false,
            },
            Duration::from_secs(30),
        );
        let media = original.direct_media();
        assert!(media.validate_url("https://cdn.example.test/audio").is_ok());
        assert!(
            media
                .validate_url("https://unlisted.example.test/audio")
                .is_err()
        );
        assert!(media.validate_url("http://cdn.example.test/audio").is_err());
        assert!(!media.follow_redirects);
        assert!(media.native_media);
    }

    #[test]
    fn direct_media_does_not_send_metadata_cookies_or_follow_redirects() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            for response in [
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                "HTTP/1.1 302 Found\r\nLocation: /unexpected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            ] {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                    assert!(request.len() < 8192);
                }
                assert!(
                    !String::from_utf8(request)
                        .unwrap()
                        .to_lowercase()
                        .contains("\r\ncookie:")
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let service = NetworkService::new().unwrap();
        service.set_allow_private_network(true);
        let original = service.session(
            NetworkPermissions {
                domains: vec!["127.0.0.1".into()],
                allow_http: true,
            },
            Duration::from_secs(3),
        );
        let mut cookies = http::HeaderMap::new();
        cookies.insert(
            http::header::SET_COOKIE,
            "metadata=private; Path=/".parse().unwrap(),
        );
        original
            .cookies
            .lock()
            .unwrap()
            .store(&UrlParts::parse(&base).unwrap(), &cookies);
        let media = original.direct_media();
        let request =
            || serde_json::from_value(serde_json::json!({"url":format!("{base}/media")})).unwrap();
        assert_eq!(media.request(request(), || Ok(())).unwrap().body, b"ok");
        assert!(
            media
                .request(request(), || Ok(()))
                .unwrap_err()
                .contains("media redirect blocked")
        );
        server.join().unwrap();
    }

    #[test]
    fn cancellation_after_operation_is_pending_drops_it_before_return() {
        struct Dropped<'a>(&'a AtomicBool);
        impl Drop for Dropped<'_> {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }

        let service = NetworkService::new().unwrap();
        // Sample two phases; timings are diagnostics, not shared-host limits.
        for (waiting_for, wake) in [
            (Duration::ZERO, false),
            (Duration::from_millis(15), false),
            (Duration::from_millis(15), true),
        ] {
            let cancelled = AtomicBool::new(false);
            let dropped = AtomicBool::new(false);
            let (waiting_tx, waiting_rx) = mpsc::sync_channel(1);
            let (finished_tx, finished_rx) = mpsc::sync_channel(1);
            std::thread::scope(|scope| {
                let worker = scope.spawn(|| {
                    let mut waiting = Some(waiting_tx);
                    let result = service.run(
                        0,
                        Duration::from_secs(2),
                        || {
                            if cancelled.load(Ordering::Acquire) {
                                Err("cancelled".into())
                            } else {
                                Ok(())
                            }
                        },
                        async {
                            let _dropped = Dropped(&dropped);
                            if !waiting_for.is_zero() {
                                tokio::time::sleep(waiting_for).await;
                            }
                            poll_fn(|_| {
                                if let Some(waiting) = waiting.take() {
                                    waiting.send(()).unwrap();
                                }
                                Poll::<Result<(), String>>::Pending
                            })
                            .await
                        },
                    );
                    finished_tx
                        .send((result, Instant::now(), dropped.load(Ordering::Acquire)))
                        .unwrap();
                });
                waiting_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                let began = Instant::now();
                cancelled.store(true, Ordering::Release);
                if wake {
                    service.cancellation_waker().wake();
                }
                let (result, returned, dropped_before_return) =
                    finished_rx.recv_timeout(Duration::from_secs(1)).unwrap();
                worker.join().unwrap();
                assert_eq!(result, Err("cancelled".into()));
                assert!(dropped_before_return);
                println!(
                    "pending operation cancellation (wait={}ms, wake={wake}): return={}us join={}us",
                    waiting_for.as_millis(),
                    returned.duration_since(began).as_micros(),
                    began.elapsed().as_micros(),
                );
            });
        }
        assert_eq!(
            service.run(0, Duration::from_secs(1), || Ok(()), async { Ok(7) }),
            Ok(7)
        );
    }
}
