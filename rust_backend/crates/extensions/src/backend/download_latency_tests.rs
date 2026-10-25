use super::*;
use crate::environment::ExtensionEnvironment;
use crate::{
    RuntimeLimits,
    backend::{LyricsRequest, MetadataOptions},
};
use spotiflac_network::{NetworkOptions, NetworkService};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

const RECORDING: &str = r#"{"recordings":[{"tags":[{"name":"rock","count":1}],"releases":[{"title":"Album","artist-credit":[{"name":"Album Artist"}]}]}]}"#;
const CATALOG: &str = r#"{"id":7,"album":{"id":9},"genres":{"data":[{"name":"Jazz"}]},"label":"Label","copyright":"Copyright"}"#;

#[test]
fn download_preserves_source_artist_credits_in_response_and_embedded_tags() {
    let manifest = ExtensionManifest {
        name: "audio-provider".into(),
        ..Default::default()
    };
    for (source, provided, expected) in [
        (
            "Lead Artist & Guest Artist",
            "Lead Artist",
            "Lead Artist & Guest Artist",
        ),
        (
            "",
            "Lead Artist & Guest Artist",
            "Lead Artist & Guest Artist",
        ),
        (
            "   ",
            "Lead Artist & Guest Artist",
            "Lead Artist & Guest Artist",
        ),
        (
            "Lead Artist & Guest Artist",
            "",
            "Lead Artist & Guest Artist",
        ),
    ] {
        let request = DownloadRequest {
            track_name: "Track".into(),
            artist_name: source.into(),
            ..Default::default()
        };
        let result = json!({"artist": provided});
        for exists in [false, true] {
            let response = success(&request, &result, "track.flac", exists, &manifest, &|| {
                Ok(())
            })
            .unwrap();
            assert_eq!(response["artist"], expected);
            assert_eq!(
                download_metadata_fields(&request, &response)["ARTIST"],
                expected
            );
        }
    }
}

fn network() -> (Arc<NetworkService>, Arc<rustls::ServerConfig>) {
    let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        vec![certificate.cert.der().clone()],
        rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der()).into(),
    )
    .unwrap();
    let network = NetworkService::with_options(NetworkOptions {
        extra_root_pem: certificate.cert.pem().into_bytes(),
        doh_upstreams: vec![],
        ..Default::default()
    })
    .unwrap();
    network.set_allow_private_network(true);
    (network, Arc::new(config))
}

fn server(
    requests: usize,
    body: &'static str,
    config: Arc<rustls::ServerConfig>,
) -> (
    String,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    thread::JoinHandle<Vec<String>>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("https://{}", listener.local_addr().unwrap());
    let (started, ready) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut paths = Vec::new();
        for index in 0..requests {
            let stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "missing metadata request");
                        thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("{error}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut stream = rustls::StreamOwned::new(
                rustls::ServerConnection::new(Arc::clone(&config)).unwrap(),
                stream,
            );
            let mut request = [0; 4096];
            let count = stream.read(&mut request).unwrap();
            assert!(count > 0);
            paths.push(
                std::str::from_utf8(&request[..count])
                    .unwrap()
                    .split_whitespace()
                    .nth(1)
                    .unwrap()
                    .to_owned(),
            );
            if index == 0 {
                let _ = started.send(());
                released.recv_timeout(Duration::from_secs(3)).unwrap();
            }
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
        paths
    });
    (url, ready, release, worker)
}

fn backend(
    directory: &Path,
    catalog: String,
    recording: String,
    network: Arc<NetworkService>,
) -> Arc<Backend> {
    let environment = ExtensionEnvironment::with_network(
        &directory.join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        network,
    )
    .unwrap();
    let mut options = MetadataOptions {
        deezer_endpoint: catalog,
        ..Default::default()
    };
    options.musicbrainz.endpoint = recording;
    Arc::new(
        Backend::with_environment(
            &directory.join("sources"),
            environment,
            RuntimeLimits::default(),
            options,
        )
        .unwrap(),
    )
}

#[test]
fn extended_metadata_overlaps_requests_preserves_fields_and_reuses_genre_fallback() {
    for catalog_body in [
        CATALOG,
        r#"{"id":7,"album":{"id":9},"label":"Label","copyright":"Copyright"}"#,
    ] {
        let (network, config) = network();
        let (catalog, catalog_ready, release_catalog, catalog_worker) =
            server(2, catalog_body, Arc::clone(&config));
        let (recording, recording_ready, release_recording, recording_worker) =
            server(1, RECORDING, config);
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path(), catalog, recording, network);
        let active = Arc::clone(&backend);
        let worker = thread::spawn(move || {
            let mut request = DownloadRequest {
                isrc: "EXAMPLE12345".into(),
                album_name: "Album".into(),
                label: "Existing label".into(),
                ..Default::default()
            };
            active
                .enrich_download_extended(&mut request, &|| Ok(()))
                .unwrap();
            request
        });
        // Neither server replies until both independent requests have started.
        catalog_ready.recv_timeout(Duration::from_secs(2)).unwrap();
        recording_ready
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        release_catalog.send(()).unwrap();
        release_recording.send(()).unwrap();
        let mut request = worker.join().unwrap();
        assert_eq!(request.album_artist, "Album Artist");
        assert_eq!(request.label, "Existing label");
        assert_eq!(request.copyright, "Copyright");
        assert_eq!(
            request.genre,
            if catalog_body == CATALOG {
                "Jazz"
            } else {
                "Rock"
            }
        );
        assert_eq!(
            catalog_worker.join().unwrap(),
            ["/2.0/track/isrc:EXAMPLE12345", "/2.0/album/9"]
        );
        recording_worker.join().unwrap();
        // Complete input must not query either server, which is now closed.
        backend
            .enrich_download_extended(&mut request, &|| Ok(()))
            .unwrap();
        assert_eq!(request.label, "Existing label");
        backend.shutdown();
    }
}

#[test]
fn extended_metadata_cancellation_joins_both_blocked_requests() {
    for shutdown in [false, true] {
        let (network, config) = network();
        let (catalog, catalog_ready, release_catalog, catalog_worker) =
            server(1, CATALOG, Arc::clone(&config));
        let (recording, recording_ready, release_recording, recording_worker) =
            server(1, RECORDING, config);
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(directory.path(), catalog, recording, network);
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&cancelled);
        let active = Arc::clone(&backend);
        let worker = thread::spawn(move || {
            let mut request = DownloadRequest {
                isrc: "EXAMPLE12345".into(),
                album_name: "Album".into(),
                ..Default::default()
            };
            active.enrich_download_extended(&mut request, &|| {
                active.check()?;
                if stop.load(Ordering::Acquire) {
                    Err("download cancelled".into())
                } else {
                    Ok(())
                }
            })
        });
        catalog_ready.recv_timeout(Duration::from_secs(2)).unwrap();
        recording_ready
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        if shutdown {
            backend.shutdown();
        } else {
            cancelled.store(true, Ordering::Release);
        }
        let started = Instant::now();
        while !worker.is_finished() {
            assert!(
                started.elapsed() < Duration::from_secs(2),
                "cancel waited for HTTP replies"
            );
            thread::sleep(Duration::from_millis(1));
        }
        let result = worker.join().unwrap();
        if shutdown {
            assert!(result.is_err(), "owner shutdown must cancel metadata");
        } else {
            assert_eq!(result, Err("download cancelled".into()));
        }
        release_catalog.send(()).unwrap();
        release_recording.send(()).unwrap();
        catalog_worker.join().unwrap();
        recording_worker.join().unwrap();
        backend.shutdown();
    }
}

struct GatedServer {
    url: String,
    started: mpsc::Receiver<(String, mpsc::Sender<()>)>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<Vec<String>>>,
}

impl GatedServer {
    fn new(config: Arc<rustls::ServerConfig>, replies: &[(&str, u16, &str)]) -> Self {
        let replies: std::collections::BTreeMap<_, _> = replies
            .iter()
            .map(|(path, status, body)| (path.to_string(), (*status, body.to_string())))
            .collect();
        let replies = Arc::new(replies);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("https://{}", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let (ready, started) = mpsc::channel();
        let worker = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(8);
            let mut workers = Vec::new();
            while !stopped.load(Ordering::Acquire) && Instant::now() < deadline {
                let stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("gated fixture accept: {error}"),
                };
                assert!(workers.len() < 8, "unexpected repeated request");
                let config = config.clone();
                let ready = ready.clone();
                let replies = replies.clone();
                workers.push(thread::spawn(move || {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    stream.set_write_timeout(Some(Duration::from_secs(2))).unwrap();
                    let mut stream = rustls::StreamOwned::new(
                        rustls::ServerConnection::new(config).unwrap(), stream,
                    );
                    let mut request = Vec::new();
                    while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                        let mut bytes = [0; 4096];
                        let count = stream.read(&mut bytes).unwrap();
                        assert!(count > 0 && request.len() + count <= 8192);
                        request.extend_from_slice(&bytes[..count]);
                    }
                    let path = std::str::from_utf8(&request).unwrap().split_whitespace().nth(1).unwrap()
                        .split('?').next().unwrap().to_owned();
                    let (release, released) = mpsc::channel();
                    ready.send((path.clone(), release)).unwrap();
                    let _ = released.recv_timeout(Duration::from_secs(3));
                    let (status, body) = replies.get(&path).expect("unexpected fixture path");
                    let _ = write!(stream, "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    path
                }));
            }
            workers
                .into_iter()
                .map(|worker| worker.join().unwrap())
                .collect()
        });
        Self {
            url,
            started,
            stop,
            worker: Some(worker),
        }
    }

    fn next(&self) -> (String, mpsc::Sender<()>) {
        self.started.recv_timeout(Duration::from_secs(2)).unwrap()
    }

    fn finish(&mut self) -> Vec<String> {
        self.stop.store(true, Ordering::Release);
        let mut paths = self.worker.take().unwrap().join().unwrap();
        paths.sort();
        paths
    }
}

impl Drop for GatedServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[test]
fn catalog_search_gates_required_tracks_then_overlaps_optional_categories() {
    for mode in ["all", "artist", "track_failure"] {
        let (network, config) = network();
        let track = if mode == "track_failure" {
            r#"{"error":{"code":100,"message":"required track failure"}}"#
        } else {
            r#"{"data":[{"id":1,"title":"Track"}]}"#
        };
        let artist = if mode == "artist" {
            r#"{"data":[{"id":2,"name":"Artist"}]}"#
        } else {
            r#"{"error":{"code":100,"message":"optional artist failure"}}"#
        };
        let mut server = GatedServer::new(
            config,
            &[
                ("/2.0/search/track", 200, track),
                ("/2.0/search/artist", 200, artist),
                (
                    "/2.0/search/album",
                    200,
                    r#"{"data":[{"id":3,"title":"Album"}]}"#,
                ),
                (
                    "/2.0/search/playlist",
                    200,
                    r#"{"data":[{"id":4,"title":"Playlist"}]}"#,
                ),
            ],
        );
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(
            directory.path(),
            server.url.clone(),
            server.url.clone(),
            network,
        );
        let active = backend.clone();
        let worker = thread::spawn(move || {
            active.search_deezer(
                "needle",
                2,
                2,
                if mode == "artist" { "artist" } else { "" },
                &|| Ok(()),
            )
        });
        let (first, release) = server.next();
        assert_eq!(
            first,
            if mode == "artist" {
                "/2.0/search/artist"
            } else {
                "/2.0/search/track"
            }
        );
        assert!(matches!(
            server.started.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        release.send(()).unwrap();
        if mode == "all" {
            let mut pending = Vec::new();
            for _ in 0..3 {
                pending.push(server.next());
            }
            let mut categories: Vec<_> = pending.iter().map(|(path, _)| path.as_str()).collect();
            categories.sort();
            assert_eq!(
                categories,
                [
                    "/2.0/search/album",
                    "/2.0/search/artist",
                    "/2.0/search/playlist"
                ]
            );
            for (_, release) in pending {
                release.send(()).unwrap();
            }
        }
        let result = worker.join().unwrap();
        if mode == "track_failure" {
            assert!(result.unwrap_err().contains("required track failure"));
        } else {
            let value: Value = serde_json::from_str(&result.unwrap()).unwrap();
            if mode == "all" {
                assert_eq!(value["tracks"][0]["spotify_id"], "deezer:1");
                assert_eq!(value["artists"], json!([]));
                assert_eq!(value["albums"][0]["id"], "deezer:3");
                assert_eq!(value["playlists"][0]["id"], "deezer:4");
            } else {
                assert_eq!(value["artists"][0]["id"], "deezer:2");
                assert_eq!(value["tracks"], json!([]));
                assert_eq!(value["albums"], json!([]));
                assert_eq!(value["playlists"], json!([]));
            }
        }
        let paths = server.finish();
        assert_eq!(paths.len(), if mode == "all" { 4 } else { 1 });
        backend.shutdown();
    }
}

#[test]
fn reenrich_cover_and_lyrics_overlap_preserve_best_effort_results_and_cancel() {
    for mode in [
        "success",
        "cover_failure",
        "lyrics_failure",
        "missing",
        "instrumental",
        "instrumental_native",
        "instrumental_with_lyrics",
        "cancel",
    ] {
        let (network, config) = network();
        let mut server = GatedServer::new(
            config,
            &[
                (
                    "/cover",
                    if matches!(mode, "cover_failure" | "instrumental_native") {
                        404
                    } else {
                        200
                    },
                    "artwork",
                ),
                (
                    "/lyrics",
                    if matches!(mode, "lyrics_failure" | "missing") {
                        404
                    } else {
                        200
                    },
                    "New lyrics",
                ),
            ],
        );
        let directory = tempfile::tempdir().unwrap();
        let backend = backend(
            directory.path(),
            server.url.clone(),
            server.url.clone(),
            network,
        );
        let archive = directory.path().join("example.lyrics.sflx");
        let mut writer = zip::ZipWriter::new(std::fs::File::create(&archive).unwrap());
        let manifest = json!({"name":"example.lyrics","displayName":"Example Lyrics","version":"1",
            "description":"Generic lyrics fixture","type":["lyrics_provider"],"permissions":{"network":["127.0.0.1"]}});
        let source = format!(
            r#"registerExtension({{fetchLyrics(){{const response=http.get({});
            return response.statusCode===200 ? {} : {{}};}}}});"#,
            json!(format!("{}/lyrics", server.url)),
            if mode.starts_with("instrumental") {
                "{instrumental:true}"
            } else {
                "{plainLyrics:response.body}"
            },
        );
        for (name, body) in [
            ("manifest.json", manifest.to_string()),
            ("index.js", source),
        ] {
            writer
                .start_file(name, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(body.as_bytes()).unwrap();
        }
        writer.finish().unwrap();
        backend.install(&archive).unwrap();
        backend.set_enabled("example.lyrics", true).unwrap();
        backend
            .set_lyrics_providers_json(r#"["extension:example.lyrics"]"#)
            .unwrap();
        let native = mode == "instrumental_native";
        let file_name = if native { "track.flac" } else { "track.mp3" };
        let audio = directory.path().join("data").join(file_name);
        let sidecar = directory.path().join("data/track.lrc");
        if native {
            let mut flac = b"fLaC\x80\x00\x00\x22".to_vec();
            flac.extend_from_slice(&[0; 34]);
            flac.extend_from_slice(&[0xff, 0xf8]);
            flac.extend_from_slice(&[0; 32]);
            std::fs::write(&audio, flac).unwrap();
        } else {
            std::fs::write(&audio, "original audio").unwrap();
        }
        let has_existing = !matches!(mode, "missing" | "instrumental" | "instrumental_native");
        if has_existing {
            std::fs::write(&sidecar, "[00:01.00]Old lyrics").unwrap();
        }
        let request = json!({"file_path":file_name,"track_name":"Track","artist_name":"Artist",
            "cover_url":format!("{}/cover", server.url),"embed_lyrics":true,"lyrics_mode":"both",
            "update_fields":["cover","lyrics"]})
        .to_string();
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = cancelled.clone();
        let active = backend.clone();
        let worker = thread::spawn(move || {
            active.reenrich_file(&request, &|| {
                if stop.load(Ordering::Acquire) {
                    Err("reenrich cancelled".into())
                } else {
                    Ok(())
                }
            })
        });
        let first = server.next();
        let second = server.next();
        let mut paths = [first.0.as_str(), second.0.as_str()];
        paths.sort();
        assert_eq!(paths, ["/cover", "/lyrics"]);
        if mode == "cancel" {
            cancelled.store(true, Ordering::Release);
            let deadline = Instant::now() + Duration::from_secs(2);
            while !worker.is_finished() {
                assert!(
                    Instant::now() < deadline,
                    "reenrich cancellation waited for server replies"
                );
                thread::sleep(Duration::from_millis(1));
            }
        } else {
            first.1.send(()).unwrap();
            second.1.send(()).unwrap();
        }
        let result = worker.join().unwrap();
        if mode == "cancel" {
            assert_eq!(result, Err("reenrich cancelled".into()));
            first.1.send(()).unwrap();
            second.1.send(()).unwrap();
        } else {
            let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["method"], if native { "native" } else { "ffmpeg" });
            assert_eq!(result["write_external_lrc"], mode != "missing");
            let lyrics = result["lyrics"].as_str().unwrap();
            let (status, expected) = match mode {
                "lyrics_failure" | "instrumental_with_lyrics" => ("preserved", "Old lyrics"),
                "missing" => ("not_found", ""),
                "instrumental" | "instrumental_native" => ("instrumental", "[instrumental:true]"),
                _ => ("updated", "New lyrics"),
            };
            assert_eq!(result["lyrics_status"], status);
            if mode == "missing" {
                assert!(lyrics.is_empty());
                assert!(result["metadata"].get("LYRICS").is_none());
            } else {
                assert!(lyrics.contains(expected));
                if !native {
                    assert_eq!(result["metadata"]["LYRICS"], lyrics);
                }
            }
            if !native {
                let cover = result["cover_path"].as_str().unwrap();
                if mode == "cover_failure" {
                    assert!(cover.is_empty());
                } else {
                    assert_eq!(std::fs::read(cover).unwrap(), b"artwork");
                    std::fs::remove_file(cover).unwrap();
                }
            } else {
                let embedded = backend
                    .get_lyrics_lrc(
                        &LyricsRequest {
                            file_path: file_name.into(),
                            ..Default::default()
                        },
                        &|| Ok(()),
                    )
                    .unwrap();
                assert_eq!(embedded, "[instrumental:true]");
            }
        }
        if !native {
            assert_eq!(std::fs::read(&audio).unwrap(), b"original audio");
        }
        if has_existing {
            assert_eq!(std::fs::read(&sidecar).unwrap(), b"[00:01.00]Old lyrics");
        } else {
            assert!(!sidecar.exists());
        }
        assert!(
            std::fs::read_dir(directory.path().join("data"))
                .unwrap()
                .all(|entry| !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("reenrich_cover_"))
        );
        assert_eq!(server.finish(), ["/cover", "/lyrics"]);
        backend.shutdown();
    }
}
