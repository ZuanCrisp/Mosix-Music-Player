use spotiflac_network::policy::NetworkPermissions;
use spotiflac_network::{HttpRequest, NetworkService};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

struct Server {
    base: String,
    connections: Arc<AtomicUsize>,
    redirected: mpsc::Receiver<()>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

fn pause(stop: &AtomicBool, duration: Duration) -> bool {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if stop.load(Ordering::Acquire) {
            return false;
        }
        thread::sleep(Duration::from_millis(2));
    }
    !stop.load(Ordering::Acquire)
}

fn connection(mut stream: TcpStream, stop: &AtomicBool, redirected: mpsc::Sender<()>) {
    stream
        .set_read_timeout(Some(Duration::from_millis(25)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
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
        let path = std::str::from_utf8(&request)
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .to_owned();
        request.clear();
        if path.starts_with("/final") {
            if path == "/final-cancel" && !pause(stop, Duration::from_secs(1)) {
                break;
            }
            if stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok",
                )
                .is_err()
            {
                break;
            }
            continue;
        }
        let final_path = if path == "/cancel" {
            "/final-cancel"
        } else {
            "/final"
        };
        let length = if path == "/huge" { 64 << 20 } else { 32 };
        if write!(stream, "HTTP/1.1 302 Found\r\nLocation: {final_path}\r\nContent-Length: {length}\r\nConnection: keep-alive\r\n\r\n").is_err() {
            break;
        }
        if path == "/short" {
            if stream.write_all(&[b'x'; 32]).is_err() {
                break;
            }
            let _ = redirected.send(());
            continue;
        }
        if stream.write_all(b"x").is_err() {
            break;
        }
        let _ = redirected.send(());
        if path == "/huge" {
            let _ = stream.write_all(&[b'x'; 65535]);
            pause(stop, Duration::from_secs(1));
            break;
        }
        let delay = if path == "/split" {
            Duration::from_millis(10)
        } else {
            Duration::from_secs(1)
        };
        if !pause(stop, delay) || stream.write_all(&[b'x'; 31]).is_err() {
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
        let (redirect, redirected) = mpsc::channel();
        let worker = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut workers = Vec::new();
            while Instant::now() < deadline && !stopped.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        assert!(count.fetch_add(1, Ordering::AcqRel) < 4);
                        let stopped = stopped.clone();
                        let redirect = redirect.clone();
                        workers.push(thread::spawn(move || {
                            connection(stream, &stopped, redirect)
                        }));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("redirect fixture accept: {error}"),
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
            redirected,
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

fn request(url: String) -> HttpRequest {
    serde_json::from_value(serde_json::json!({"url":url})).unwrap()
}

#[test]
fn redirect_bodies_report_connection_reuse_without_waiting_for_unbounded_bodies() {
    for route in ["short", "split", "delayed", "huge"] {
        let server = Server::new();
        let service = NetworkService::new().unwrap();
        service.set_allow_private_network(true);
        let session = service.session(
            NetworkPermissions {
                domains: vec!["127.0.0.1".into()],
                allow_http: true,
            },
            Duration::from_secs(3),
        );
        let began = Instant::now();
        let response = session
            .request(request(format!("{}/{route}", server.base)), || Ok(()))
            .unwrap();
        let elapsed = began.elapsed();
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"ok");
        let connections = server.connections.load(Ordering::Acquire);
        assert_eq!(
            connections,
            if matches!(route, "short" | "split") {
                1
            } else {
                2
            },
            "{route}"
        );
        eprintln!(
            "redirect route={route} connections={connections} elapsed_us={}",
            elapsed.as_micros()
        );
        if matches!(route, "delayed" | "huge") {
            assert!(
                elapsed < Duration::from_millis(750),
                "{route} waited for an unnecessary redirect body: {elapsed:?}"
            );
        }
    }
}

#[test]
fn cancellation_interrupts_redirect_body_or_followup_without_waiting_for_eof() {
    let server = Server::new();
    let service = NetworkService::new().unwrap();
    service.set_allow_private_network(true);
    let session = service.session(
        NetworkPermissions {
            domains: vec!["127.0.0.1".into()],
            allow_http: true,
        },
        Duration::from_secs(3),
    );
    let cancelled = Arc::new(AtomicBool::new(false));
    let active = cancelled.clone();
    let input = request(format!("{}/cancel", server.base));
    let (done, result) = mpsc::channel();
    let worker = thread::spawn(move || {
        let response = session.request(input, || {
            if active.load(Ordering::Acquire) {
                Err("redirect fixture cancelled".into())
            } else {
                Ok(())
            }
        });
        let _ = done.send(response);
    });
    server
        .redirected
        .recv_timeout(Duration::from_secs(2))
        .unwrap();
    let began = Instant::now();
    cancelled.store(true, Ordering::Release);
    let failure = result
        .recv_timeout(Duration::from_millis(750))
        .unwrap()
        .unwrap_err();
    worker.join().unwrap();
    assert_eq!(failure, "redirect fixture cancelled");
    eprintln!(
        "redirect route=cancel connections={} elapsed_us={}",
        server.connections.load(Ordering::Acquire),
        began.elapsed().as_micros()
    );
}
