use super::*;

#[derive(Clone)]
pub(super) struct Connector(Transport);

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

pub(super) struct Pool {
    pub(super) client: Client<Connector, Full<Bytes>>,
    pub(super) allow_private: bool,
    pub(super) allow_http_fallback: bool,
    permits: Mutex<HashMap<String, Weak<Semaphore>>>,
}

impl Pool {
    pub(super) fn new(
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

    pub(super) async fn acquire(&self, uri: &Uri) -> OwnedSemaphorePermit {
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
