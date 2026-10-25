use serde_json::{Value, json};
use spotiflac_extensions::RuntimeLimits;
use spotiflac_extensions::environment::ExtensionEnvironment;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

const KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

struct Request {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

struct Server {
    base: String,
    requests: mpsc::Receiver<Request>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Server {
    fn new(responses: &[(&str, &[u8])]) -> Self {
        let responses: BTreeMap<_, _> = responses
            .iter()
            .map(|(path, body)| (path.to_string(), body.to_vec()))
            .collect();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let (sent, requests) = mpsc::channel();
        let worker = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(10);
            while !stopped.load(Ordering::Acquire) && Instant::now() < deadline {
                let (mut stream, _) = match listener.accept() {
                    Ok(value) => value,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("fetch fixture accept: {error}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut bytes = Vec::new();
                let header_end = loop {
                    if let Some(index) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                        break index + 4;
                    }
                    let mut chunk = [0; 4096];
                    let count = stream.read(&mut chunk).unwrap();
                    assert!(count > 0 && bytes.len() + count <= 16384);
                    bytes.extend_from_slice(&chunk[..count]);
                };
                let mut lines = std::str::from_utf8(&bytes[..header_end])
                    .unwrap()
                    .split("\r\n");
                let mut first = lines.next().unwrap().split_whitespace();
                let method = first.next().unwrap().to_owned();
                let path = first.next().unwrap().to_owned();
                let headers: BTreeMap<_, _> = lines
                    .filter_map(|line| line.split_once(':'))
                    .map(|(key, value)| (key.to_ascii_lowercase(), value.trim().to_owned()))
                    .collect();
                let length = headers
                    .get("content-length")
                    .map(|value| value.parse::<usize>().unwrap())
                    .unwrap_or(0);
                assert!(length <= 1 << 20);
                while bytes.len() - header_end < length {
                    let mut chunk = [0; 16384];
                    let count = stream.read(&mut chunk).unwrap();
                    assert!(count > 0 && bytes.len() + count <= (1 << 20) + header_end);
                    bytes.extend_from_slice(&chunk[..count]);
                }
                let response = responses.get(&path).map(Vec::as_slice).unwrap_or(b"{}");
                sent.send(Request {
                    method,
                    path,
                    headers,
                    body: bytes[header_end..].to_vec(),
                })
                .unwrap();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    response.len()
                )
                .unwrap();
                stream.write_all(response).unwrap();
            }
        });
        Self {
            base,
            requests,
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

fn manifest() -> String {
    json!({"name":"example.fetch","version":"1","description":"Generic fetch fixture","type":["metadata_provider"],
        "permissions":{"network":["127.0.0.1"],"allowHttp":true}}).to_string()
}

#[test]
fn fetch_json_preserves_go_numbers_normalization_and_fresh_objects() {
    let server = Server::new(&[
        ("/numbers", b"[-0,-0.0,9007199254740993,9223372036854775807,18446744073709551615,1.7976931348623157e308,5e-324,-1e-4000]"),
        ("/overflow", br#"{"x":1e400,"x":0}"#),
        ("/malformed", b"{\"value\":\"\xff\xe2\x82\"}"),
        ("/surrogates", br#"{"\ud800":1,"\ufffd":2,"\ud800":3,"value":"\udfff","pair":"\ud83d\ude00"}"#),
        ("/object", br#"{"__proto__":{"polluted":true},"nested":{"n":1},"items":[1,2]}"#),
        ("/invalid", br#"{"x":1,}"#),
        ("/trailing", b"{}{}"),
        ("/string", br#"{"x":"[1e400] \" { "}"#),
        ("/null", b"null"),
    ]);
    let directory = tempfile::tempdir().unwrap();
    let environment = ExtensionEnvironment::new(directory.path(), KEY, "1").unwrap();
    environment.set_allow_private_network(true).unwrap();
    let runtime = environment.load(&manifest(), r#"registerExtension({run(base){
        const numbers = fetch(base+'/numbers').json();
        const malformed = fetch(base+'/malformed').json();
        const surrogates = fetch(base+'/surrogates').json();
        const response = fetch(base+'/object');
        const first = response.json();
        first.nested.n = 9; first.items.push(3); first.extra = true;
        const second = response.json();
        return {
            zero: Object.is(numbers[0],-0) && Object.is(numbers[1],-0) && Object.is(numbers[7],-0),
            numbers: numbers[2]===9007199254740992 && numbers[3]===9223372036854775808
                && numbers[4]===18446744073709551616 && numbers[5]===Number.MAX_VALUE && numbers[6]===Number.MIN_VALUE,
            overflow: fetch(base+'/overflow').json()===undefined,
            malformed: malformed.value==='\ufffd\ufffd\ufffd',
            surrogates: surrogates['\ufffd']===3 && surrogates.value==='\ufffd' && surrogates.pair==='\ud83d\ude00',
            proto: Object.prototype.hasOwnProperty.call(second,'__proto__')
                && second.__proto__.polluted===true && Object.getPrototypeOf(second)===Object.prototype && ({}).polluted===undefined,
            fresh: first!==second && first.nested!==second.nested && second.nested.n===1 && second.items.length===2 && second.extra===undefined,
            invalid: fetch(base+'/invalid').json()===undefined && fetch(base+'/trailing').json()===undefined,
            string: fetch(base+'/string').json().x==='[1e400] " { ',
            null: fetch(base+'/null').json()===null
        };
    }});"#, RuntimeLimits::default()).unwrap();
    let result = runtime
        .call("run", &json!([server.base]).to_string(), None, 5000)
        .unwrap();
    let result: Value = serde_json::from_str(&result).unwrap();
    assert_eq!(result.as_object().unwrap().len(), 10);
    for (name, value) in result.as_object().unwrap() {
        assert_eq!(value, true, "{name}: {result}");
    }
    environment.shutdown();
}

#[test]
fn direct_http_arguments_preserve_body_bytes_getters_headers_and_content_type() {
    let server = Server::new(&[]);
    let directory = tempfile::tempdir().unwrap();
    let environment = ExtensionEnvironment::new(directory.path(), KEY, "1").unwrap();
    environment.set_allow_private_network(true).unwrap();
    let runtime = environment.load(&manifest(), r#"registerExtension({run(base){
        const events = [];
        const url = {toString(){events.push('url');return base+'/large';}};
        const body = {
            get z(){events.push('body.z');return undefined;},
            get a(){events.push('body.a');return '\ud800';},
            get blob(){events.push('body.blob');return 'x'.repeat(262144);}
        };
        const headers = {
            get 'X-Zero'(){events.push('header.zero');return -0;},
            get 'X-List'(){events.push('header.list');return ['one',2];},
            get 'X-Null'(){events.push('header.null');return null;}
        };
        const options = {
            get method(){events.push('method');return 'post';},
            get body(){events.push('body');return body;},
            get headers(){events.push('headers');return headers;}
        };
        const large = fetch(url,options);
        const empty = http.post(base+'/empty',undefined);
        const emptyFetch = fetch(base+'/empty-fetch',{method:'POST'});
        const override = fetch(base+'/override',{method:'POST',body:'raw\0\ud800',headers:{'Content-Type':'application/custom'}});
        return {events,statuses:[large.status,empty.statusCode,emptyFetch.status,override.status]};
    }});"#, RuntimeLimits::default()).unwrap();
    let result = runtime
        .call("run", &json!([server.base]).to_string(), None, 5000)
        .unwrap();
    let result: Value = serde_json::from_str(&result).unwrap();
    assert_eq!(
        result["events"],
        json!([
            "url",
            "method",
            "method",
            "body",
            "body.z",
            "body.a",
            "body.blob",
            "headers",
            "header.zero",
            "header.list",
            "header.null"
        ])
    );
    assert_eq!(result["statuses"], json!([200, 200, 200, 200]));
    let requests: Vec<_> = (0..4)
        .map(|_| {
            server
                .requests
                .recv_timeout(Duration::from_secs(2))
                .unwrap()
        })
        .collect();
    assert!(requests.iter().all(|request| request.method == "POST"));
    let large = &requests[0];
    assert_eq!(large.path, "/large");
    let expected = format!(
        "{{\"a\":\"\u{fffd}\",\"blob\":\"{}\",\"z\":null}}",
        "x".repeat(262144)
    );
    assert_eq!(large.body, expected.as_bytes());
    assert_eq!(large.headers["x-zero"], "-0");
    assert_eq!(large.headers["x-list"], "[one 2]");
    assert_eq!(large.headers["x-null"], "<nil>");
    assert_eq!(large.headers["content-type"], "application/json");
    assert_eq!(requests[1].path, "/empty");
    assert!(requests[1].body.is_empty());
    assert_eq!(requests[1].headers["content-type"], "application/json");
    assert_eq!(requests[2].path, "/empty-fetch");
    assert!(requests[2].body.is_empty());
    assert!(!requests[2].headers.contains_key("content-type"));
    assert_eq!(requests[3].path, "/override");
    assert_eq!(requests[3].body, b"raw\0\xef\xbf\xbd");
    assert_eq!(requests[3].headers["content-type"], "application/custom");
    environment.shutdown();
}
