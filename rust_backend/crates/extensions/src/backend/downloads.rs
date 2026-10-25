//! Application download planning. The installed manager owns VMs/transfers;
//! this root owns request lifetime, fallback and publication of regular files.

use super::Backend;
use crate::download::native_error_response;
use crate::manager::{ProviderAvailabilityRequest, ProviderDownloadRequest};
use crate::manifest::ExtensionManifest;
use cap_std::fs::OpenOptions;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use spotiflac_core::cancellation::RequestLease;
use spotiflac_core::downloads::DownloadRequest;
use spotiflac_core::filename::{build_filename_checked, sanitize_filename_preserving_token};
use spotiflac_core::lyrics::matching::{normalize_loose_artist, normalize_title};
use spotiflac_core::matching::lowercase;
use spotiflac_core::metadata::reenrich::{self, text};
use spotiflac_core::resolver::{artists_match, titles_match, track_identity_title};
use spotiflac_core::tags::{embed_flac_metadata, extract_cover};
use spotiflac_providers::resolver::Check;
use std::collections::{BTreeMap, VecDeque};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

pub(super) type PreparedDownloads = BTreeMap<String, Prepared>;

pub(super) struct Prepared {
    key: String,
    request: DownloadRequest,
    metadata_ready: bool,
    created: Instant,
}

enum DownloadOutcome {
    Retry(Value),
    // Successful downloads and host finalization failures are both terminal.
    Final(Value),
}

impl Backend {
    /// Go's strategy facade returns a JSON failure, including transport errors
    /// from the extension facade. The latter retains its Result error boundary.
    pub fn download_by_strategy(&self, raw: &str, check: &Check<'_>) -> Result<String, String> {
        let _operation = self.enter()?;
        let request = match DownloadRequest::parse(raw) {
            Ok(request) => request,
            Err(error) => {
                return Ok(native_error_response(&format!("Invalid request: {error}")).to_string());
            }
        };
        if !request.use_extensions {
            return Ok(native_error_response(
                "Extension providers are disabled; built-in download providers have been retired",
            )
            .to_string());
        }
        Ok(self
            .download_request(request, check)
            .unwrap_or_else(|error| native_error_response(&error).to_string()))
    }

    fn download_request(
        &self,
        mut request: DownloadRequest,
        check: &Check<'_>,
    ) -> Result<String, String> {
        request.normalize();
        self.check()?;
        check()?;
        // Descriptor adoption is an application-owner operation. Do not claim
        // a successful regular-file download has written the caller's FD.
        if request.output_fd > 0 {
            return Err(
                "output descriptor ownership is not yet connected to the Rust download planner"
                    .into(),
            );
        }
        self.set_song_link_region(&request.songlink_region)?;
        let state = self.environment().download_state();
        let lease = Arc::new(
            state
                .acquire(&request.item_id)
                .map_err(|error| error.to_string())?,
        );
        lease.check_active().map_err(|error| error.to_string())?;
        let item_id = request.item_id.clone();
        if !item_id.is_empty() {
            state
                .progress
                .start(&item_id)
                .map_err(|error| error.to_string())?;
            state
                .progress
                .preparing(&item_id, "checking_session")
                .map_err(|error| error.to_string())?;
        }
        // One lease reaches availability, auth, VM and file finalization,
        // including requests without an item ID. Join the VM before returning.
        let result = std::thread::scope(|scope| {
            let (finished, completion) = mpsc::sync_channel(1);
            let request_lease = lease.clone();
            let worker = std::thread::Builder::new()
                .name("download-planner".into())
                .spawn_scoped(scope, move || {
                    let result = self.plan_download(request, request_lease);
                    let _ = finished.send(());
                    result
                })
                .map_err(|error| error.to_string())?;
            let mut cancelled = None;
            while !worker.is_finished() {
                if let Err(error) = self.check().and_then(|()| check()) {
                    cancelled = Some(error);
                    lease.release();
                    break;
                }
                // Completion wakes the caller immediately; timeouts retain the
                // owner/caller cancellation heartbeat while work is active.
                if !matches!(
                    completion.recv_timeout(Duration::from_millis(5)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
            let result = worker
                .join()
                .map_err(|_| "download planner panicked".to_owned())?;
            if let Some(error) = cancelled {
                return Err(error);
            }
            self.check()?;
            check()?;
            lease.check_active().map_err(|error| error.to_string())?;
            result
        });
        if !item_id.is_empty() {
            if result
                .as_ref()
                .is_ok_and(|result| result["success"] == true)
            {
                let _ = state.progress.complete(&item_id);
            } else {
                let _ = state.progress.remove(&item_id);
            }
        }
        result.map(|value| compact(value).to_string())
    }

    fn plan_download(
        &self,
        mut request: DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<Value, String> {
        let check = || {
            self.check()
                .and_then(|()| lease.check_active().map_err(|error| error.to_string()))
        };
        let key = preparation_key(&request);
        let session_provider = if request.service.trim().is_empty() {
            request.source.trim()
        } else {
            request.service.trim()
        }
        .to_owned();
        let preflight = self.preflight_download(&session_provider, lease.clone());
        check()?;
        match preflight {
            Ok(true) => {
                self.cache_prepared(&key, &request, false);
                return Ok(failure(
                    &session_provider,
                    "Verification required before download",
                    "verification_required",
                    0,
                ));
            }
            Err(error) => {
                return Ok(failure(
                    &session_provider,
                    &format!("Could not start verification for {session_provider}: {error}"),
                    "",
                    0,
                ));
            }
            Ok(false) => {}
        }
        let prepared = self.take_prepared(&key, &mut request);
        if !request.item_id.is_empty() {
            let _ = self
                .environment()
                .download_state()
                .progress
                .preparing(&request.item_id, "resolving_metadata");
        }
        let mut selected = request.service.trim().to_owned();
        let priorities: Value = serde_json::from_str(
            &self
                .provider_priorities()
                .map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        let mut priority: Vec<String> = serde_json::from_value(priorities["download"].clone())
            .map_err(|error| error.to_string())?;
        if !request.use_fallback {
            if selected.is_empty() {
                selected = request.source.trim().to_owned();
            }
            if !selected.is_empty() {
                priority = vec![selected.clone()];
            }
        } else if !request.service.is_empty() {
            priority.retain(|id| !id.eq_ignore_ascii_case(&request.service));
            priority.insert(0, request.service.clone());
        }

        if prepared == Some(false)
            && let Some(response) =
                self.download_verified_retry(&request, &selected, lease.clone())?
        {
            return Ok(response);
        }

        // A source catalog can explicitly prohibit replacing its recording.
        let mut source_availability = None;
        if !request.source.is_empty()
            && selected != request.source
            && self
                .download_manifest(&request.source)
                .is_ok_and(|m| m.has_type("download_provider"))
        {
            let availability = self.download_availability(&request.source, &request, lease.clone());
            check()?;
            if let Ok(availability) = availability
                && availability["skip_fallback"] == true
            {
                selected = request.source.clone();
                source_availability = Some(availability);
            }
        }
        if prepared != Some(true) {
            self.enrich_download_source(&mut request, lease.clone())?;
        }

        let mut last = None;
        let mut attempts = VecDeque::new();
        if !request.source.is_empty() && selected == request.source {
            attempts.push_back((request.source.clone(), true));
        }
        let mut fallback = Some(priority);
        loop {
            if attempts.is_empty() {
                let Some(priority) = fallback.take() else {
                    break;
                };
                let protected = if selected.is_empty() {
                    &request.source
                } else {
                    &selected
                };
                let priority = self.prioritize_healthy_downloads(priority, protected, &selected)?;
                attempts.extend(priority.into_iter().map(|id| (id, false)));
            }
            let Some((id, direct)) = attempts.pop_front() else {
                break;
            };
            check()?;
            if id.is_empty()
                || (!direct && id == request.source && request.source != selected)
                || (!direct
                    && id != selected
                    && !self
                        .fallback_allowed(&id)
                        .map_err(|error| error.to_string())?)
            {
                continue;
            }
            let Ok(manifest) = self.download_manifest(&id) else {
                continue;
            };
            if !manifest.has_type("download_provider") {
                continue;
            }
            let account_mode = self
                .account_download_enabled(&id)
                .map_err(|error| error.to_string())?;
            let availability = if direct {
                source_availability
                    .clone()
                    .unwrap_or_else(|| json!({"available":true}))
            } else {
                let available = self.preflight_download(&id, lease.clone()).map_err(|error| error.to_string())
                    .and_then(|verification| {
                        if verification { Err(format!("verification_required: extension '{id}' needs signed-session verification")) }
                        else { self.download_availability(&id, &request, lease.clone()) }
                    });
                check()?;
                match available {
                    Ok(value) => value,
                    Err(error) => {
                        let response = failure(&id, &error, "", 0);
                        if account_mode {
                            return Ok(response);
                        }
                        if response["error_type"] == "verification_required" {
                            self.cache_prepared(&key, &request, true);
                            return Ok(failure(
                                &id,
                                &format!("Download failed: {error}"),
                                "verification_required",
                                0,
                            ));
                        }
                        last = Some(response);
                        continue;
                    }
                }
            };
            let stop = availability["skip_fallback"] == true || account_mode;
            if availability["available"] != true {
                if stop {
                    return Ok(stopped(&id, &availability, ""));
                }
                continue;
            }
            let track_id = if direct {
                preferred_track_id(&request, &manifest, text(&availability, "track_id"))
            } else {
                text(&availability, "track_id").to_owned()
            };
            let mut attempt = request.clone();
            attempt.download_provider = id.clone();
            attempt.provider_track_id = track_id;
            if !direct {
                attempt.output_ext.clear();
            }
            let outcome =
                self.download_resolved(&attempt, &manifest, &availability, lease.clone())?;
            check()?;
            let response = match outcome {
                DownloadOutcome::Final(response) => return Ok(response),
                DownloadOutcome::Retry(response) => response,
            };
            let message = text(&response, "error");
            let kind = text(&response, "error_type");
            let retry = response["retry_after_seconds"].as_i64().unwrap_or_default();
            if account_mode
                || self
                    .account_download_enabled(&id)
                    .map_err(|error| error.to_string())?
            {
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    kind,
                    retry,
                ));
            }
            if kind == "verification_required" {
                self.cache_prepared(&key, &request, true);
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    kind,
                    retry,
                ));
            }
            if storage_failure(kind, message) {
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    "permission",
                    retry,
                ));
            }
            if stop {
                return Ok(stopped(&id, &availability, message));
            }
            if direct && manifest.stops_provider_fallback() {
                return Ok(failure(
                    &id,
                    &format!("Download failed: {message}"),
                    kind,
                    retry,
                ));
            }
            last = Some(response);
        }
        check()?;
        Ok(match last {
            Some(last) => failure(
                text(&last, "service"),
                &format!("All providers failed. Last error: {}", text(&last, "error")),
                if text(&last, "error_type") == "unknown" {
                    "not_found"
                } else {
                    text(&last, "error_type")
                },
                last["retry_after_seconds"].as_i64().unwrap_or_default(),
            ),
            None => failure(
                "",
                "No extension download providers available",
                "not_found",
                0,
            ),
        })
    }

    /// A preflight challenge can be satisfied without consulting optional
    /// metadata providers again. A different download source still gets its
    /// normal opportunity to prohibit fallback before any selected download.
    fn download_verified_retry(
        &self,
        request: &DownloadRequest,
        selected: &str,
        lease: Arc<RequestLease>,
    ) -> Result<Option<Value>, String> {
        if selected.is_empty()
            || (!request.source.is_empty()
                && !request.source.eq_ignore_ascii_case(selected)
                && self
                    .download_manifest(&request.source)
                    .is_ok_and(|manifest| manifest.has_type("download_provider")))
        {
            return Ok(None);
        }
        let Ok(manifest) = self.download_manifest(selected) else {
            return Ok(None);
        };
        if !manifest.has_type("download_provider") {
            return Ok(None);
        }
        let direct = request.source.eq_ignore_ascii_case(selected);
        let availability = if direct {
            json!({"available":true})
        } else {
            let result = self.download_availability(selected, request, lease.clone());
            lease.check_active().map_err(|error| error.to_string())?;
            match result {
                Ok(value) => value,
                Err(error) => {
                    let response = failure(selected, &format!("Download failed: {error}"), "", 0);
                    return Ok(
                        (response["error_type"] == "verification_required").then_some(response)
                    );
                }
            }
        };
        if availability["available"] != true {
            return Ok((availability["skip_fallback"] == true)
                .then(|| stopped(selected, &availability, "")));
        }
        let mut attempt = request.clone();
        attempt.download_provider = selected.into();
        attempt.provider_track_id =
            preferred_track_id(request, &manifest, text(&availability, "track_id"));
        if !direct {
            attempt.output_ext.clear();
        }
        let outcome = self.download_resolved(&attempt, &manifest, &availability, lease.clone())?;
        lease.check_active().map_err(|error| error.to_string())?;
        let response = match outcome {
            DownloadOutcome::Final(response) => return Ok(Some(response)),
            DownloadOutcome::Retry(response) => response,
        };
        let message = text(&response, "error");
        let kind = text(&response, "error_type");
        let retry = response["retry_after_seconds"].as_i64().unwrap_or_default();
        if kind == "verification_required" || storage_failure(kind, message) {
            return Ok(Some(failure(
                selected,
                &format!("Download failed: {message}"),
                if kind == "verification_required" {
                    kind
                } else {
                    "permission"
                },
                retry,
            )));
        }
        // Ordinary failures may recover after source enrichment supplies a
        // better native track ID. Preserve the normal strict/fallback path.
        Ok(None)
    }

    fn download_resolved(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
        availability: &Value,
        lease: Arc<RequestLease>,
    ) -> Result<DownloadOutcome, String> {
        let source = [&request.service, &request.source]
            .into_iter()
            .filter_map(|id| self.download_manifest(id.trim()).ok())
            .find(|manifest| manifest.find_quality(request.quality.trim()).is_some());
        let quality = match manifest.resolve_download_quality(&request.quality, source.as_ref()) {
            Ok(quality) => quality,
            Err(error) => {
                self.log_provider_failure(&request.download_provider, "quality selection", &error);
                return Ok(DownloadOutcome::Retry(failure(
                    &request.download_provider,
                    &error,
                    "quality_unavailable",
                    0,
                )));
            }
        };
        let mut attempt = request.clone();
        attempt.quality = quality;
        let outcome = self.download_attempt(&attempt, manifest, availability, lease)?;
        if let DownloadOutcome::Retry(response) = &outcome {
            self.log_provider_failure(
                &request.download_provider,
                "download",
                text(response, "error"),
            );
        }
        Ok(outcome)
    }

    fn download_availability(
        &self,
        id: &str,
        request: &DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<Value, String> {
        let input = ProviderAvailabilityRequest {
            isrc: request.isrc.clone(),
            track_name: request.track_name.clone(),
            artist_name: request.artist_name.clone(),
            spotify_id: request.spotify_id.clone(),
            deezer_id: request.deezer_id.clone(),
            tidal_id: request.tidal_id.clone(),
            qobuz_id: request.qobuz_id.clone(),
            duration_ms: request.duration_ms as isize,
            item_id: request.item_id.clone(),
            track: host_track(request).as_object().cloned(),
        };
        let result = self
            .check_availability_with_lease(id, input, 30_000, Some(lease))
            .map_err(|error| error.to_string())
            .and_then(|raw| serde_json::from_str::<Value>(&raw).map_err(|error| error.to_string()));
        match &result {
            Ok(value) if value["available"] != true => {
                self.log_provider_failure(id, "availability", text(value, "reason"));
            }
            Err(error) => self.log_provider_failure(id, "availability", error),
            _ => {}
        }
        result
    }

    fn log_provider_failure(&self, id: &str, stage: &str, reason: &str) {
        let reason = if reason.trim().is_empty() {
            "no reason supplied"
        } else {
            reason
        };
        let _ = self.environment().log_buffer().add(
            "WARN",
            "DownloadPlanner",
            &format!("Provider {id} failed during {stage}: {reason}"),
        );
    }

    fn enrich_download_source(
        &self,
        request: &mut DownloadRequest,
        lease: Arc<RequestLease>,
    ) -> Result<(), String> {
        if request.source.is_empty() {
            return Ok(());
        }
        if self
            .download_manifest(&request.source)
            .is_ok_and(|manifest| manifest.has_type("metadata_provider"))
        {
            let mut input = host_track(request);
            input["id"] = request.spotify_id.clone().into();
            for (key, value) in [
                ("provider_id", &request.source),
                ("spotify_id", &request.spotify_id),
                ("tidal_id", &request.tidal_id),
                ("qobuz_id", &request.qobuz_id),
                ("deezer_id", &request.deezer_id),
            ] {
                input[key] = value.clone().into();
            }
            let result = self.enrich_track_with_lease(
                &request.source,
                &input.to_string(),
                &request.item_id,
                30_000,
                Some(lease.clone()),
            );
            lease.check_active().map_err(|error| error.to_string())?;
            if let Ok(raw) = result
                && let Ok(track) = serde_json::from_str::<Value>(&raw)
            {
                apply_metadata(request, &track, true);
            }
        }
        if !request.track_name.is_empty()
            && !request.artist_name.is_empty()
            && (request.album_name.is_empty()
                || request.release_date.is_empty()
                || request.isrc.is_empty())
        {
            let result = self.search_metadata_providers_with_lease(
                &format!("{} {}", request.track_name, request.artist_name),
                5,
                true,
                &request.item_id,
                30_000,
                Some(lease.clone()),
            );
            lease.check_active().map_err(|error| error.to_string())?;
            if let Ok(raw) = result
                && let Ok(tracks) = serde_json::from_str::<Vec<Value>>(&raw)
                && let Some(track) = select_download_metadata(request, &tracks)
            {
                apply_metadata(request, track, false);
            }
        }
        Ok(())
    }

    fn download_attempt(
        &self,
        request: &DownloadRequest,
        manifest: &ExtensionManifest,
        availability: &Value,
        lease: Arc<RequestLease>,
    ) -> Result<DownloadOutcome, String> {
        let check = || {
            self.check()
                .and_then(|()| lease.check_active().map_err(|error| error.to_string()))
        };
        let environment = self.environment();
        let files = environment.native_files()?;
        let directory = environment
            .data_directory()
            .join(&manifest.name)
            .join("downloads");
        let path = output_path(request, &directory, &request.album_name, &check)?;
        let output = files.resolve_legacy(&path)?;
        output.native_display()?;
        let guard = files.lock(&output, &check)?;
        // The output lock also owns this destination's attempt directories.
        // Reclaim only that namespace after a process restart, including when
        // a complete file already exists but its finalizer still needs to run.
        let staging_prefix = format!(
            ".spotiflac-download-{}-",
            crate::binary::encode(
                &Sha256::digest(output.display().to_lowercase().as_bytes()),
                "hex"
            )
            .expect("hex encoding")
        );
        if directory.exists() {
            for entry in directory.read_dir().map_err(|error| error.to_string())? {
                check()?;
                let entry = entry.map_err(|error| error.to_string())?;
                if entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(&staging_prefix)
                    && entry
                        .file_type()
                        .map_err(|error| error.to_string())?
                        .is_dir()
                {
                    std::fs::remove_dir_all(entry.path()).map_err(|error| error.to_string())?;
                }
            }
        }
        if !request.allow_quality_variant
            && (request.album_folder_template.is_empty()
                || !album_folder(request, &request.album_name).is_empty())
            && output
                .metadata()
                .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
        {
            let mut result = json!({"file_path":path});
            probe_result(&files, &mut result, false, &check)?;
            let mut response = success(request, &result, &path, true, manifest, &check)?;
            response
                .as_object_mut()
                .unwrap()
                .remove("skip_metadata_enrichment");
            return Ok(DownloadOutcome::Final(response));
        }
        // Give the extension its own temporary directory. A mismatched track,
        // failed provider or cancellation can never overwrite an old library file.
        let temporary_parent =
            files.resolve_legacy(&directory.join(".parent").to_string_lossy())?;
        temporary_parent.native_display()?;
        temporary_parent
            .mkdir_parent()
            .map_err(|error| format!("failed to create directory: {error}"))?;
        let temporary = tempfile::Builder::new()
            .prefix(&staging_prefix)
            .tempdir_in(&directory)
            .map_err(|error| format!("failed to create directory: {error}"))?;
        let _grant = environment.grant_temporary_download_directory(temporary.path())?;
        let name = filename(request, &request.output_ext, &check)?;
        let staging_path = temporary.path().join(name).to_string_lossy().into_owned();
        let mut prepared = availability["prepared_context"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        prepared.insert("host_track".into(), host_track(request));
        if !request.item_id.is_empty() {
            let _ = environment
                .download_state()
                .progress
                .preparing(&request.item_id, "resolving_stream");
        }
        let response = self.download_with_lease(
            &manifest.name,
            ProviderDownloadRequest {
                track_id: request.provider_track_id.clone(),
                quality: request.quality.clone(),
                output_path: staging_path,
                item_id: request.item_id.clone(),
                prepared_context: Some(prepared),
            },
            60_000,
            Some(lease.clone()),
        );
        check()?;
        let mut result: Value = match response {
            Ok(raw) => serde_json::from_str(&raw).map_err(|error| error.to_string())?,
            Err(error) => {
                return Ok(DownloadOutcome::Retry(failure(
                    &manifest.name,
                    &error.to_string(),
                    "",
                    0,
                )));
            }
        };
        if result["success"] != true {
            let message = if text(&result, "error_message").is_empty() {
                "extension download failed without an error message"
            } else {
                text(&result, "error_message")
            };
            let kind = text(&result, "error_type").trim();
            let classified = native_error_response(message);
            let kind = if matches!(
                kind.to_ascii_lowercase().as_str(),
                "" | "unknown"
                    | "runtime_error"
                    | "api_error"
                    | "download_error"
                    | "extension_error"
            ) && classified["error_type"] != "unknown"
            {
                text(&classified, "error_type")
            } else if kind.is_empty() {
                "extension_error"
            } else {
                kind
            };
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                message,
                kind,
                result["retry_after_seconds"].as_i64().unwrap_or_default(),
            )));
        }
        let skip_names = request.source.trim().eq_ignore_ascii_case(&manifest.name)
            || manifest
                .track_matching
                .as_ref()
                .is_some_and(|matching| matching.custom_matching);
        if !matches_track(request, &result, skip_names) {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                &format!("provider {} returned a different track", manifest.name),
                "not_found",
                0,
            )));
        }
        let returned = text(&result, "file_path").trim();
        let already_exists = result["already_exists"] == true || returned.starts_with("EXISTS:");
        let returned = returned
            .strip_prefix("EXISTS:")
            .unwrap_or(returned)
            .to_owned();
        let input = files.resolve_legacy(&returned)?;
        input.native_display()?;
        if !already_exists
            && !crate::files::clean(Path::new(&returned)).starts_with(temporary.path())
        {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                "provider output is outside its download staging directory",
                "file_error",
                0,
            )));
        }
        if !input
            .metadata()
            .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
        {
            return Ok(DownloadOutcome::Retry(failure(
                &manifest.name,
                "provider returned no audio file",
                "file_error",
                0,
            )));
        }
        result["file_path"] = returned.clone().into();
        let mut enriched = request.clone();
        if !manifest.skip_metadata_enrichment {
            self.enrich_download_extended(&mut enriched, &check)?;
        }
        let request = &enriched;
        probe_result(
            &files,
            &mut result,
            request.album_name.trim().is_empty()
                && request.album_folder_template.contains("{album}"),
            &check,
        )?;
        if already_exists {
            return success(request, &result, &returned, true, manifest, &check)
                .map(DownloadOutcome::Final);
        }
        if !request.item_id.is_empty() {
            let _ = environment
                .download_state()
                .progress
                .finalizing(&request.item_id);
        }

        let mut response = success(request, &result, &path, false, manifest, &check)?;
        let mut resolved = request.clone();
        resolved.output_ext = text(&response, "actual_extension").to_owned();
        if !request.output_path.is_empty() {
            // SAF uses a local working path too. Keep its directory and stem,
            // but use the provider's actual container before final publication.
            resolved.output_path = Path::new(&request.output_path)
                .with_extension(resolved.output_ext.trim_start_matches('.'))
                .to_string_lossy()
                .into_owned();
        }
        let final_path = output_path(&resolved, &directory, text(&response, "album"), &check)?;
        // Keep the original lock for an unchanged destination. Release it
        // before acquiring a different path lock to avoid lock-order cycles.
        let destination = files.resolve_legacy(&final_path)?;
        destination.native_display()?;
        let _guard = if final_path == path {
            guard
        } else {
            drop(guard);
            files.lock(&destination, &check)?
        };
        if final_path != path && destination.metadata().is_ok() {
            return Ok(DownloadOutcome::Final(failure(
                &manifest.name,
                &format!("resolve album folder: open {final_path}: file exists"),
                "file_error",
                0,
            )));
        }
        let mut source = input
            .open(OpenOptions::new().read(true))
            .map_err(|error| error.to_string())?;
        let info = source.metadata().map_err(|error| error.to_string())?;
        if !info.is_file() || info.len() == 0 {
            return Err("provider returned no audio file".into());
        }
        // ReplayGain, decryption/conversion, external LRC and extension hooks
        // are executed by the existing Android/Dart finalizers. This is the
        // Go backend's local FLAC embed step; provider lyrics are reused.
        let embed = request.embed_metadata && resolved.output_ext == ".flac";
        let cover = if embed {
            let url = [text(&response, "cover_url"), &request.cover_url]
                .into_iter()
                .map(str::trim)
                .find(|url| !url.is_empty())
                .unwrap_or_default();
            if url.is_empty() {
                None
            } else {
                self.cover
                    .download(url, request.cover_max_dimension, &check)
                    .ok()
            }
        } else {
            None
        };
        check()?;
        let (mut staged, promoted) = if embed {
            destination.stage().map(|stage| (stage, false))
        } else {
            destination.stage_from(&input, &source)
        }
        .map_err(|error| format!("failed to create file: {error}"))?;
        if embed {
            let cover = cover.as_deref().filter(|bytes| !bytes.is_empty());
            embed_flac_metadata(
                &mut source,
                &mut staged.file,
                &download_metadata_fields(request, &response),
                &request.artist_tag_mode,
                cover,
                &check,
            )?;
            if cover.is_some()
                && extract_cover(&mut staged.file, "flac", &check)?
                    .data
                    .is_empty()
            {
                return Err(
                    "metadata embedded but cover verification failed: empty embedded cover".into(),
                );
            }
        } else if !promoted {
            let mut buffer = [0_u8; 65536];
            loop {
                check()?;
                let size = source
                    .read(&mut buffer)
                    .map_err(|error| error.to_string())?;
                if size == 0 {
                    break;
                }
                staged
                    .file
                    .write_all(&buffer[..size])
                    .map_err(|error| error.to_string())?;
            }
        }
        if final_path != path {
            if let Err(error) = staged.publish_new(&check) {
                check()?;
                let message = if error.kind() == std::io::ErrorKind::AlreadyExists {
                    format!("resolve album folder: open {final_path}: file exists")
                } else {
                    format!("resolve album folder: {error}")
                };
                return Ok(DownloadOutcome::Final(failure(
                    &manifest.name,
                    &message,
                    "file_error",
                    0,
                )));
            }
        } else {
            staged.publish(&check)?;
        }
        response["file_path"] = final_path.clone().into();
        if !request.output_dir.is_empty() && !text(&response, "isrc").trim().is_empty() {
            // Shared index only; never build a planner-specific cache.
            environment
                .invalidate_isrc_cache(&request.output_dir)
                .map_err(|error| error.to_string())?;
            environment
                .add_to_isrc_index(
                    destination
                        .absolute
                        .parent()
                        .unwrap_or(Path::new("."))
                        .to_string_lossy()
                        .as_ref(),
                    text(&response, "isrc").trim(),
                    &final_path,
                    &check,
                )
                .map_err(|error| error.to_string())?;
        }
        Ok(DownloadOutcome::Final(response))
    }

    fn enrich_download_extended(
        &self,
        request: &mut DownloadRequest,
        check: &Check<'_>,
    ) -> Result<(), String> {
        if request.isrc.is_empty() {
            return Ok(());
        }
        let needs_artist = request.album_artist.trim().is_empty();
        let needs_tags =
            request.genre.is_empty() || request.label.is_empty() || request.copyright.is_empty();
        let artist = || {
            self.fetch_music_brainz_album_artist_by_isrc(&request.isrc, &request.album_name, check)
        };
        let tags = || {
            self.metadata_operation(10, check, |check| {
                self.deezer
                    .get_extended_metadata_by_isrc(request.isrc.trim(), check)
            })
        };
        // These lookups are independent. Join the extra worker before returning
        // so cancellation and owner shutdown still cover both requests.
        let (artist, metadata) = if needs_artist && needs_tags && !request.isrc.trim().is_empty() {
            std::thread::scope(|scope| {
                let worker = std::thread::Builder::new()
                    .name("download-album-artist".into())
                    .spawn_scoped(scope, artist);
                let Ok(worker) = worker else {
                    let artist = artist();
                    check()?;
                    return Ok((Some(artist), Some(tags())));
                };
                let metadata = tags();
                let artist = worker
                    .join()
                    .map_err(|_| "album artist lookup panicked".to_owned())?;
                Ok::<_, String>((Some(artist), Some(metadata)))
            })?
        } else {
            let artist = needs_artist.then(artist);
            check()?;
            let metadata = (needs_tags && !request.isrc.trim().is_empty()).then(tags);
            (artist, metadata)
        };
        check()?;
        if let Some(Ok(artist)) = artist
            && !artist.trim().is_empty()
        {
            request.album_artist = artist.trim().into();
        }
        if let Some(metadata) = metadata {
            if let Ok(metadata) = metadata {
                for (target, value) in [
                    (&mut request.genre, &metadata.genre),
                    (&mut request.label, &metadata.label),
                    (&mut request.copyright, &metadata.copyright),
                ] {
                    if target.is_empty() {
                        *target = value.clone();
                    }
                }
            }
            if request.genre.is_empty() {
                let genre = self.fetch_music_brainz_genre_by_isrc(request.isrc.trim(), check);
                check()?;
                if let Ok(genre) = genre {
                    request.genre = genre;
                }
            }
        }
        check()
    }

    fn cache_prepared(&self, key: &str, request: &DownloadRequest, metadata_ready: bool) {
        if request.item_id.trim().is_empty() {
            return;
        }
        let mut cache = self
            .prepared_downloads
            .lock()
            .expect("prepared downloads lock");
        prune(&mut cache);
        cache.insert(
            request.item_id.trim().into(),
            Prepared {
                key: key.into(),
                request: request.clone(),
                metadata_ready,
                created: Instant::now(),
            },
        );
    }

    fn take_prepared(&self, key: &str, request: &mut DownloadRequest) -> Option<bool> {
        let mut cache = self
            .prepared_downloads
            .lock()
            .expect("prepared downloads lock");
        prune(&mut cache);
        let prepared = cache
            .remove(request.item_id.trim())
            .filter(|entry| entry.key == key)?;
        let mut fresh = serde_json::to_value(&*request).expect("download request serialization");
        let old = serde_json::to_value(prepared.request).expect("download request serialization");
        for key in [
            "isrc",
            "spotify_id",
            "track_name",
            "artist_name",
            "album_name",
            "album_artist",
            "cover_url",
            "track_number",
            "disc_number",
            "total_tracks",
            "total_discs",
            "release_date",
            "duration_ms",
            "genre",
            "label",
            "copyright",
            "composer",
            "tidal_id",
            "qobuz_id",
            "deezer_id",
        ] {
            fresh[key] = old[key].clone();
        }
        *request = serde_json::from_value(fresh).expect("typed download request");
        Some(prepared.metadata_ready)
    }
}

fn prune(cache: &mut PreparedDownloads) {
    cache.retain(|_, entry| entry.created.elapsed() < Duration::from_secs(300));
    while cache.len() >= 128 {
        let oldest = cache
            .iter()
            .min_by_key(|(_, entry)| entry.created)
            .map(|(id, _)| id.clone())
            .unwrap();
        cache.remove(&oldest);
    }
}

fn preparation_key(request: &DownloadRequest) -> String {
    [
        &request.item_id,
        &request.service,
        &request.source,
        &request.spotify_id,
        &request.tidal_id,
        &request.qobuz_id,
        &request.deezer_id,
        &request.track_name,
        &request.artist_name,
    ]
    .into_iter()
    .enumerate()
    .map(|(index, value)| {
        if matches!(index, 1 | 2 | 7 | 8) {
            value.trim().to_lowercase()
        } else {
            value.trim().to_owned()
        }
    })
    .collect::<Vec<_>>()
    .join("\n")
}

fn host_track(request: &DownloadRequest) -> Value {
    let mut track = serde_json::to_value(request).expect("download request serialization");
    let object = track.as_object_mut().unwrap();
    object.retain(|key, _| {
        matches!(
            key.as_str(),
            "album_name"
                | "album_artist"
                | "cover_url"
                | "release_date"
                | "track_number"
                | "total_tracks"
                | "disc_number"
                | "total_discs"
                | "duration_ms"
                | "isrc"
                | "genre"
                | "label"
                | "copyright"
                | "composer"
                | "comment"
                | "explicit"
                | "album_type"
                | "upc"
        )
    });
    object.insert("id".into(), request.provider_track_id.clone().into());
    object.insert("name".into(), request.track_name.clone().into());
    object.insert("artists".into(), request.artist_name.clone().into());
    track
}

fn download_metadata_fields(
    request: &DownloadRequest,
    response: &Value,
) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::new();
    for (tag, field, fallback) in [
        ("TITLE", "title", &request.track_name),
        ("ARTIST", "artist", &request.artist_name),
        ("ALBUM", "album", &request.album_name),
        ("ALBUMARTIST", "album_artist", &request.album_artist),
        ("DATE", "release_date", &request.release_date),
        ("ISRC", "isrc", &request.isrc),
        ("GENRE", "genre", &request.genre),
        ("ORGANIZATION", "label", &request.label),
        ("COPYRIGHT", "copyright", &request.copyright),
        ("COMPOSER", "composer", &request.composer),
        ("COMMENT", "comment", &request.comment),
        ("BARCODE", "upc", &request.upc),
    ] {
        let value = [text(response, field), fallback.as_str()]
            .into_iter()
            .map(str::trim)
            .find(|value| !value.is_empty())
            .unwrap_or_default();
        if !value.is_empty() {
            fields.insert(tag.into(), value.into());
        }
    }
    let positive = |field: &str, fallback: i64| {
        response[field]
            .as_i64()
            .filter(|value| *value > 0)
            .unwrap_or(fallback.max(0))
    };
    for (tag, number, total) in [
        (
            "TRACKNUMBER",
            positive("track_number", request.track_number),
            positive("total_tracks", request.total_tracks),
        ),
        (
            "DISCNUMBER",
            positive("disc_number", request.disc_number),
            positive("total_discs", request.total_discs),
        ),
    ] {
        if number > 0 {
            fields.insert(
                tag.into(),
                if total > 0 {
                    format!("{number}/{total}")
                } else {
                    number.to_string()
                },
            );
        }
    }
    if request.embed_lyrics && !text(response, "lyrics_lrc").is_empty() {
        for tag in ["LYRICS", "UNSYNCEDLYRICS"] {
            fields.insert(tag.into(), text(response, "lyrics_lrc").into());
        }
    }
    if response["explicit"] == true || request.explicit {
        fields.insert("ITUNESADVISORY".into(), "1".into());
    }
    let album_type = [text(response, "album_type"), &request.album_type]
        .into_iter()
        .map(str::trim)
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    if !album_type.is_empty() {
        fields.insert(
            "RELEASETYPE".into(),
            spotiflac_core::matching::lowercase(album_type),
        );
        if album_type.eq_ignore_ascii_case("compilation") {
            fields.insert("COMPILATION".into(), "1".into());
        }
    }
    fields
}

fn apply_metadata(request: &mut DownloadRequest, track: &Value, source: bool) {
    let mut value = serde_json::to_value(&*request).expect("download request serialization");
    for (target, key) in [
        ("track_name", "name"),
        ("artist_name", "artists"),
        ("album_name", "album_name"),
        ("album_artist", "album_artist"),
        ("spotify_id", "id"),
        ("isrc", "isrc"),
        ("cover_url", "cover_url"),
        ("release_date", "release_date"),
        ("genre", "genre"),
        ("label", "label"),
        ("copyright", "copyright"),
        ("composer", "composer"),
        ("comment", "comment"),
        ("album_type", "album_type"),
        ("upc", "upc"),
        ("tidal_id", "tidal_id"),
        ("qobuz_id", "qobuz_id"),
        ("deezer_id", "deezer_id"),
    ] {
        if !source
            && matches!(
                target,
                "track_name"
                    | "artist_name"
                    | "spotify_id"
                    | "comment"
                    | "tidal_id"
                    | "qobuz_id"
                    | "deezer_id"
            )
        {
            continue;
        }
        if (text(&value, target).is_empty()
            || (source && matches!(target, "isrc" | "tidal_id" | "qobuz_id" | "deezer_id")))
            && !text(track, key).is_empty()
        {
            value[target] = track[key].clone();
        }
    }
    for key in [
        "duration_ms",
        "track_number",
        "total_tracks",
        "disc_number",
        "total_discs",
    ] {
        if !source && key == "duration_ms" {
            continue;
        }
        if value[key] == 0 && track[key].as_i64().is_some_and(|number| number > 0) {
            value[key] = track[key].clone();
        }
    }
    if track["explicit"] == true {
        value["explicit"] = true.into();
    }
    *request = serde_json::from_value(value).expect("typed download metadata");
}

fn preferred_track_id(
    request: &DownloadRequest,
    manifest: &ExtensionManifest,
    explicit: &str,
) -> String {
    if !explicit.trim().is_empty() {
        return explicit.trim().into();
    }
    let replaces = manifest
        .capabilities
        .get("replacesBuiltInProviders")
        .and_then(Value::as_array);
    for (provider, native) in [
        ("tidal", &request.tidal_id),
        ("qobuz", &request.qobuz_id),
        ("deezer", &request.deezer_id),
        ("spotify", &request.spotify_id),
    ] {
        if replaces.is_some_and(|values| {
            values.iter().any(|value| {
                value
                    .as_str()
                    .is_some_and(|id| id.trim().eq_ignore_ascii_case(provider))
            })
        }) {
            if provider != "spotify" && !native.trim().is_empty() {
                return native.trim().into();
            }
            let id = request.spotify_id.trim();
            if !id.is_empty() {
                let prefix = format!("{provider}:");
                return if id.to_lowercase().starts_with(&prefix) {
                    id[prefix.len()..].into()
                } else {
                    id.into()
                };
            }
        }
    }
    [
        &request.spotify_id,
        &request.tidal_id,
        &request.qobuz_id,
        &request.deezer_id,
    ]
    .into_iter()
    .map(|value| value.trim())
    .find(|value| !value.is_empty())
    .unwrap_or_default()
    .into()
}

fn filename(
    request: &DownloadRequest,
    extension: &str,
    check: &Check<'_>,
) -> Result<String, String> {
    let mut metadata = host_track(request).as_object().cloned().unwrap();
    for (key, value) in [
        ("title", json!(request.track_name)),
        ("artist", json!(request.artist_name)),
        ("album", json!(request.album_name)),
        ("track", json!(request.track_number)),
        ("disc", json!(request.disc_number)),
        ("date", json!(request.release_date)),
        ("playlist_position", json!(request.playlist_position)),
        ("provider", json!(request.download_provider)),
        ("provider_id", json!(request.provider_track_id)),
        ("quality", json!(request.quality)),
        ("quality_variant", json!(request.quality_variant)),
    ] {
        metadata.insert(key.into(), value);
    }
    let name = build_filename_checked(&request.filename_format, &metadata, 1024 * 1024, check)?;
    let name = if name.trim().is_empty() {
        format!("{} - {}", request.artist_name, request.track_name)
    } else {
        name
    };
    let extension = if extension.trim().is_empty() {
        ".flac"
    } else {
        extension.trim()
    };
    Ok(format!(
        "{}{}{}",
        sanitize_filename_preserving_token(&name, &request.quality_variant),
        if extension.starts_with('.') { "" } else { "." },
        extension
    ))
}

fn album_folder(request: &DownloadRequest, album: &str) -> String {
    if !request.album_folder_template.contains("{album}") || album.trim().is_empty() {
        return String::new();
    }
    let name: String = request
        .album_folder_template
        .replace("{album}", album)
        .chars()
        .filter_map(|ch| {
            if ch < ' ' || ch == '\u{7f}' {
                None
            } else if "<>:\"/\\|?*".contains(ch) {
                Some(' ')
            } else {
                Some(ch)
            }
        })
        .collect();
    let mut name = name
        .trim_matches(['.', ' '])
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    while name.contains("__") {
        name = name.replace("__", "_");
    }
    let name = name.trim_matches(['_', ' ']);
    let mut end = name.len().min(120);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    name[..end].trim_matches(['.', '_', ' ']).into()
}

fn output_path(
    request: &DownloadRequest,
    temporary: &Path,
    album: &str,
    check: &Check<'_>,
) -> Result<String, String> {
    if !request.output_path.is_empty() {
        return Ok(request.output_path.clone());
    }
    let mut directory = if request.output_dir.is_empty() {
        temporary.to_owned()
    } else {
        PathBuf::from(&request.output_dir)
    };
    let folder = album_folder(request, album);
    if !request.output_dir.is_empty() && !folder.is_empty() {
        directory = crate::files::clean(&directory)
            .parent()
            .unwrap_or(Path::new("."))
            .join(folder);
    }
    Ok(directory
        .join(filename(request, &request.output_ext, check)?)
        .to_string_lossy()
        .into_owned())
}

fn probe_result(
    files: &crate::files::ExtensionFiles,
    result: &mut Value,
    album_pending: bool,
    check: &Check<'_>,
) -> Result<(), String> {
    let path = text(result, "file_path").to_owned();
    let file = files
        .resolve_legacy(&path)?
        .open(OpenOptions::new().read(true));
    if let Ok(mut file) = file {
        let mut header = [0; 8];
        // Quality is probed only for FLAC/MP4. Missing album folders may use
        // tags from any supported container, including undecoded audio.
        let has_header = file.read_exact(&mut header).is_ok();
        let container = if has_header && &header[..4] == b"fLaC" {
            "flac"
        } else if has_header && &header[4..] == b"ftyp" {
            "m4a"
        } else {
            ""
        };
        let quality = !container.is_empty();
        if quality {
            result["actual_container"] = container.into();
        }
        let album = album_pending && text(result, "album").trim().is_empty();
        if (quality || album)
            && file.seek(SeekFrom::Start(0)).is_ok()
            && let Ok(metadata) =
                spotiflac_core::tags::read_file_metadata(&mut file, &path, "", check)
        {
            if quality {
                for key in ["bit_depth", "sample_rate", "audio_codec"] {
                    result[key] = metadata[key].clone();
                }
            }
            if album {
                result["album"] = text(&metadata, "album").trim().into();
            }
        }
    }
    check()
}

fn matches_track(request: &DownloadRequest, result: &Value, skip_names: bool) -> bool {
    let exact = !request.isrc.is_empty()
        && !text(result, "isrc").is_empty()
        && request
            .isrc
            .trim()
            .eq_ignore_ascii_case(text(result, "isrc").trim());
    let identity = reenrich::Request {
        track_name: request.track_name.clone(),
        artist_name: request.artist_name.clone(),
        isrc: request.isrc.clone(),
        duration_ms: request.duration_ms,
        ..Default::default()
    };
    let mut candidate = result.clone();
    candidate["name"] = result.get("title").cloned().unwrap_or(json!(""));
    candidate["artists"] = result.get("artist").cloned().unwrap_or(json!(""));
    // Skipping names does not permit truncated previews or a duration mismatch.
    if skip_names && request.duration_ms / 1000 <= 0 {
        return true;
    }
    if skip_names
        && (result["duration_ms"].as_i64().unwrap_or_default() / 1000 <= 0
            || (request.duration_ms / 1000)
                .abs_diff(result["duration_ms"].as_i64().unwrap_or_default() / 1000)
                <= 10)
    {
        return true;
    }
    if !identity.verified(&candidate) {
        return false;
    }
    if !exact
        && !skip_names
        && !request.album_name.is_empty()
        && !text(result, "album").is_empty()
        && !titles_match(&request.album_name, text(result, "album"))
    {
        if !request.isrc.is_empty() && !text(result, "isrc").is_empty() {
            return false;
        }
        return strong_identity(request, result);
    }
    true
}

fn exact_identity(expected: &str, found: &str, normalize: fn(&str) -> String) -> bool {
    let (left, right) = (normalize(expected), normalize(found));
    if !left.is_empty() && !right.is_empty() {
        left == right
    } else {
        lowercase(expected.trim()) == lowercase(found.trim())
    }
}

fn duration_matches(request: &DownloadRequest, track: &Value) -> bool {
    let expected = request.duration_ms / 1000;
    let actual = track["duration_ms"].as_i64().unwrap_or_default() / 1000;
    expected > 0 && actual > 0 && expected.abs_diff(actual) <= 10
}

fn strong_identity(request: &DownloadRequest, track: &Value) -> bool {
    let title = text(track, "title");
    let artist = text(track, "artist");
    !request.track_name.is_empty()
        && !title.is_empty()
        && !request.artist_name.is_empty()
        && !artist.is_empty()
        && exact_identity(&request.track_name, title, track_identity_title)
        && (exact_identity(&request.artist_name, artist, normalize_loose_artist)
            || (artists_match(&request.artist_name, artist) && duration_matches(request, track)))
}

fn select_download_metadata<'a>(
    request: &DownloadRequest,
    tracks: &'a [Value],
) -> Option<&'a Value> {
    let mut best = None;
    let mut best_score = i32::MIN;
    for track in tracks {
        let isrc = text(track, "isrc").trim();
        let expected = request.isrc.trim();
        let exact = !expected.is_empty() && !isrc.is_empty() && expected.eq_ignore_ascii_case(isrc);
        if !expected.is_empty() && !isrc.is_empty() && !exact {
            continue;
        }
        let mut candidate = track.clone();
        for (target, source) in [
            ("title", "name"),
            ("artist", "artists"),
            ("album", "album_name"),
        ] {
            candidate[target] = text(track, source).into();
        }
        if !matches_track(request, &candidate, false)
            || (!exact && !strong_identity(request, &candidate))
        {
            continue;
        }
        let score = 2000
            + i32::from(exact) * 10000
            + i32::from(exact_identity(
                &request.track_name,
                text(track, "name"),
                normalize_title,
            )) * 400
            + i32::from(exact_identity(
                &request.artist_name,
                text(track, "artists"),
                normalize_loose_artist,
            )) * 320
            + i32::from(
                !request.album_name.is_empty()
                    && !text(track, "album_name").is_empty()
                    && titles_match(&request.album_name, text(track, "album_name")),
            ) * 120
            + i32::from(duration_matches(request, track)) * 80
            + i32::from(!text(track, "isrc").is_empty()) * 40
            + i32::from(!text(track, "album_name").is_empty()) * 30
            + i32::from(!text(track, "release_date").is_empty()) * 30
            + i32::from(
                track["track_number"]
                    .as_i64()
                    .is_some_and(|number| number > 0),
            ) * 10;
        if score > best_score {
            best_score = score;
            best = Some(track);
        }
    }
    best
}

fn success(
    request: &DownloadRequest,
    result: &Value,
    path: &str,
    exists: bool,
    manifest: &ExtensionManifest,
    check: &Check<'_>,
) -> Result<Value, String> {
    let mut response = json!({"success":true,"message":if exists { "File already exists".into() } else { format!("Downloaded from {}", manifest.name) },
        "file_path":path,"provider_track_id":request.provider_track_id,"already_exists":exists,"service":manifest.name,
        "actual_bit_depth":result["bit_depth"],"actual_sample_rate":result["sample_rate"],
        "audio_codec":text(result, "audio_codec").trim(),"actual_container":text(result, "actual_container").trim(),
        "requires_container_conversion":result["requires_container_conversion"] == true,
        "skip_metadata_enrichment":manifest.skip_metadata_enrichment,
        "explicit":request.explicit || result["explicit"] == true});
    for (key, requested, prefer_request) in [
        ("title", request.track_name.trim(), true),
        // Preserve source credits: an audio provider may list only the lead artist.
        ("artist", request.artist_name.trim(), true),
        ("album", request.album_name.trim(), true),
        ("album_artist", request.album_artist.as_str(), true),
        ("release_date", request.release_date.trim(), true),
        ("cover_url", request.cover_url.trim(), true),
        ("isrc", request.isrc.as_str(), false),
        ("genre", request.genre.as_str(), false),
        ("label", request.label.as_str(), false),
        ("copyright", request.copyright.as_str(), false),
        ("composer", request.composer.as_str(), false),
        ("comment", request.comment.trim(), true),
        ("album_type", request.album_type.as_str(), false),
        ("upc", request.upc.as_str(), false),
    ] {
        let provided = text(result, key);
        response[key] = if (prefer_request && !requested.is_empty()) || provided.is_empty() {
            requested
        } else {
            provided
        }
        .into();
    }
    for (key, value) in [
        ("track_number", request.track_number),
        ("disc_number", request.disc_number),
        ("total_tracks", request.total_tracks),
        ("total_discs", request.total_discs),
    ] {
        response[key] = if value != 0 {
            json!(value)
        } else {
            result.get(key).cloned().unwrap_or(json!(0))
        };
    }
    for key in ["lyrics_lrc", "decryption_key", "decryption"] {
        if let Some(value) = result.get(key) {
            response[key] = value.clone();
        }
    }
    let container = text(result, "actual_container")
        .trim()
        .trim_start_matches('.');
    let container = if [
        "flac", "m4a", "mp4", "mp3", "opus", "ogg", "aac", "wav", "aiff", "aif", "aifc",
    ]
    .iter()
    .any(|extension| container.eq_ignore_ascii_case(extension))
    {
        container
    } else {
        ""
    };
    let extension = [
        text(result, "actual_extension"),
        text(result, "output_extension"),
        container,
    ]
    .into_iter()
    .map(|value| value.trim().to_lowercase())
    .find(|value| !value.is_empty() && !value.contains(['/', '\\']))
    .unwrap_or_else(|| {
        // Providers may only return a renamed file_path, without explicit
        // format fields. The planned path still carries the requested quality.
        [text(result, "file_path"), path]
            .into_iter()
            .filter_map(|path| Path::new(path).extension())
            .map(|extension| extension.to_string_lossy().trim().to_lowercase())
            .find(|extension| !extension.is_empty())
            .unwrap_or_default()
    });
    if !extension.is_empty() {
        let extension = format!(".{}", extension.trim_start_matches('.'));
        response["actual_extension"] = if extension == ".mp4" {
            ".m4a".into()
        } else {
            extension.into()
        };
    }
    let mut named = request.clone();
    if !text(result, "isrc").trim().is_empty() {
        named.isrc = text(result, "isrc").trim().into();
    }
    response["resolved_file_name"] =
        filename(&named, text(&response, "actual_extension"), check)?.into();
    response["resolved_album_folder"] = album_folder(request, text(&response, "album")).into();
    Ok(response)
}

fn compact(mut value: Value) -> Value {
    value.as_object_mut().unwrap().retain(|key, value| {
        matches!(key.as_str(), "success" | "message")
            || !(value.is_null() || value == "" || value == false || value == 0)
    });
    value
}

fn failure(service: &str, message: &str, kind: &str, retry: i64) -> Value {
    let mut response = native_error_response(message);
    if !kind.is_empty() {
        response["error_type"] = kind.into();
    }
    response["service"] = service.into();
    response["retry_after_seconds"] = retry.into();
    response
}

fn stopped(service: &str, availability: &Value, message: &str) -> Value {
    let reason = if !text(availability, "reason").trim().is_empty() {
        text(availability, "reason").trim()
    } else if !message.is_empty() {
        message
    } else {
        "extension requested no further fallback"
    };
    let kind = native_error_response(reason);
    failure(
        service,
        &format!("Fallback stopped by {service}: {reason}"),
        if kind["error_type"] == "unknown" {
            "extension_error"
        } else {
            text(&kind, "error_type")
        },
        0,
    )
}

fn storage_failure(kind: &str, message: &str) -> bool {
    kind.eq_ignore_ascii_case("permission")
        || [
            "operation not permitted",
            "permission denied",
            "read-only file system",
            "failed to create file",
            "failed to create directory",
        ]
        .into_iter()
        .any(|part| message.to_lowercase().contains(part))
}

#[cfg(test)]
#[path = "download_latency_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "download_account_tests.rs"]
mod account_tests;

#[cfg(test)]
#[path = "download_container_tests.rs"]
mod container_tests;
