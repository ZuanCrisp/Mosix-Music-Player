use rquickjs::{Coerced, Context, Ctx, FromJs, Function, Object, Persistent, Runtime, Value};
use spotiflac_core::cancellation::{CancellationError, RequestLease};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

mod json_input;

const MAX_INPUT_BYTES: usize = 8 * 1024 * 1024;
const MAX_TIMEOUT_MS: u64 = 300_000;
const QUEUE_CAPACITY: usize = 8;
const IDLE_GC_DELAY: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum LoadMode {
    Initialize,
    Register,
    Validate,
}

/// Hosts granted by the trusted extension manager after permission validation.
#[derive(Clone)]
pub struct ExtensionServices {
    pub legacy_backend: bool,
    pub(crate) lyrics: Weak<spotiflac_providers::lyrics::LyricsService>,
    pub(crate) lyrics_node: spotiflac_providers::lyrics::CallNode,
    pub(crate) lyrics_parent: Option<spotiflac_providers::lyrics::CallNode>,
    pub legacy_files: Option<Arc<crate::files::ExtensionFiles>>,
    pub isrc: Arc<spotiflac_core::isrc::IndexCache>,
    pub logs: Arc<crate::logging::LogBuffer>,
    pub extension_id: String,
    pub ffmpeg: Arc<crate::ffmpeg::CommandRegistry>,
    pub raw_ffmpeg_stub: bool,
    pub downloads: Arc<spotiflac_core::downloads::DownloadState>,
    pub storage: Option<Arc<crate::storage::ExtensionStore>>,
    pub files: Option<Arc<crate::files::ExtensionFiles>>,
    pub transfer_policy: crate::transfer_policy::DownloadTransferPolicy,
    pub network: Option<Arc<spotiflac_network::NetworkSession>>,
    pub auth: Option<Arc<crate::auth::ExtensionAuth>>,
    pub(crate) auth_registry: Option<Arc<crate::auth::AuthRegistry>>,
    pub session: Option<Arc<crate::signed_session::SignedSessionClient>>,
    pub app_version: spotiflac_core::app_version::AppVersion,
    pub(crate) parent_closed: Option<Arc<AtomicBool>>,
    pub(crate) startup_lease: Option<Arc<RequestLease>>,
    pub(crate) initialize_empty_settings: bool,
    pub(crate) load_mode: LoadMode,
    pub(crate) compiled_source: Option<Arc<CompiledSource>>,
}

impl Default for ExtensionServices {
    fn default() -> Self {
        Self {
            legacy_backend: false,
            lyrics: Weak::new(),
            lyrics_node: spotiflac_providers::lyrics::CallGraph::default().node(),
            lyrics_parent: None,
            legacy_files: None,
            isrc: Arc::new(spotiflac_core::isrc::IndexCache::default()),
            logs: Arc::new(crate::logging::LogBuffer::default()),
            extension_id: String::new(),
            ffmpeg: Arc::new(crate::ffmpeg::CommandRegistry::default()),
            raw_ffmpeg_stub: false,
            downloads: Arc::new(spotiflac_core::downloads::DownloadState::default()),
            storage: None,
            files: None,
            transfer_policy: crate::transfer_policy::DownloadTransferPolicy::default(),
            network: None,
            auth: None,
            auth_registry: None,
            session: None,
            app_version: Default::default(),
            parent_closed: None,
            startup_lease: None,
            initialize_empty_settings: true,
            load_mode: LoadMode::Initialize,
            compiled_source: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ExtensionError {
    #[error("extension runtime closed")]
    Closed,
    #[error("extension runtime busy")]
    Busy,
    #[error("execution timeout exceeded")]
    Timeout,
    #[error("{0}")]
    Cancelled(CancellationError),
    #[error("extension did not call registerExtension()")]
    NotRegistered,
    #[error("extension function not found: {0}")]
    MissingFunction(String),
    #[error("invalid extension input: {0}")]
    InvalidInput(String),
    #[error("{0}")]
    Script(String),
}

#[derive(Clone, Debug)]
pub struct RuntimeLimits {
    pub memory_bytes: usize,
    pub stack_bytes: usize,
    pub timeout_ms: u64,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            memory_bytes: 64 * 1024 * 1024,
            stack_bytes: 512 * 1024,
            timeout_ms: 30_000,
        }
    }
}

impl RuntimeLimits {
    fn validate(&self) -> Result<(), ExtensionError> {
        if !(1024 * 1024..=256 * 1024 * 1024).contains(&self.memory_bytes)
            || !(64 * 1024..=1024 * 1024).contains(&self.stack_bytes)
        {
            return Err(ExtensionError::InvalidInput(
                "memory must be 1–256 MiB and stack must be 64–1024 KiB".to_owned(),
            ));
        }
        Ok(())
    }

    fn timeout(&self, requested_ms: u64) -> Duration {
        let milliseconds = if requested_ms == 0 {
            self.timeout_ms.max(1)
        } else {
            requested_ms
        };
        Duration::from_millis(milliseconds.min(MAX_TIMEOUT_MS))
    }
}

struct Operation {
    item_id: String,
    deadline: Instant,
    lease: Option<Arc<RequestLease>>,
    resolution: Option<Arc<crate::resolution::ResolutionBudget>>,
}

#[derive(Default)]
pub(crate) struct Control {
    closed: AtomicBool,
    parent_closed: Option<Arc<AtomicBool>>,
    operation: Mutex<Option<Operation>>,
    waiter: Mutex<Option<Arc<thread::Thread>>>,
    #[cfg(test)]
    checks: std::sync::atomic::AtomicUsize,
}

pub(crate) struct ControlWait<'a>(&'a Control);

impl Drop for ControlWait<'_> {
    fn drop(&mut self) {
        self.0.waiter.lock().expect("extension waiter lock").take();
    }
}

impl Control {
    pub(crate) fn watch_thread(&self) -> ControlWait<'_> {
        let thread = Arc::new(thread::current());
        *self.waiter.lock().expect("extension waiter lock") = Some(Arc::clone(&thread));
        if let Some(lease) = self
            .operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .and_then(|operation| operation.lease.as_ref())
        {
            lease.observe_thread(&thread);
        }
        ControlWait(self)
    }

    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
        if let Some(thread) = self.waiter.lock().expect("extension waiter lock").as_ref() {
            thread.unpark();
        }
    }

    pub(crate) fn deadline_remaining(&self) -> Duration {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .map_or(Duration::from_millis(MAX_TIMEOUT_MS), |operation| {
                operation.deadline.saturating_duration_since(Instant::now())
            })
    }

    pub(crate) fn request_cancelled(&self) -> bool {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .and_then(|operation| operation.lease.as_ref())
            .is_some_and(|lease| lease.active_request_cancelled())
    }

    pub(crate) fn item_id(&self) -> String {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .map_or_else(String::new, |operation| operation.item_id.clone())
    }

    pub(crate) fn check(&self) -> Result<(), ExtensionError> {
        #[cfg(test)]
        self.checks.fetch_add(1, Ordering::Relaxed);
        if self.is_closed() {
            return Err(ExtensionError::Closed);
        }
        if let Some(operation) = &*self.operation.lock().expect("extension operation lock") {
            if let Some(lease) = &operation.lease {
                lease.check_active().map_err(ExtensionError::Cancelled)?;
            }
            if Instant::now() >= operation.deadline
                || operation
                    .resolution
                    .as_ref()
                    .is_some_and(|budget| budget.remaining().is_zero())
            {
                return Err(ExtensionError::Timeout);
            }
        }
        Ok(())
    }

    pub(crate) fn resolution(&self) -> Option<Arc<crate::resolution::ResolutionBudget>> {
        self.operation
            .lock()
            .expect("extension operation lock")
            .as_ref()
            .and_then(|operation| operation.resolution.clone())
    }

    fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
            || self
                .parent_closed
                .as_ref()
                .is_some_and(|closed| closed.load(Ordering::Acquire))
    }

    pub(crate) fn sleep(&self, duration: Duration) -> bool {
        let started = Instant::now();
        loop {
            if self.check().is_err() {
                return false;
            }
            let remaining = duration.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return true;
            }
            // Core leases and shutdown can be signalled from native threads.
            // A short heartbeat also observes deadlines while in a host call.
            thread::sleep(remaining.min(Duration::from_millis(10)));
        }
    }
}

type Reply = SyncSender<Result<String, ExtensionError>>;

#[derive(Clone, Copy)]
enum CallKind {
    Function,
    Lifecycle,
    Action,
    Provider,
    DownloadProvider,
    PostProcess,
}

enum Command {
    Call {
        method: String,
        arguments: String,
        operation: Operation,
        reply: Reply,
        kind: CallKind,
    },
    #[cfg(test)]
    InspectHeap(SyncSender<(i64, u64)>),
    Stop,
}

/// A stateful VM owned by one dedicated worker. No QuickJS value crosses threads.
///
/// Calls are serialized and bounded, including queue time, JS jobs, and host
/// utilities. An interrupted VM is retired: callers must reload the extension
/// rather than letting pending callbacks escape into a subsequent request.
pub struct ExtensionRuntime {
    pub(crate) compiled_source: Arc<CompiledSource>,
    lyrics_node: spotiflac_providers::lyrics::CallNode,
    lyrics_parent: Option<spotiflac_providers::lyrics::CallNode>,
    downloads: Arc<spotiflac_core::downloads::DownloadState>,
    sender: SyncSender<Command>,
    control: Arc<Control>,
    worker: Mutex<Option<JoinHandle<()>>>,
    limits: RuntimeLimits,
    session: Option<Arc<crate::signed_session::SignedSessionClient>>,
    network: Option<Arc<spotiflac_network::NetworkSession>>,
    native_calls: Mutex<usize>,
    native_idle: Condvar,
}

impl ExtensionRuntime {
    pub(crate) fn shared_source(&self) -> Arc<str> {
        Arc::clone(&self.compiled_source.source)
    }

    pub fn load(
        source: &str,
        settings_json: &str,
        limits: RuntimeLimits,
    ) -> Result<Self, ExtensionError> {
        Self::load_with_services(source, settings_json, limits, ExtensionServices::default())
    }

    pub fn load_with_services(
        source: &str,
        settings_json: &str,
        limits: RuntimeLimits,
        mut services: ExtensionServices,
    ) -> Result<Self, ExtensionError> {
        limits.validate()?;
        validate_size(source)?;
        let compiled_source = services
            .compiled_source
            .take()
            .filter(|cached| cached.source.as_ref() == source)
            .unwrap_or_else(|| {
                Arc::new(CompiledSource {
                    source: source.into(),
                    bytecode: OnceLock::new(),
                })
            });
        services.compiled_source = Some(Arc::clone(&compiled_source));
        let settings = validate_json(settings_json)?;
        if !settings.is_object() {
            return Err(ExtensionError::InvalidInput(
                "settings must be an object".to_owned(),
            ));
        }
        let control = Arc::new(Control {
            parent_closed: services.parent_closed.clone(),
            ..Control::default()
        });
        *control.operation.lock().expect("extension operation lock") = Some(Operation {
            item_id: String::new(),
            deadline: Instant::now() + limits.timeout(0),
            lease: services.startup_lease.clone(),
            resolution: None,
        });
        let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
        let (ready, result) = mpsc::sync_channel(1);
        let worker_control = Arc::clone(&control);
        let worker_limits = limits.clone();
        let source = Arc::clone(&compiled_source.source);
        let settings = settings_json.to_owned();
        let session = services.session.clone();
        let network = services.network.clone();
        let downloads = Arc::clone(&services.downloads);
        let lyrics_node = services.lyrics_node.clone();
        let lyrics_parent = services.lyrics_parent.clone();
        // Isolated VM loading happens while its primary manager engine is held.
        let _dependency = lyrics_parent
            .as_ref()
            .map(|parent| parent.wait_for(&lyrics_node))
            .transpose()
            .map_err(ExtensionError::Script)?;
        let worker = thread::Builder::new()
            .name("extension-js".to_owned())
            .stack_size(4 * 1024 * 1024)
            .spawn(move || {
                run_worker(
                    receiver,
                    ready,
                    &worker_control,
                    &worker_limits,
                    &source,
                    &settings,
                    &services,
                );
                worker_control.close();
            })
            .map_err(|error| ExtensionError::Script(format!("start extension worker: {error}")))?;
        let runtime = Self {
            compiled_source,
            lyrics_node,
            lyrics_parent,
            downloads,
            sender,
            control,
            worker: Mutex::new(Some(worker)),
            limits,
            session,
            network,
            native_calls: Mutex::new(0),
            native_idle: Condvar::new(),
        };
        result.recv().unwrap_or(Err(ExtensionError::Closed))?;
        Ok(runtime)
    }

    pub fn call(
        &self,
        method: &str,
        arguments_json: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<String, ExtensionError> {
        self.call_with_operation(
            method,
            arguments_json,
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + self.limits.timeout(timeout_ms),
                lease,
                resolution: None,
            },
            CallKind::Function,
        )
    }

    pub(crate) fn managed_call(
        &self,
        method: &str,
        arguments: &str,
        action: bool,
        timeout_ms: u64,
    ) -> Result<String, ExtensionError> {
        self.managed_call_with_lease(method, arguments, action, timeout_ms, None)
    }

    pub(crate) fn managed_call_with_lease(
        &self,
        method: &str,
        arguments: &str,
        action: bool,
        timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionError> {
        // Initialize/cleanup of a pooled VM also holds the primary engine.
        // Its regular download call runs without this dependency.
        let _dependency = self
            .lyrics_parent
            .as_ref()
            .map(|parent| parent.wait_for(&self.lyrics_node))
            .transpose()
            .map_err(ExtensionError::Script)?;
        self.call_with_operation(
            method,
            arguments,
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + self.limits.timeout(timeout_ms),
                lease,
                resolution: None,
            },
            if action {
                CallKind::Action
            } else {
                CallKind::Lifecycle
            },
        )
    }

    /// Read typed provider fields in the owning VM. Go's provider wrappers do
    /// not await a returned Promise; the provider object itself is parsed.
    pub(crate) fn call_provider_operation(
        &self,
        method: &str,
        arguments: &str,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
        item_id: String,
    ) -> Result<String, ExtensionError> {
        self.call_with_operation(
            method,
            arguments,
            Operation {
                item_id,
                deadline: Instant::now() + self.limits.timeout(timeout_ms),
                lease,
                resolution: None,
            },
            CallKind::Provider,
        )
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.control.is_closed()
    }

    pub(crate) fn call_post_process(
        &self,
        arguments: &str,
        timeout_ms: u64,
        item_id: &str,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionError> {
        self.call_with_operation(
            "postProcessV2",
            arguments,
            Operation {
                item_id: item_id.into(),
                deadline: Instant::now()
                    + self
                        .limits
                        .timeout(if timeout_ms == 0 { 120_000 } else { timeout_ms }),
                lease,
                resolution: None,
            },
            CallKind::PostProcess,
        )
    }

    pub(crate) fn network_session(&self) -> Option<Arc<spotiflac_network::NetworkSession>> {
        self.network.clone()
    }

    pub(crate) fn call_download_provider(
        &self,
        arguments: &str,
        item_id: &str,
        resolution_timeout_ms: u64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, (ExtensionError, bool)> {
        let lease = match lease {
            Some(lease) => lease,
            None => Arc::new(
                self.downloads
                    .acquire(item_id)
                    .map_err(|error| (ExtensionError::Cancelled(error), false))?,
            ),
        };
        if !item_id.is_empty() {
            let _ = self.downloads.progress.preparing(item_id, "");
        }
        let allowance = if resolution_timeout_ms == 0 {
            60_000
        } else {
            resolution_timeout_ms.min(MAX_TIMEOUT_MS)
        };
        let budget = crate::resolution::ResolutionBudget::new(Duration::from_millis(allowance));
        self.call_with_operation(
            "download",
            arguments,
            Operation {
                item_id: item_id.to_owned(),
                deadline: Instant::now() + Duration::from_secs(24 * 60 * 60),
                lease: Some(lease),
                resolution: Some(Arc::clone(&budget)),
            },
            CallKind::DownloadProvider,
        )
        .map_err(|error| (error, budget.remaining().is_zero()))
    }

    /// Native provider-manager entry point. Resolver/callback/retry time shares
    /// one allowance; established native media reads pause only that allowance.
    pub fn call_download(
        &self,
        method: &str,
        arguments_json: &str,
        lease: Option<Arc<RequestLease>>,
        resolution_timeout_ms: u64,
    ) -> Result<String, ExtensionError> {
        self.call_download_operation(
            method,
            arguments_json,
            lease,
            resolution_timeout_ms,
            String::new(),
        )
    }

    pub fn download_state(&self) -> Arc<spotiflac_core::downloads::DownloadState> {
        Arc::clone(&self.downloads)
    }

    fn call_download_operation(
        &self,
        method: &str,
        arguments_json: &str,
        lease: Option<Arc<RequestLease>>,
        resolution_timeout_ms: u64,
        item_id: String,
    ) -> Result<String, ExtensionError> {
        let allowance = if resolution_timeout_ms == 0 {
            60_000
        } else {
            resolution_timeout_ms.min(MAX_TIMEOUT_MS)
        };
        self.call_with_operation(
            method,
            arguments_json,
            Operation {
                item_id,
                deadline: Instant::now() + Duration::from_secs(24 * 60 * 60),
                lease,
                resolution: Some(crate::resolution::ResolutionBudget::new(
                    Duration::from_millis(allowance),
                )),
            },
            CallKind::Function,
        )
    }

    fn call_with_operation(
        &self,
        method: &str,
        arguments_json: &str,
        operation: Operation,
        kind: CallKind,
    ) -> Result<String, ExtensionError> {
        if self.control.is_closed() {
            return Err(ExtensionError::Closed);
        }
        let arguments = validate_json(arguments_json)?;
        if !arguments.is_array() {
            return Err(ExtensionError::InvalidInput(
                "arguments must be an array".to_owned(),
            ));
        }
        validate_size(method)?;
        if let Some(lease) = &operation.lease {
            lease.check_active().map_err(ExtensionError::Cancelled)?;
        }
        let (reply, result) = mpsc::sync_channel(1);
        let command = Command::Call {
            method: method.to_owned(),
            arguments: arguments_json.to_owned(),
            operation,
            reply,
            kind,
        };
        self.sender.try_send(command).map_err(|error| match error {
            TrySendError::Full(_) => ExtensionError::Busy,
            TrySendError::Disconnected(_) => ExtensionError::Closed,
        })?;
        result.recv().unwrap_or(Err(ExtensionError::Closed))
    }

    /// Session preflight touches thread-safe hosts without occupying the VM.
    pub fn preflight_signed_session(
        &self,
        lease: Option<Arc<RequestLease>>,
        timeout_ms: u64,
    ) -> Result<bool, ExtensionError> {
        let mut pending = self
            .native_calls
            .lock()
            .expect("extension native calls lock");
        if self.control.is_closed() {
            return Err(ExtensionError::Closed);
        }
        *pending += 1;
        drop(pending);
        let _operation = NativeOperation(self);
        let deadline = Instant::now() + self.limits.timeout(timeout_ms);
        let check = || {
            if self.control.is_closed() {
                return Err(ExtensionError::Closed);
            }
            if let Some(lease) = &lease {
                lease.check_active().map_err(ExtensionError::Cancelled)?;
            }
            if Instant::now() >= deadline {
                return Err(ExtensionError::Timeout);
            }
            Ok(())
        };
        check()?;
        let result = self.session.as_ref().map_or(Ok(false), |session| {
            session.preflight(|| check().map_err(|error| error.to_string()))
        });
        check()?;
        result.map_err(ExtensionError::Script)
    }

    pub fn take_verification_url(&self) -> String {
        self.session
            .as_ref()
            .map_or_else(String::new, |session| session.take_verification_url())
    }

    /// Terminal, idempotent interruption, including queued work. Does not run JS.
    /// A manager should call the extension's cleanup hook before orderly shutdown.
    pub fn shutdown(&self) {
        self.control.close();
        let _ = self.sender.try_send(Command::Stop);
        if let Some(worker) = self.worker.lock().expect("extension worker lock").take() {
            let _ = worker.join();
        }
        let mut pending = self
            .native_calls
            .lock()
            .expect("extension native calls lock");
        while *pending > 0 {
            pending = self
                .native_idle
                .wait(pending)
                .expect("extension native calls idle");
        }
    }
}

struct NativeOperation<'a>(&'a ExtensionRuntime);
impl Drop for NativeOperation<'_> {
    fn drop(&mut self) {
        let mut pending = self
            .0
            .native_calls
            .lock()
            .expect("extension native calls lock");
        *pending -= 1;
        self.0.native_idle.notify_all();
    }
}

impl Drop for ExtensionRuntime {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn run_worker(
    receiver: Receiver<Command>,
    ready: SyncSender<Result<(), ExtensionError>>,
    control: &Arc<Control>,
    limits: &RuntimeLimits,
    source: &str,
    settings: &str,
    services: &ExtensionServices,
) {
    let vm = match Vm::load(control, limits, source, settings, services) {
        Ok(vm) => vm,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    *control.operation.lock().expect("extension operation lock") = None;
    if services.load_mode == LoadMode::Validate {
        // Validation owns a fresh VM only until cleanup finishes. Keeping both
        // steps on this worker avoids a caller/worker round trip and never
        // exposes the validation VM to a later provider call.
        let result = vm.execute(
            control,
            "cleanup",
            "[]",
            Operation {
                item_id: String::new(),
                deadline: Instant::now() + limits.timeout(0),
                lease: None,
                resolution: None,
            },
            CallKind::Lifecycle,
        );
        if let Err(error) = lifecycle_result("cleanup", result) {
            let _ = services
                .logs
                .backend(&format!("[Extension] Cleanup error: {error}"));
        }
        let _ = ready.send(Ok(()));
        return;
    }
    if ready.send(Ok(())).is_err() {
        return;
    }
    // Reclaim unreachable cycles once after a burst. Reference-counted values
    // are already released; reachable extension state must remain untouched.
    let mut collect_at = Some(Instant::now() + IDLE_GC_DELAY);
    #[cfg(test)]
    let mut idle_collections = 0;
    loop {
        let command = if let Some(deadline) = collect_at {
            match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(command) => command,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => match receiver.try_recv() {
                    Ok(command) => command,
                    Err(mpsc::TryRecvError::Disconnected) => break,
                    Err(mpsc::TryRecvError::Empty) => {
                        if control.is_closed() {
                            break;
                        }
                        vm._runtime.run_gc();
                        collect_at = None;
                        #[cfg(test)]
                        {
                            idle_collections += 1;
                        }
                        continue;
                    }
                },
            }
        } else {
            match receiver.recv() {
                Ok(command) => command,
                Err(_) => break,
            }
        };
        #[cfg(test)]
        if let Command::InspectHeap(reply) = command {
            let _ = reply.send((
                vm._runtime.memory_usage().memory_used_size,
                idle_collections,
            ));
            continue;
        }
        let Command::Call {
            method,
            arguments,
            operation,
            reply,
            kind,
        } = command
        else {
            break;
        };
        let result = vm.execute(control, &method, &arguments, operation, kind);
        collect_at = Some(Instant::now() + IDLE_GC_DELAY);
        let _ = reply.send(result);
        if control.closed.load(Ordering::Acquire) {
            // Dropping receiver rejects all queued callers. No stale jobs survive.
            break;
        }
    }
}

pub(crate) fn lifecycle_result(
    method: &str,
    output: Result<String, ExtensionError>,
) -> Result<(), ExtensionError> {
    let result: serde_json::Value = serde_json::from_str(&output?)
        .map_err(|error| ExtensionError::Script(error.to_string()))?;
    if result["success"] == false {
        return Err(ExtensionError::Script(format!(
            "{method} failed: {}",
            result["error"].as_str().unwrap_or("unknown error")
        )));
    }
    Ok(())
}

struct Vm {
    gateway: Persistent<Object<'static>>,
    context: Context,
    // Drop the context and its persistent values before the owning runtime.
    _runtime: Runtime,
}

pub(crate) struct CompiledSource {
    source: Arc<str>,
    bytecode: OnceLock<Vec<u8>>,
}

fn builtin_factory<'js>(
    ctx: &Ctx<'js>,
    source: &'static str,
    cache: &OnceLock<Vec<u8>>,
) -> rquickjs::Result<Function<'js>> {
    Function::from_js(ctx, eval_cached(ctx, source, cache, true)?)
}

// Bytecode is compiled locally by this engine. Each VM decodes its own objects;
// installed source caches belong to one primary runtime/install generation.
#[allow(unsafe_code)]
fn eval_cached<'js>(
    ctx: &Ctx<'js>,
    source: &str,
    cache: &OnceLock<Vec<u8>>,
    strict: bool,
) -> rquickjs::Result<Value<'js>> {
    use rquickjs::qjs;

    let context = ctx.as_raw().as_ptr();
    // Match Ctx::eval's stack bookkeeping before entering QuickJS.
    unsafe { qjs::JS_UpdateStackTop(qjs::JS_GetRuntime(context)) };
    let compiled = if let Some(bytes) = cache.get() {
        // JS_ReadObject accepts only bytecode produced locally by this engine.
        unsafe {
            qjs::JS_ReadObject(
                context,
                bytes.as_ptr(),
                bytes.len() as _,
                qjs::JS_READ_OBJ_BYTECODE as i32,
            )
        }
    } else {
        let mut source = source.as_bytes().to_vec();
        source.push(0);
        let flags = qjs::JS_EVAL_TYPE_GLOBAL
            | qjs::JS_EVAL_FLAG_COMPILE_ONLY
            | if strict { qjs::JS_EVAL_FLAG_STRICT } else { 0 };
        // The owned value belongs to this context; its RAII wrapper releases it
        // on every return path, including compilation/serialization failure.
        let compiled = unsafe {
            Value::from_raw(
                ctx.clone(),
                qjs::JS_Eval(
                    context,
                    source.as_ptr().cast(),
                    (source.len() - 1) as _,
                    if strict {
                        c"eval_script".as_ptr()
                    } else {
                        c"index.js".as_ptr()
                    },
                    flags as i32,
                ),
            )
        };
        if compiled.is_exception() {
            return Err(rquickjs::Error::Exception);
        }
        let mut len = 0;
        let buffer = unsafe {
            qjs::JS_WriteObject(
                context,
                &mut len,
                compiled.as_raw(),
                qjs::JS_WRITE_OBJ_BYTECODE as i32,
            )
        };
        if buffer.is_null() {
            // Caching is optional under memory/stack pressure. Keep the already
            // compiled script and let execution enforce the VM's limits.
            drop(ctx.catch());
        } else {
            if len as usize <= MAX_INPUT_BYTES {
                let bytes = unsafe { std::slice::from_raw_parts(buffer, len as _).to_vec() };
                let _ = cache.set(bytes);
            }
            unsafe { qjs::js_free(context, buffer.cast()) };
        }
        // Give JS_EvalFunction its own reference; the wrapper still releases
        // both its original value and context reference on this branch.
        unsafe { qjs::JS_DupValue(context, compiled.as_raw()) }
    };
    if unsafe { qjs::JS_IsException(compiled) } {
        return Err(rquickjs::Error::Exception);
    }
    // JS_EvalFunction consumes compiled. Only its owned result gets a wrapper.
    let result = unsafe { Value::from_raw(ctx.clone(), qjs::JS_EvalFunction(context, compiled)) };
    if result.is_exception() {
        return Err(rquickjs::Error::Exception);
    }
    Ok(result)
}

impl Vm {
    fn load(
        control: &Arc<Control>,
        limits: &RuntimeLimits,
        source: &str,
        settings: &str,
        services: &ExtensionServices,
    ) -> Result<Self, ExtensionError> {
        let runtime = Runtime::new().map_err(|error| ExtensionError::Script(error.to_string()))?;
        runtime.set_memory_limit(limits.memory_bytes);
        runtime.set_max_stack_size(limits.stack_bytes);
        let interrupt = Arc::clone(control);
        runtime.set_interrupt_handler(Some(Box::new(move || interrupt.check().is_err())));
        let context =
            Context::full(&runtime).map_err(|error| ExtensionError::Script(error.to_string()))?;
        let gateway = context.with(|ctx| {
            static PRELUDE: OnceLock<Vec<u8>> = OnceLock::new();
            static PROVIDER: OnceLock<Vec<u8>> = OnceLock::new();
            let host = crate::host::register(&ctx, Arc::clone(control), services)
                .map_err(|error| script_error(&ctx, control, error))?;
            let factory = builtin_factory(&ctx, include_str!("prelude.js"), &PRELUDE)
                .map_err(|error| script_error(&ctx, control, error))?;
            let gateway: Object = factory
                .call((host.clone(),))
                .map_err(|error| script_error(&ctx, control, error))?;
            let provider_factory = builtin_factory(&ctx, include_str!("provider.js"), &PROVIDER)
                .map_err(|error| script_error(&ctx, control, error))?;
            let helpers: Object = gateway
                .get("providerHelpers")
                .map_err(|error| script_error(&ctx, control, error))?;
            let provider: Object = provider_factory
                .call((host, helpers))
                .map_err(|error| script_error(&ctx, control, error))?;
            gateway
                .set("provider", provider)
                .map_err(|error| script_error(&ctx, control, error))?;
            // Goja compiles extension scripts without forcing strict mode.
            let cache = &services
                .compiled_source
                .as_ref()
                .expect("local source cache")
                .bytecode;
            eval_cached(&ctx, source, cache, false)
                .map_err(|error| script_error(&ctx, control, error))?;
            drain_jobs(&ctx, control)?;
            let registered: Function = gateway
                .get("registered")
                .map_err(|error| script_error(&ctx, control, error))?;
            if !registered
                .call::<_, bool>(())
                .map_err(|error| script_error(&ctx, control, error))?
            {
                return Err(ExtensionError::NotRegistered);
            }
            Ok(Persistent::save(&ctx, gateway))
        })?;
        let vm = Self {
            gateway,
            context,
            _runtime: runtime,
        };
        let empty_settings = validate_json(settings)?.is_empty_object();
        if services.load_mode == LoadMode::Initialize
            && (services.initialize_empty_settings || !empty_settings)
        {
            vm.call(
                control,
                "initialize",
                &format!("[{settings}]"),
                true,
                CallKind::Function,
            )?;
        }
        control.check()?;
        Ok(vm)
    }

    fn execute(
        &self,
        control: &Control,
        method: &str,
        arguments: &str,
        operation: Operation,
        kind: CallKind,
    ) -> Result<String, ExtensionError> {
        *control.operation.lock().expect("extension operation lock") = Some(operation);
        // A queued cancellation/expiry has not touched the VM and need not retire it.
        if let Err(error) = control.check() {
            *control.operation.lock().expect("extension operation lock") = None;
            return Err(error);
        }
        let result = self.call(control, method, arguments, false, kind);
        // A thrown synchronous error can still leave Promise jobs in the queue.
        let jobs = self.context.with(|ctx| drain_jobs(&ctx, control));
        let result = result.and_then(|value| jobs.map(|()| value));
        let interruption = control.check().err();
        *control.operation.lock().expect("extension operation lock") = None;
        if interruption.is_some() {
            // Callers must see the retired VM before handling its interruption.
            control.close();
        }
        interruption.map_or(result, Err)
    }

    fn call(
        &self,
        control: &Control,
        method: &str,
        arguments: &str,
        optional: bool,
        kind: CallKind,
    ) -> Result<String, ExtensionError> {
        self.context.with(|ctx| {
            let result = (|| -> rquickjs::Result<Option<Value<'_>>> {
                let gateway = self.gateway.clone().restore(&ctx)?;
                if matches!(
                    kind,
                    CallKind::Provider | CallKind::DownloadProvider | CallKind::PostProcess
                ) {
                    let provider: Object = gateway.get("provider")?;
                    let invoke: Function =
                        provider.get(if matches!(kind, CallKind::DownloadProvider) {
                            "invokeDownload"
                        } else if matches!(kind, CallKind::PostProcess) {
                            "invokePostProcess"
                        } else {
                            "invoke"
                        })?;
                    let arguments: rquickjs::Array = ctx.json_parse(arguments)?.get()?;
                    return Ok(Some(invoke.call((method, arguments))?));
                }
                if !matches!(kind, CallKind::Function) {
                    let invoke: Function = gateway.get("invokeManaged")?;
                    let arguments: rquickjs::Array = ctx.json_parse(arguments)?.get()?;
                    return Ok(Some(invoke.call((
                        matches!(kind, CallKind::Action),
                        method,
                        arguments,
                    ))?));
                }
                let get: Function = gateway.get("getExtension")?;
                let extension: Value = get.call(())?;
                let Some(object) = extension.as_object() else {
                    return Ok(None);
                };
                let function: Value = object.get(method)?;
                let Some(function) = function.as_function() else {
                    return Ok(None);
                };
                let arguments: rquickjs::Array = ctx.json_parse(arguments)?.get()?;
                let mut args = rquickjs::function::Args::new(ctx.clone(), arguments.len());
                args.this(object.clone())?;
                for argument in arguments.iter::<Value>() {
                    args.push_arg(argument?)?;
                }
                Ok(Some(function.call_arg(args)?))
            })()
            .map_err(|error| script_error(&ctx, control, error))?;
            let Some(mut value) = result else {
                return if optional {
                    Ok("null".to_owned())
                } else {
                    Err(ExtensionError::MissingFunction(method.to_owned()))
                };
            };
            if !optional
                && matches!(kind, CallKind::Function)
                && let Some(promise) = value.as_promise()
            {
                value = loop {
                    control.check()?;
                    if let Some(result) = promise.result::<Value>() {
                        break result.map_err(|error| script_error(&ctx, control, error))?;
                    }
                    if !ctx.execute_pending_job() {
                        if ctx.has_exception() {
                            return Err(script_error(&ctx, control, rquickjs::Error::Exception));
                        }
                        control.sleep(Duration::from_millis(10));
                    }
                };
            }
            drain_jobs(&ctx, control)?;
            if optional {
                // The Go manager ignores initialize's return value.
                return Ok("null".to_owned());
            }
            let gateway = self
                .gateway
                .clone()
                .restore(&ctx)
                .map_err(|error| script_error(&ctx, control, error))?;
            if matches!(
                kind,
                CallKind::Provider | CallKind::DownloadProvider | CallKind::PostProcess
            ) {
                let provider: Object = gateway
                    .get("provider")
                    .map_err(|error| script_error(&ctx, control, error))?;
                let parse: Function = provider
                    .get(if matches!(kind, CallKind::PostProcess) {
                        "parsePostProcess"
                    } else {
                        "parse"
                    })
                    .map_err(|error| script_error(&ctx, control, error))?;
                let json: String = parse
                    .call((method, value))
                    .map_err(|error| script_error(&ctx, control, error))?;
                drain_jobs(&ctx, control)?;
                control.check()?;
                return Ok(json);
            }
            let serialize: Function = gateway
                .get("serialize")
                .map_err(|error| script_error(&ctx, control, error))?;
            let json: String = serialize
                .call((value,))
                .map_err(|error| script_error(&ctx, control, error))?;
            // Go export serialization may execute extension-defined getters and jobs.
            drain_jobs(&ctx, control)?;
            control.check()?;
            Ok(json)
        })
    }
}

fn drain_jobs(ctx: &Ctx<'_>, control: &Control) -> Result<(), ExtensionError> {
    loop {
        control.check()?;
        let ran = ctx.execute_pending_job();
        if ctx.has_exception() {
            return Err(script_error(ctx, control, rquickjs::Error::Exception));
        }
        if !ran {
            return Ok(());
        }
    }
}

fn script_error(ctx: &Ctx<'_>, control: &Control, error: rquickjs::Error) -> ExtensionError {
    if let Err(interruption) = control.check() {
        return interruption;
    }
    let message = if error.is_exception() {
        Coerced::<String>::from_js(ctx, ctx.catch())
            .map(|message| message.0)
            .unwrap_or_else(|_| "JavaScript exception".to_owned())
    } else {
        error.to_string()
    };
    // Even converting a thrown value to text may execute arbitrary JS.
    control
        .check()
        .err()
        .unwrap_or(ExtensionError::Script(message))
}

fn validate_size(value: &str) -> Result<(), ExtensionError> {
    if value.len() > MAX_INPUT_BYTES {
        return Err(ExtensionError::InvalidInput(
            "input exceeds 8 MiB".to_owned(),
        ));
    }
    Ok(())
}

fn validate_json(value: &str) -> Result<json_input::Shape, ExtensionError> {
    validate_size(value)?;
    serde_json::from_str(value).map_err(|error| ExtensionError::InvalidInput(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_collects_once_after_idle_burst_and_preserves_live_state() {
        let runtime = ExtensionRuntime::load(
            "let calls=0;const keep={value:'live-state'};registerExtension({allocate(){const cycle={bytes:new Uint8Array(16*1024*1024)};cycle.self=cycle;return ++calls;},state(){return {calls,value:keep.value};}});",
            "{}",
            RuntimeLimits::default(),
        )
        .unwrap();
        let snapshot = || {
            let (reply, result) = mpsc::sync_channel(1);
            runtime.sender.send(Command::InspectHeap(reply)).unwrap();
            result.recv_timeout(Duration::from_secs(5)).unwrap()
        };
        assert_eq!(runtime.call("allocate", "[]", None, 0).unwrap(), "1");
        let (retained, collections) = snapshot();
        let deadline = Instant::now() + Duration::from_secs(5);
        let collected = loop {
            thread::sleep(Duration::from_millis(25));
            let (bytes, count) = snapshot();
            if count > collections {
                assert_eq!(count, collections + 1);
                break bytes;
            }
            assert!(Instant::now() < deadline, "idle collection did not run");
        };
        assert!(retained - collected >= 16 * 1024 * 1024);
        thread::sleep(IDLE_GC_DELAY + Duration::from_millis(50));
        assert_eq!(
            snapshot().1,
            collections + 1,
            "clean idle VM collected again"
        );
        let state: serde_json::Value =
            serde_json::from_str(&runtime.call("state", "[]", None, 0).unwrap()).unwrap();
        assert_eq!(state, serde_json::json!({"calls":1,"value":"live-state"}));
        eprintln!(
            "actual worker idle GC: before_bytes={retained} after_bytes={collected} freed_bytes={} collections=1",
            retained - collected
        );
        runtime.shutdown();
    }

    #[test]
    fn idle_gc_reclaims_unreachable_cycles_without_changing_live_state() {
        let source = "let calls=0; const keep={value:'live-state'}; registerExtension({allocate(){const cycle={bytes:new Uint8Array(16*1024*1024)};cycle.self=cycle;return ++calls;},state(){return {calls,value:keep.value};}});";
        let control = Arc::new(Control::default());
        let services = ExtensionServices {
            compiled_source: Some(Arc::new(CompiledSource {
                source: source.into(),
                bytecode: OnceLock::new(),
            })),
            ..ExtensionServices::default()
        };
        let vm = Vm::load(&control, &RuntimeLimits::default(), source, "{}", &services).unwrap();
        vm._runtime.run_gc();
        let baseline = vm._runtime.memory_usage().memory_used_size;
        let call = |method| {
            vm.execute(
                &control,
                method,
                "[]",
                Operation {
                    item_id: String::new(),
                    deadline: Instant::now() + Duration::from_secs(5),
                    lease: None,
                    resolution: None,
                },
                CallKind::Function,
            )
            .unwrap()
        };
        assert_eq!(call("allocate"), "1");
        let retained = vm._runtime.memory_usage().memory_used_size;
        let started = Instant::now();
        vm._runtime.run_gc();
        let elapsed = started.elapsed();
        let collected = vm._runtime.memory_usage().memory_used_size;
        assert!(retained - collected >= 16 * 1024 * 1024);
        let state: serde_json::Value = serde_json::from_str(&call("state")).unwrap();
        assert_eq!(state, serde_json::json!({"calls":1,"value":"live-state"}));
        eprintln!(
            "QuickJS isolated idle cycle probe: baseline_bytes={baseline} retained_bytes={retained} after_gc_bytes={collected} freed_bytes={} gc_us={}",
            retained - collected,
            elapsed.as_micros()
        );
    }

    #[test]
    fn argument_validation_rejects_before_execution_and_keeps_runtime_usable() {
        let runtime = ExtensionRuntime::load(
            "let calls=0; registerExtension({echo(value){return {calls:++calls,value}}});",
            "{}",
            RuntimeLimits::default(),
        )
        .unwrap();
        for input in ["{}", "[1e400]", "[\"\\uD800\"]", "[] true"] {
            assert!(matches!(
                runtime.call("echo", input, None, 0),
                Err(ExtensionError::InvalidInput(_))
            ));
        }
        let input = "[{\"title\":\"音楽 🎵\",\"nested\":[true,null,{\"key\":\"value\"}]}]";
        let output: serde_json::Value =
            serde_json::from_str(&runtime.call("echo", input, None, 0).unwrap()).unwrap();
        assert_eq!(output["calls"], 1);
        assert_eq!(output["value"]["title"], "音楽 🎵");
        assert_eq!(output["value"]["nested"][2]["key"], "value");
    }

    #[test]
    fn cached_source_still_obeys_each_vms_memory_and_stack_limits() {
        let source = "registerExtension({allocate(){const a=[];while(true)a.push(new Uint8Array(65536));},recurse(){function f(){return 1+f()}return f()}});";
        let primary = ExtensionRuntime::load(source, "{}", RuntimeLimits::default()).unwrap();
        let runtime = ExtensionRuntime::load_with_services(
            source,
            "{}",
            RuntimeLimits {
                memory_bytes: 2 << 20,
                stack_bytes: 128 << 10,
                ..Default::default()
            },
            ExtensionServices {
                compiled_source: Some(Arc::clone(&primary.compiled_source)),
                ..Default::default()
            },
        )
        .unwrap();
        for method in ["recurse", "allocate"] {
            assert!(
                matches!(
                    runtime.call(method, "[]", None, 1000),
                    Err(ExtensionError::Script(_))
                ),
                "{method}"
            );
        }
    }

    #[test]
    fn compiled_source_reuses_bytecode_but_isolates_state_settings_and_new_source() {
        let source = "let n=0,s={};registerExtension({initialize(v){s=v;if(v.spin)while(true){}},next(){return [++n,s.id]}});";
        let primary =
            ExtensionRuntime::load(source, "{\"id\":0}", RuntimeLimits::default()).unwrap();
        let cache = Arc::clone(&primary.compiled_source);
        assert!(cache.bytecode.get().is_some());
        thread::scope(|scope| {
            let workers: Vec<_> = (1..=4)
                .map(|id| {
                    let cache = Arc::clone(&cache);
                    scope.spawn(move || {
                        let runtime = ExtensionRuntime::load_with_services(
                            source,
                            &format!("{{\"id\":{id}}}"),
                            RuntimeLimits::default(),
                            ExtensionServices {
                                compiled_source: Some(Arc::clone(&cache)),
                                ..Default::default()
                            },
                        )
                        .unwrap();
                        assert!(Arc::ptr_eq(&cache, &runtime.compiled_source));
                        assert_eq!(
                            runtime.call("next", "[]", None, 1000).unwrap(),
                            format!("[1,{id}]")
                        );
                        assert_eq!(
                            runtime.call("next", "[]", None, 1000).unwrap(),
                            format!("[2,{id}]")
                        );
                    })
                })
                .collect();
            for worker in workers {
                worker.join().unwrap();
            }
        });
        assert_eq!(primary.call("next", "[]", None, 1000).unwrap(), "[1,0]");
        let timed_out = ExtensionRuntime::load_with_services(
            source,
            "{\"spin\":true}",
            RuntimeLimits {
                timeout_ms: 30,
                ..Default::default()
            },
            ExtensionServices {
                compiled_source: Some(Arc::clone(&cache)),
                ..Default::default()
            },
        );
        assert!(matches!(timed_out, Err(ExtensionError::Timeout)));
        let changed = ExtensionRuntime::load_with_services(
            "registerExtension({next(){return 99}});",
            "{}",
            RuntimeLimits::default(),
            ExtensionServices {
                compiled_source: Some(Arc::clone(&cache)),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(!Arc::ptr_eq(&cache, &changed.compiled_source));
        assert_eq!(changed.call("next", "[]", None, 1000).unwrap(), "99");
    }

    #[test]
    fn ffmpeg_waits_for_completion_cancellation_or_deadline_without_polling() {
        use spotiflac_core::cancellation::{CancellationDomain, CancellationRegistry};
        for mode in [
            "complete",
            "cancel",
            "release",
            "cancel-shutdown",
            "close",
            "shutdown",
            "timeout",
        ] {
            let registry = crate::ffmpeg::CommandRegistry::default();
            let cancellation = CancellationRegistry::new(CancellationDomain::Download);
            let lease = Arc::new(cancellation.acquire("example").unwrap());
            let control = Control::default();
            *control.operation.lock().unwrap() = Some(Operation {
                item_id: "example".into(),
                deadline: Instant::now()
                    + if mode == "timeout" {
                        Duration::from_millis(100)
                    } else {
                        Duration::from_secs(1)
                    },
                lease: Some(Arc::clone(&lease)),
                resolution: None,
            });
            thread::scope(|scope| {
                let worker = scope.spawn(|| {
                    registry.execute("example", vec![], "in".into(), "out".into(), &control)
                });
                let pending: serde_json::Value =
                    serde_json::from_str(&registry.wait_pending_json(500).unwrap()).unwrap();
                let id = pending[0]["command_id"].as_str().unwrap();
                thread::sleep(Duration::from_millis(45));
                assert!(
                    control.checks.load(Ordering::Relaxed) <= 3,
                    "FFmpeg polled during {mode}"
                );
                let result = || crate::ffmpeg::CommandResult {
                    success: true,
                    output: "done".into(),
                    error: String::new(),
                };
                let began = Instant::now();
                match mode {
                    "complete" => {
                        assert!(registry.complete(id, result()).unwrap());
                    }
                    "cancel" => cancellation.cancel("example").unwrap(),
                    "release" => lease.release(),
                    "cancel-shutdown" => cancellation.shutdown(),
                    "close" => control.close(),
                    "shutdown" => registry.shutdown(),
                    _ => {}
                }
                let finished = worker.join().unwrap();
                assert!(
                    began.elapsed() < Duration::from_millis(300),
                    "late wake: {mode}"
                );
                if mode == "complete" {
                    assert!(finished.unwrap().success);
                } else {
                    assert!(finished.is_err(), "{mode}");
                }
                if mode != "shutdown" {
                    assert!(!registry.complete(id, result()).unwrap());
                }
            });
        }
    }

    #[test]
    fn interrupted_worker_is_closed_before_publishing_its_reply() {
        let services = ExtensionServices::default();
        services.logs.set_enabled(true).unwrap();
        let logs = Arc::clone(&services.logs);
        let downloads = Arc::clone(&services.downloads);
        let runtime = ExtensionRuntime::load_with_services(
            "registerExtension({spin(){log.info('entered');while(true){}}});",
            "{}",
            RuntimeLimits::default(),
            services,
        )
        .unwrap();
        // A rendezvous reply holds the worker at publication until we receive.
        // This makes the ordering assertion independent of thread scheduling.
        let (reply, result) = mpsc::sync_channel(0);
        assert!(
            runtime
                .sender
                .send(Command::Call {
                    method: "spin".into(),
                    arguments: "[]".into(),
                    operation: Operation {
                        item_id: "example-item".into(),
                        deadline: Instant::now() + Duration::from_secs(10),
                        lease: Some(Arc::new(downloads.acquire("example-item").unwrap())),
                        resolution: None,
                    },
                    reply,
                    kind: CallKind::Function,
                })
                .is_ok()
        );
        let began = Instant::now();
        while logs.count().unwrap() == 0 {
            assert!(
                began.elapsed() < Duration::from_secs(2),
                "VM did not enter spin"
            );
            thread::sleep(Duration::from_millis(1));
        }
        downloads.cancel("example-item").unwrap();
        let began = Instant::now();
        while !runtime.is_closed() && began.elapsed() < Duration::from_secs(1) {
            thread::sleep(Duration::from_millis(1));
        }
        let closed_before_reply = runtime.is_closed();
        let response = result.recv_timeout(Duration::from_secs(2)).unwrap();
        runtime.shutdown();
        assert_eq!(
            response,
            Err(ExtensionError::Cancelled(
                CancellationError::DownloadCancelled
            ))
        );
        assert!(
            closed_before_reply,
            "interrupted worker published before closing"
        );
    }
}
