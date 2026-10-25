use super::*;

pub(super) struct ResponseBody {
    pub(super) reader: Box<dyn AsyncRead + Unpin + Send>,
    pub(super) small_http1: bool,
    pub(super) _permit: OwnedSemaphorePermit,
}

/// A pull-based media response. Read and progress callbacks run on the caller's
/// worker; JavaScript never executes inside the Tokio executor. Dropping this
/// response immediately releases its body and per-origin permit.
pub struct HttpStream {
    /// Response metadata. The body is delivered exclusively through `read`.
    pub response: HttpResponse,
    pub(super) body: Option<ResponseBody>,
    pub(super) service: Arc<NetworkService>,
    pub(super) _pool: Arc<Pool>,
    pub(super) generation: u64,
    pub(super) started: Instant,
    pub(super) last_progress: Instant,
    pub(super) timeout: Duration,
    pub(super) stall_timeout: Duration,
    pub(super) failure: Option<String>,
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

    /// Collect the rest of the body through `buffer`, returning `Ok(None)` as
    /// soon as it exceeds `limit` bytes. Each read requests at most one byte
    /// past the limit, so an oversized body is never buffered further. Read
    /// errors are returned unchanged for the caller to map.
    pub fn read_limited(
        &mut self,
        limit: usize,
        buffer: &mut [u8],
        check: impl Fn() -> Result<(), String>,
    ) -> Result<Option<Vec<u8>>, String> {
        let mut body = Vec::new();
        loop {
            let capacity = buffer.len().min(limit + 1 - body.len());
            let count = self.read(&mut buffer[..capacity], &check)?;
            if count == 0 {
                return Ok(Some(body));
            }
            body.extend_from_slice(&buffer[..count]);
            if body.len() > limit {
                return Ok(None);
            }
        }
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
