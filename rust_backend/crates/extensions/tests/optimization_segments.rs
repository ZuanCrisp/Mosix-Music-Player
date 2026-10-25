#![cfg(unix)]

use serde_json::{Value, json};
use spotiflac_core::cancellation::{CancellationDomain, CancellationError, CancellationRegistry};
use spotiflac_extensions::environment::ExtensionEnvironment;
use spotiflac_extensions::{ExtensionError, RuntimeLimits};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

const SEGMENTS: usize = 2048;
const WINDOW: usize = 4;
static SERIAL: Mutex<()> = Mutex::new(());

struct Server {
    base: String,
    arrivals: mpsc::Receiver<usize>,
    closed: mpsc::Receiver<()>,
    control: mpsc::Sender<bool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Server {
    fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let (sent, arrivals) = mpsc::channel();
        let (close, closed) = mpsc::channel();
        let (control, commands) = mpsc::channel();
        let worker = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(20);
            let mut held: Option<TcpStream> = None;
            let mut requests = 0;
            while Instant::now() < deadline {
                match commands.try_recv() {
                    Ok(true) => {
                        let mut stream = held.take().expect("segment zero is held");
                        stream.set_nonblocking(false).unwrap();
                        stream.write_all(&[0; 3]).unwrap();
                    }
                    Ok(false) | Err(mpsc::TryRecvError::Disconnected) => break,
                    Err(mpsc::TryRecvError::Empty) => {}
                }
                if let Some(stream) = &mut held {
                    match stream.read(&mut [0]) {
                        Ok(0) => {
                            held.take();
                            let _ = close.send(());
                        }
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::ConnectionReset
                                    | std::io::ErrorKind::ConnectionAborted
                            ) =>
                        {
                            held.take();
                            let _ = close.send(());
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                        result => panic!("unexpected held segment read: {result:?}"),
                    }
                }
                let (mut stream, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if requests == SEGMENTS && held.is_none() {
                            break;
                        }
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("accept failed: {error}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut request = Vec::new();
                while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                    let mut bytes = [0; 1024];
                    let count = stream.read(&mut bytes).unwrap();
                    assert!(count > 0 && request.len() + count <= 8192);
                    request.extend_from_slice(&bytes[..count]);
                }
                let index: usize = std::str::from_utf8(&request)
                    .unwrap()
                    .split_whitespace()
                    .nth(1)
                    .unwrap()
                    .trim_start_matches('/')
                    .parse()
                    .unwrap();
                assert!(index < SEGMENTS);
                stream
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n")
                    .unwrap();
                if index == 0 {
                    stream.write_all(&[0]).unwrap();
                    stream.set_nonblocking(true).unwrap();
                    held = Some(stream);
                } else {
                    stream.write_all(&(index as u32).to_be_bytes()).unwrap();
                }
                requests += 1;
                if sent.send(index).is_err() {
                    break;
                }
            }
        });
        Self {
            base,
            arrivals,
            closed,
            control,
            worker: Some(worker),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.control.send(false);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn stalled_window(cancel: bool) {
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
    let manifest = json!({"name":"example.segments","version":"1","description":"Generic segment fixture",
        "type":["download_provider"],"permissions":{"file":true,"network":["127.0.0.1"],"allowHttp":true}}).to_string();
    let runtime = environment
        .load(
            &manifest,
            r#"registerExtension({run(base,count,parallel){
        return file.downloadSegments(Array.from({length:count},(_,index)=>base+'/'+index),
            'result.bin',{maxParallel:parallel,maxAttempts:1});
    }});"#,
            RuntimeLimits::default(),
        )
        .unwrap();
    let root = directory.path().join("example.segments");
    let target = root.join("result.bin");
    fs::write(&target, b"original").unwrap();
    let descriptors = fs::read_dir("/dev/fd").unwrap().count();
    let registry = CancellationRegistry::new(CancellationDomain::Download);
    let lease = std::sync::Arc::new(registry.acquire("window").unwrap());
    let arguments = json!([server.base, SEGMENTS, WINDOW]).to_string();
    let (done, result) = mpsc::channel();
    let worker = thread::spawn(move || {
        let value = runtime.call_download("run", &arguments, Some(lease), 10_000);
        let _ = done.send(value);
    });
    let mut initial = Vec::new();
    for _ in 0..WINDOW {
        initial.push(
            server
                .arrivals
                .recv_timeout(Duration::from_secs(5))
                .unwrap(),
        );
    }
    initial.sort_unstable();
    assert_eq!(initial, (0..WINDOW).collect::<Vec<_>>());
    assert_eq!(
        server.arrivals.recv_timeout(Duration::from_millis(150)),
        Err(mpsc::RecvTimeoutError::Timeout)
    );
    let staged = fs::read_dir(&root)
        .unwrap()
        .filter(|entry| {
            entry
                .as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".segment.")
        })
        .count();
    assert_eq!(
        staged, WINDOW,
        "active and completed segment files share the window"
    );
    assert!(
        fs::read_dir("/dev/fd").unwrap().count() <= descriptors + WINDOW * 4 + 16,
        "open descriptors must depend on the window, not the segment count"
    );
    if cancel {
        registry.cancel("window").unwrap();
    } else {
        server.control.send(true).unwrap();
    }
    let outcome = result.recv_timeout(Duration::from_secs(15)).unwrap();
    worker.join().unwrap();
    if cancel {
        assert_eq!(
            outcome,
            Err(ExtensionError::Cancelled(
                CancellationError::DownloadCancelled
            ))
        );
        server.closed.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"original");
        assert!(matches!(
            server.arrivals.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
    } else {
        let value: Value = serde_json::from_str(&outcome.unwrap()).unwrap();
        assert_eq!(value["success"], true);
        let expected: Vec<_> = (0..SEGMENTS as u32).flat_map(u32::to_be_bytes).collect();
        assert_eq!(fs::read(&target).unwrap(), expected);
        let mut remaining: Vec<_> = (WINDOW..SEGMENTS)
            .map(|_| {
                server
                    .arrivals
                    .recv_timeout(Duration::from_secs(2))
                    .unwrap()
            })
            .collect();
        remaining.sort_unstable();
        assert_eq!(remaining, (WINDOW..SEGMENTS).collect::<Vec<_>>());
    }
    assert!(fs::read_dir(&root).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".partial")
    }));
    environment.shutdown();
}

#[test]
fn stalled_first_segment_bounds_files_and_requests_then_assembles_in_order() {
    stalled_window(false);
}

#[test]
fn cancellation_of_stalled_segment_window_joins_workers_and_preserves_output() {
    stalled_window(true);
}
