#![cfg(unix)]
use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
use mornye_extensions::RuntimeLimits;
use mornye_extensions::environment::ExtensionEnvironment;
use serde_json::{Value, json};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const BODY: &[u8] = b"0123456789abcdefghij";
static SERIAL: Mutex<()> = Mutex::new(());

struct Server {
    base: String,
    connections: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

/// Writes headers and body separately, as proxies and CDNs commonly flush
/// them. The body is delayed well inside the 20 ms small-body drain bound.
fn respond(stream: &mut TcpStream, head: &str, body: &[u8]) -> std::io::Result<()> {
    stream.write_all(head.as_bytes())?;
    stream.flush()?;
    thread::sleep(Duration::from_millis(3));
    stream.write_all(body)
}

/// Serves byte ranges over keep-alive HTTP/1.1. `/busy` answers the first
/// ranged chunk (after the two-byte probe) with a small retryable 503 body.
fn connection(mut stream: TcpStream, stop: &AtomicBool, busy: &AtomicBool) {
    // Keep the fixture's 3 ms body delay independent of Nagle/delayed ACK,
    // which can exceed the client's bounded drain on Linux runners.
    stream.set_nodelay(true).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_millis(25)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut request = Vec::new();
    while Instant::now() < deadline && !stop.load(Ordering::Acquire) {
        let mut bytes = [0; 1024];
        match stream.read(&mut bytes) {
            Ok(0) => break,
            Ok(count) => request.extend_from_slice(&bytes[..count]),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(_) => break,
        }
        assert!(request.len() <= 8192);
        if !request.windows(4).any(|part| part == b"\r\n\r\n") {
            continue;
        }
        let text = String::from_utf8(std::mem::take(&mut request)).unwrap();
        let path = text.split_whitespace().nth(1).unwrap().to_owned();
        let range = text
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("range")
                    .then(|| value.trim().trim_start_matches("bytes=").to_owned())
            })
            .expect("chunked requests carry a range");
        let (start, end) = range.split_once('-').unwrap();
        let start: usize = start.parse().unwrap();
        let end = end.parse::<usize>().unwrap().min(BODY.len() - 1);
        let result = if path == "/busy"
            && start == 0
            && end > 1
            && busy.swap(false, Ordering::AcqRel)
        {
            respond(
                &mut stream,
                "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\n",
                b"busy",
            )
        } else {
            let part = &BODY[start..=end];
            respond(
                &mut stream,
                &format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
                    BODY.len(),
                    part.len()
                ),
                part,
            )
        };
        if result.is_err() {
            break;
        }
    }
}

impl Server {
    fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let connections = Arc::new(AtomicUsize::new(0));
        let count = connections.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let busy = Arc::new(AtomicBool::new(true));
        let worker = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut workers = Vec::new();
            while Instant::now() < deadline && !stopped.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        count.fetch_add(1, Ordering::AcqRel);
                        let (stopped, busy) = (stopped.clone(), busy.clone());
                        workers.push(thread::spawn(move || connection(stream, &stopped, &busy)));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("chunked fixture accept: {error}"),
                }
            }
            stopped.store(true, Ordering::Release);
            for worker in workers {
                worker.join().unwrap();
            }
        });
        Self {
            base,
            connections,
            stop,
            worker: Some(worker),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn download(route: &str) -> (Value, Vec<u8>, usize) {
    let _serial = SERIAL.lock().unwrap_or_else(|error| error.into_inner());
    let server = Server::new();
    let directory = tempfile::tempdir().unwrap();
    let environment = ExtensionEnvironment::new(
        directory.path(),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
    )
    .unwrap();
    environment.set_allow_private_network(true).unwrap();
    let manifest = json!({"name":"example.chunked","version":"1","description":"Generic chunked fixture",
        "type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true}}).to_string();
    let runtime = environment
        .load(
            &manifest,
            r#"registerExtension({run(url){
        return file.download(url, 'result.bin', {chunked: 8, maxAttempts: 2});
    }});"#,
            RuntimeLimits::default(),
        )
        .unwrap();
    let registry = CancellationRegistry::new(CancellationDomain::Download);
    let lease = Arc::new(registry.acquire("chunked").unwrap());
    let arguments = json!([format!("{}/{route}", server.base)]).to_string();
    let outcome = runtime
        .call_download("run", &arguments, Some(lease), 10_000)
        .unwrap();
    let written = fs::read(directory.path().join("example.chunked/result.bin")).unwrap_or_default();
    let connections = server.connections.load(Ordering::Acquire);
    environment.shutdown();
    (
        serde_json::from_str(&outcome).unwrap(),
        written,
        connections,
    )
}

#[test]
fn chunked_probe_and_ranges_share_one_keep_alive_connection() {
    let (value, written, connections) = download("plain");
    assert_eq!(value["success"], true, "{value}");
    assert_eq!(written, BODY);
    assert_eq!(connections, 1, "probe body must not discard its connection");
}

#[test]
fn small_retryable_error_body_keeps_connection_for_retry() {
    let (value, written, connections) = download("busy");
    assert_eq!(value["success"], true, "{value}");
    assert_eq!(written, BODY);
    assert_eq!(connections, 1, "503 body must not discard its connection");
}
