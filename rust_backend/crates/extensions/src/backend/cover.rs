use super::Backend;
use cap_std::fs::OpenOptions;
use spotiflac_core::app_version::AppVersion;
use spotiflac_core::cover::{MAX_DOWNLOAD_BYTES, resize};
use spotiflac_core::tags::{CoverArt, extract_cover};
use spotiflac_network::{
    HttpRequest, NetworkService, NetworkSession, random_user_agent, url::UrlParts,
};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::Write;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, UNIX_EPOCH};

type Check<'a> = dyn Fn() -> Result<(), String> + 'a;
type Outcome = Result<Arc<[u8]>, String>;
const CACHE_TTL: Duration = Duration::from_secs(15 * 60);
const SIZE_ERROR: &str = "cover download exceeds 24 MiB limit";

struct Entry {
    data: Arc<[u8]>,
    expires: Instant,
}

#[derive(Default)]
struct Cache {
    entries: BTreeMap<String, Entry>,
    bytes: usize,
    flights: BTreeMap<String, Arc<Flight>>,
}

#[derive(Default)]
struct Flight {
    // Outer None is pending; inner None asks followers to retry after the
    // leader's cancellation. One caller cannot cancel another caller's work.
    outcome: Mutex<Option<Option<Outcome>>>,
    ready: Condvar,
}

pub(super) struct Cover {
    network: Arc<NetworkSession>,
    version: AppVersion,
    cache: Mutex<Cache>,
}

impl Cover {
    pub fn new(network: &Arc<NetworkService>, version: AppVersion) -> Self {
        Self {
            network: network.native_media_session(Duration::from_secs(60)),
            version,
            cache: Mutex::default(),
        }
    }

    pub fn clear(&self) {
        let mut cache = self.cache.lock().expect("cover cache lock");
        cache.entries.clear();
        cache.bytes = 0;
    }

    pub(super) fn download(&self, url: &str, limit: i64, check: &Check<'_>) -> Outcome {
        let key = if limit <= 0 {
            url.to_owned()
        } else {
            format!("{url}\0max-dimension={limit}")
        };
        self.cached(&key, check, &|| {
            if limit <= 0 {
                return self.fetch(url, check);
            }
            let original = self.download(url, 0, check)?;
            match resize(&original, limit, check)
                .map_err(|error| format!("resize artwork: {error}"))?
            {
                std::borrow::Cow::Borrowed(_) => Ok(original),
                std::borrow::Cow::Owned(data) => Ok(data.into()),
            }
        })
    }

    fn cached(&self, key: &str, check: &Check<'_>, fetch: &dyn Fn() -> Outcome) -> Outcome {
        loop {
            check()?;
            let (flight, leader) = {
                let mut cache = self.cache.lock().expect("cover cache lock");
                if let Some(entry) = cache.entries.get(key) {
                    if Instant::now() < entry.expires {
                        return Ok(entry.data.clone());
                    }
                    let entry = cache.entries.remove(key).expect("expired cover entry");
                    cache.bytes -= entry.data.len();
                }
                if let Some(flight) = cache.flights.get(key) {
                    (flight.clone(), false)
                } else {
                    let flight = Arc::new(Flight::default());
                    cache.flights.insert(key.into(), flight.clone());
                    (flight, true)
                }
            };
            if !leader {
                let mut outcome = flight.outcome.lock().expect("cover flight lock");
                loop {
                    check()?;
                    match outcome.as_ref() {
                        Some(Some(result)) => return result.clone(),
                        Some(None) => break,
                        None => {
                            outcome = flight
                                .ready
                                .wait_timeout(outcome, Duration::from_millis(25))
                                .expect("cover flight wait")
                                .0;
                        }
                    }
                }
                continue;
            }
            // A decoder/transport panic must not strand coalesced callers.
            let result = catch_unwind(AssertUnwindSafe(fetch))
                .unwrap_or_else(|_| Err("cover fetch aborted".into()));
            let cancelled = check().err();
            let mut cache = self.cache.lock().expect("cover cache lock");
            if cancelled.is_none()
                && let Ok(data) = &result
                && !data.is_empty()
                && data.len() <= MAX_DOWNLOAD_BYTES
            {
                cache.bytes += data.len();
                cache.entries.insert(
                    key.into(),
                    Entry {
                        data: data.clone(),
                        expires: Instant::now() + CACHE_TTL,
                    },
                );
                while cache.bytes > MAX_DOWNLOAD_BYTES {
                    let oldest = cache
                        .entries
                        .iter()
                        .min_by_key(|(_, entry)| entry.expires)
                        .map(|(key, _)| key.clone())
                        .expect("nonempty cover cache");
                    cache.bytes -= cache.entries.remove(&oldest).unwrap().data.len();
                }
            }
            cache.flights.remove(key);
            *flight.outcome.lock().expect("cover flight lock") =
                Some(cancelled.is_none().then(|| result.clone()));
            flight.ready.notify_all();
            return cancelled.map_or(result, Err);
        }
    }

    fn fetch(&self, url: &str, check: &Check<'_>) -> Outcome {
        let parsed = UrlParts::parse(url)
            .ok_or_else(|| "failed to create request: invalid URL".to_owned())?;
        let user_agent = if parsed.hostname.eq_ignore_ascii_case("api.zarz.moe") {
            self.version.user_agent()
        } else {
            random_user_agent()
        };
        let mut response = self
            .network
            .open_response_stream(
                HttpRequest {
                    url: url.into(),
                    method: "GET".into(),
                    body: String::new(),
                    headers: BTreeMap::new(),
                    default_json: false,
                    user_agent,
                },
                check,
            )
            .map_err(|error| format!("failed to download cover: {error}"))?;
        if response.response.status != 200 {
            return Err(format!(
                "cover download failed: HTTP {}",
                response.response.status
            ));
        }
        if response
            .response
            .headers
            .get("Content-Length")
            .and_then(|values| values.first())
            .and_then(|value| value.parse::<u64>().ok())
            .is_some_and(|length| length > MAX_DOWNLOAD_BYTES as u64)
        {
            return Err(SIZE_ERROR.into());
        }
        let mut data = Vec::new();
        let mut buffer = [0; 64 * 1024];
        loop {
            let capacity = buffer.len().min(MAX_DOWNLOAD_BYTES + 1 - data.len());
            let count = response
                .read(&mut buffer[..capacity], check)
                .map_err(|error| format!("failed to read cover data: {error}"))?;
            if count == 0 {
                break;
            }
            data.extend_from_slice(&buffer[..count]);
            if data.len() > MAX_DOWNLOAD_BYTES {
                return Err(SIZE_ERROR.into());
            }
        }
        Ok(data.into())
    }
}

impl Backend {
    pub fn extract_cover_to_file(
        &self,
        audio_path: &str,
        output_path: &str,
        check: &Check<'_>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        let format = extension(audio_path);
        if !matches!(
            format.as_str(),
            "flac" | "m4a" | "aac" | "mp3" | "ogg" | "opus" | "wav" | "aiff" | "aif" | "aifc"
        ) {
            return Err("unsupported audio format for cover extraction".into());
        }
        let files = self.manager.environment().native_files()?;
        let input = files.resolve_legacy(audio_path)?;
        let cover = read_cover(&input, &format, &check)
            .map_err(|error| format!("failed to extract cover: {error}"))?;
        let write = || {
            let output = files.resolve_legacy(output_path)?;
            if input.absolute == output.absolute {
                return Err("cover output must differ from the audio source".into());
            }
            let _lock = files.lock(&output, &check)?;
            let permissions = output_permissions(&output)?;
            publish_cover(&output, permissions, &cover.data, &check)
        };
        write().map_err(|error| format!("failed to write cover file: {error}"))
    }

    pub fn save_cover_to_cache_with_hint_and_key(
        &self,
        audio_path: &str,
        hint: &str,
        cache_directory: &str,
        explicit_key: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.cache_cover(
            audio_path,
            hint,
            cache_directory,
            explicit_key,
            None,
            read_cover,
            check,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn save_cover_to_cache_for_scan(
        &self,
        audio_path: &str,
        hint: &str,
        cache_directory: &str,
        explicit_key: &str,
        read: impl FnOnce(&crate::files::FilePath, &str, &Check<'_>) -> Result<CoverArt, String>,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let format = spotiflac_core::tags::library_extension(audio_path, hint);
        // The scan's MP4-family reader also accepts .mp4/.aac. The standalone
        // cover export deliberately keeps its narrower legacy suffix policy.
        let format = matches!(format.as_str(), "mp4" | "aac").then_some("m4a");
        self.cache_cover(
            audio_path,
            hint,
            cache_directory,
            explicit_key,
            format,
            read,
            check,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn cache_cover(
        &self,
        audio_path: &str,
        hint: &str,
        cache_directory: &str,
        explicit_key: &str,
        format_override: Option<&str>,
        read: impl FnOnce(&crate::files::FilePath, &str, &Check<'_>) -> Result<CoverArt, String>,
        check: &Check<'_>,
    ) -> Result<String, String> {
        let _operation = self.enter()?;
        let failure = RefCell::new(None::<String>);
        let check = || {
            if let Some(error) = failure.borrow().as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.borrow_mut() = Some(error.clone());
            })
        };
        check()?;
        let files = self.manager.environment().native_files()?;
        let input = files.resolve_legacy(audio_path)?;
        input.native_display()?;
        let key = if !explicit_key.trim().is_empty() {
            explicit_key.trim().to_owned()
        } else if let Ok(metadata) = input.metadata() {
            let modified = metadata
                .modified()
                .map_err(|error| error.to_string())?
                .into_std();
            let nanos = match modified.duration_since(UNIX_EPOCH) {
                Ok(duration) => duration.as_nanos() as i128,
                Err(error) => -(error.duration().as_nanos() as i128),
            };
            format!("{audio_path}|{}|{nanos}", metadata.len())
        } else {
            audio_path.into()
        };
        let hash = key.chars().fold(5381_u32, |hash, value| {
            hash.wrapping_mul(33).wrapping_add(value as u32)
        });
        let path =
            |extension| Path::new(cache_directory).join(format!("cover_{hash:x}.{extension}"));
        let jpg = files.resolve_legacy(&path("jpg").to_string_lossy())?;
        let png = files.resolve_legacy(&path("png").to_string_lossy())?;
        for cached in [&jpg, &png] {
            cached.native_display()?;
            if cached.metadata().is_ok_and(|metadata| metadata.is_file()) {
                return Ok(cached.display());
            }
        }
        let mut format = extension(audio_path);
        if format.is_empty() {
            format = extension(hint);
        }
        if let Some(value) = format_override {
            format = value.into();
        }
        if !matches!(
            format.as_str(),
            "flac" | "m4a" | "mp3" | "ogg" | "opus" | "wav" | "aiff" | "aif" | "aifc"
        ) {
            return Err(format!(
                "unsupported format: {}",
                if format.is_empty() {
                    String::new()
                } else {
                    format!(".{format}")
                }
            ));
        }
        let mut cover = read(&input, &format, &check)?;
        if let Ok(resized) = spotiflac_core::cover::library_thumbnail(&cover.data, &check) {
            cover.mime = if resized.starts_with(b"\x89PNG") {
                "image/png"
            } else if resized.starts_with(b"\xff\xd8") {
                "image/jpeg"
            } else {
                &cover.mime
            }
            .into();
            cover.data = resized.to_vec();
        }
        // Library caching may retain unsupported image bytes, but must never
        // swallow cancellation while attempting the optional resize.
        check()?;
        let output = if cover.mime.contains("png") { png } else { jpg };
        let _lock = files.lock(&output, &check)?;
        if output.metadata().is_ok_and(|metadata| metadata.is_file()) {
            return Ok(output.display());
        }
        output
            .mkdir_parent()
            .map_err(|error| format!("failed to create cache dir: {error}"))?;
        let permissions = output_permissions(&output)
            .map_err(|error| format!("failed to write cover: {error}"))?;
        publish_cover(&output, permissions, &cover.data, &check)
            .map_err(|error| format!("failed to write cover: {error}"))?;
        Ok(output.display())
    }

    pub fn download_cover_to_file_sized(
        &self,
        url: &str,
        output_path: &str,
        max_dimension: i64,
        check: &Check<'_>,
    ) -> Result<(), String> {
        let _operation = self.enter()?;
        let failure = RefCell::new(None::<String>);
        let check = || {
            if let Some(error) = failure.borrow().as_ref() {
                return Err(error.clone());
            }
            self.check().and_then(|()| check()).inspect_err(|error| {
                *failure.borrow_mut() = Some(error.clone());
            })
        };
        check()?;
        if url.is_empty() {
            return Err("no cover URL provided".into());
        }
        let files = self.manager.environment().native_files()?;
        // Validate and lock before doing network work for an unauthorized or
        // unavailable destination. Publication revalidates the same grant.
        let prepare = || {
            let output = files.resolve_legacy(output_path)?;
            let lock = files.lock(&output, &check)?;
            let permissions = output_permissions(&output)?;
            Ok((output, lock, permissions))
        };
        let (output, _lock, permissions) =
            prepare().map_err(|error: String| format!("failed to write cover file: {error}"))?;
        let data = self
            .cover
            .download(url, max_dimension, &check)
            .map_err(|error| format!("failed to download cover: {error}"))?;
        publish_cover(&output, permissions, &data, &check)
            .map_err(|error| format!("failed to write cover file: {error}"))
    }
}

fn extension(path: &str) -> String {
    Path::new(path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_lowercase()
}

fn read_cover(
    input: &crate::files::FilePath,
    format: &str,
    check: &Check<'_>,
) -> Result<CoverArt, String> {
    input.native_display()?;
    let mut file = input
        .open(OpenOptions::new().read(true))
        .map_err(|error| error.to_string())?;
    extract_cover(&mut file, format, check)
}

fn output_permissions(
    output: &crate::files::FilePath,
) -> Result<Option<cap_std::fs::Permissions>, String> {
    output.native_display()?;
    output.require_parent()?;
    match output.open(OpenOptions::new().write(true)) {
        Ok(file) => Ok(Some(
            file.metadata()
                .map_err(|error| error.to_string())?
                .permissions(),
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

fn publish_cover(
    output: &crate::files::FilePath,
    permissions: Option<cap_std::fs::Permissions>,
    data: &[u8],
    check: &Check<'_>,
) -> Result<(), String> {
    check()?;
    let mut stage = output
        .stage_existing_parent()
        .map_err(|error| error.to_string())?;
    if let Some(permissions) = permissions {
        stage
            .file
            .set_permissions(permissions)
            .map_err(|error| error.to_string())?;
    }
    for chunk in data.chunks(16 * 1024) {
        check()?;
        stage
            .file
            .write_all(chunk)
            .map_err(|error| error.to_string())?;
    }
    stage.publish(check)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::thread;

    fn cover() -> Cover {
        Cover::new(&NetworkService::new().unwrap(), "1".into())
    }

    #[test]
    fn cache_coalesces_and_a_cancelled_caller_does_not_cancel_its_peer() {
        for cancel_leader in [false, true] {
            let cover = cover();
            let (entered_tx, entered_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let (waiting_tx, waiting_rx) = mpsc::channel();
            let cancelled = AtomicBool::new(false);
            let calls = AtomicUsize::new(0);
            thread::scope(|scope| {
                let cover = &cover;
                let cancelled = &cancelled;
                let calls = &calls;
                let leader = scope.spawn(move || {
                    cover.cached(
                        "shared",
                        &|| {
                            if cancelled.load(Ordering::Acquire) {
                                Err("leader cancelled".into())
                            } else {
                                Ok(())
                            }
                        },
                        &|| {
                            calls.fetch_add(1, Ordering::AcqRel);
                            entered_tx.send(()).unwrap();
                            release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                            Ok(Arc::from(&b"leader"[..]))
                        },
                    )
                });
                entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                let follower = scope.spawn(|| {
                    let checks = Cell::new(0);
                    cover.cached(
                        "shared",
                        &|| {
                            checks.set(checks.get() + 1);
                            if checks.get() == 2 {
                                waiting_tx.send(()).unwrap();
                                if !cancel_leader {
                                    return Err("follower cancelled".into());
                                }
                            }
                            Ok(())
                        },
                        &|| {
                            calls.fetch_add(1, Ordering::AcqRel);
                            Ok(Arc::from(&b"follower"[..]))
                        },
                    )
                });
                waiting_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                cancelled.store(cancel_leader, Ordering::Release);
                release_tx.send(()).unwrap();
                let (leader, follower) = (leader.join().unwrap(), follower.join().unwrap());
                let expected = if cancel_leader {
                    assert_eq!(leader.unwrap_err(), "leader cancelled");
                    assert_eq!(follower.unwrap().as_ref(), b"follower");
                    assert_eq!(calls.load(Ordering::Acquire), 2);
                    &b"follower"[..]
                } else {
                    assert_eq!(leader.unwrap().as_ref(), b"leader");
                    assert_eq!(follower.unwrap_err(), "follower cancelled");
                    assert_eq!(calls.load(Ordering::Acquire), 1);
                    &b"leader"[..]
                };
                assert_eq!(
                    cover
                        .cached("shared", &|| Ok(()), &|| panic!("cache miss"))
                        .unwrap()
                        .as_ref(),
                    expected
                );
            });
        }
    }

    #[test]
    fn cache_expires_evicts_by_byte_budget_and_does_not_retain_failures() {
        let cover = cover();
        let fetches = Cell::new(0);
        let fetch = || {
            fetches.set(fetches.get() + 1);
            Ok(Arc::from(vec![42; 16 << 20]))
        };
        for key in ["first", "first", "second", "first"] {
            assert_eq!(
                cover.cached(key, &|| Ok(()), &fetch).unwrap().len(),
                16 << 20
            );
        }
        assert_eq!(fetches.get(), 3);
        cover
            .cache
            .lock()
            .unwrap()
            .entries
            .get_mut("first")
            .unwrap()
            .expires = Instant::now() - Duration::from_secs(1);
        cover.cached("first", &|| Ok(()), &fetch).unwrap();
        assert_eq!(fetches.get(), 4);
        cover.clear();
        cover.cached("first", &|| Ok(()), &fetch).unwrap();
        assert_eq!(fetches.get(), 5);
        for _ in 0..2 {
            assert_eq!(
                cover
                    .cached("error", &|| Ok(()), &|| Err("HTTP 500".into()))
                    .unwrap_err(),
                "HTTP 500"
            );
        }
        assert_eq!(
            cover
                .cached("panic", &|| Ok(()), &|| panic!("decoder panic"))
                .unwrap_err(),
            "cover fetch aborted"
        );
        assert_eq!(
            cover.cached("panic", &|| Ok(()), &fetch).unwrap().len(),
            16 << 20
        );
        assert_eq!(fetches.get(), 6);
    }
}
