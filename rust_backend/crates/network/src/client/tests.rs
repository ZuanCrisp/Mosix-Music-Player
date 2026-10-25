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
fn read_limited_matches_the_bounded_read_loops_it_replaced() {
    use std::io::{Read, Write};
    const BODY: &[u8] = b"0123456789";
    // (limit, buffer length): exact fit, one byte over, single-chunk and zero.
    let cases = [(10, 4), (9, 4), (10, 64 << 10), (9, 64 << 10), (0, 4)];
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        for _ in 0..cases.len() * 2 {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n")
                .unwrap();
            stream.write_all(BODY).unwrap();
        }
    });
    let service = NetworkService::new().unwrap();
    service.set_allow_private_network(true);
    let session = service.session(
        NetworkPermissions {
            domains: vec!["127.0.0.1".into()],
            allow_http: true,
        },
        Duration::from_secs(3),
    );
    let open = || {
        let request =
            serde_json::from_value(serde_json::json!({"url":format!("{base}/body")})).unwrap();
        session
            .open_stream(
                request,
                Duration::from_secs(3),
                Duration::from_secs(3),
                || Ok(()),
            )
            .unwrap()
    };
    let previous = |stream: &mut HttpStream, limit: usize, buffer: &mut [u8]| {
        let mut body = Vec::new();
        loop {
            let capacity = buffer.len().min(limit + 1 - body.len());
            let count = stream.read(&mut buffer[..capacity], || Ok(()))?;
            if count == 0 {
                break;
            }
            body.extend_from_slice(&buffer[..count]);
            if body.len() > limit {
                return Ok::<_, String>(None);
            }
        }
        Ok(Some(body))
    };
    for (limit, length) in cases {
        let actual = open().read_limited(limit, &mut vec![0; length], || Ok(()));
        let expected = previous(&mut open(), limit, &mut vec![0; length]);
        assert_eq!(actual, expected, "limit {limit} buffer {length}");
        assert_eq!(
            actual.unwrap(),
            (limit >= BODY.len()).then(|| BODY.to_vec())
        );
    }
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
