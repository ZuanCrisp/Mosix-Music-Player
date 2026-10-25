//! Commands executed by the native FFmpeg pump, scoped to one environment.

use serde::Serialize;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

static NEXT_COMMAND: AtomicU64 = AtomicU64::new(0);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Clone, Debug, Serialize)]
pub struct Command {
    pub command_id: String,
    pub extension_id: String,
    pub arguments: Vec<String>,
    pub input_path: String,
    pub output_path: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct CommandResult {
    pub success: bool,
    pub output: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
}

struct Entry {
    command: Command,
    claimed: bool,
    result: Option<CommandResult>,
    waiter: std::thread::Thread,
}

#[derive(Default)]
struct State {
    commands: BTreeMap<String, Entry>,
    closed: bool,
}

#[derive(Default)]
pub struct CommandRegistry {
    state: Mutex<State>,
    changed: Condvar,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("FFmpeg command registry closed")]
pub struct RegistryClosed;

impl CommandRegistry {
    pub fn get(&self, id: &str) -> Result<Option<Command>, RegistryClosed> {
        let state = self.state.lock().expect("FFmpeg state lock");
        state.check()?;
        Ok(state.commands.get(id).map(|entry| entry.command.clone()))
    }

    /// Claims each command at most once, even with multiple native pumps.
    /// A zero/negative timeout performs a nonblocking claim. Shutdown wakes waits.
    pub fn wait_pending_json(&self, timeout_ms: i64) -> Result<String, RegistryClosed> {
        let started = Instant::now();
        let timeout = Duration::from_millis(timeout_ms.clamp(0, 60_000) as u64);
        let mut state = self.state.lock().expect("FFmpeg state lock");
        loop {
            state.check()?;
            let commands = state.claim_pending();
            let remaining = timeout.saturating_sub(started.elapsed());
            if commands != "[]" || remaining.is_zero() {
                return Ok(commands);
            }
            state = self
                .changed
                .wait_timeout(state, remaining)
                .expect("FFmpeg pending wait")
                .0;
        }
    }

    /// Late or duplicate results cannot complete another command or revive one
    /// removed by cancellation. The native pump can use get() to stop such work.
    pub fn complete(&self, id: &str, result: CommandResult) -> Result<bool, RegistryClosed> {
        let mut state = self.state.lock().expect("FFmpeg state lock");
        state.check()?;
        let Some(entry) = state.commands.get_mut(id) else {
            return Ok(false);
        };
        if entry.result.is_some() {
            return Ok(false);
        }
        entry.result = Some(result);
        entry.waiter.unpark();
        self.changed.notify_all();
        Ok(true)
    }

    pub fn shutdown(&self) {
        let mut state = self.state.lock().expect("FFmpeg state lock");
        state.closed = true;
        for entry in state.commands.values() {
            entry.waiter.unpark();
        }
        state.commands.clear();
        self.changed.notify_all();
    }

    pub(crate) fn execute(
        &self,
        extension_id: &str,
        arguments: Vec<String>,
        input_path: String,
        output_path: String,
        control: &crate::runtime::Control,
    ) -> Result<CommandResult, String> {
        let _wait = control.watch_thread();
        let check = || control.check().map_err(|error| error.to_string());
        check()?;
        let sequence = NEXT_COMMAND.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let id = format!("{extension_id}_{sequence}");
        let command = Command {
            command_id: id.clone(),
            extension_id: extension_id.into(),
            arguments,
            input_path,
            output_path,
        };
        {
            let mut state = self.state.lock().expect("FFmpeg state lock");
            state.check().map_err(|e| e.to_string())?;
            state.commands.insert(
                id.clone(),
                Entry {
                    command,
                    claimed: false,
                    result: None,
                    waiter: std::thread::current(),
                },
            );
            self.changed.notify_all();
        }
        let _pending = Pending {
            registry: self,
            id: &id,
        };
        let started = Instant::now();
        let mut state = self.state.lock().expect("FFmpeg state lock");
        loop {
            check().map_err(|e| format!("FFmpeg command cancelled: {e}"))?;
            state.check().map_err(|e| e.to_string())?;
            if state
                .commands
                .get(&id)
                .is_some_and(|entry| entry.result.is_some())
            {
                return Ok(state
                    .commands
                    .remove(&id)
                    .expect("completed FFmpeg command")
                    .result
                    .expect("FFmpeg result"));
            }
            let remaining = COMMAND_TIMEOUT.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return Err("FFmpeg command timed out".into());
            }
            drop(state);
            std::thread::park_timeout(remaining.min(control.deadline_remaining()));
            state = self.state.lock().expect("FFmpeg state lock");
        }
    }
}

impl State {
    fn check(&self) -> Result<(), RegistryClosed> {
        if self.closed {
            Err(RegistryClosed)
        } else {
            Ok(())
        }
    }

    fn claim_pending(&mut self) -> String {
        #[derive(Serialize)]
        struct PendingCommand<'a> {
            command_id: &'a str,
            extension_id: &'a str,
            arguments: &'a [String],
            output_path: &'a str,
        }
        let pending: Vec<_> = self
            .commands
            .values_mut()
            .filter(|entry| !entry.claimed && entry.result.is_none())
            .map(|entry| {
                entry.claimed = true;
                PendingCommand {
                    command_id: &entry.command.command_id,
                    extension_id: &entry.command.extension_id,
                    arguments: &entry.command.arguments,
                    output_path: &entry.command.output_path,
                }
            })
            .collect();
        serde_json::to_string(&pending).expect("FFmpeg pending JSON")
    }
}

struct Pending<'a> {
    registry: &'a CommandRegistry,
    id: &'a str,
}

impl Drop for Pending<'_> {
    fn drop(&mut self) {
        self.registry
            .state
            .lock()
            .expect("FFmpeg state lock")
            .commands
            .remove(self.id);
        self.registry.changed.notify_all();
    }
}

impl Drop for CommandRegistry {
    fn drop(&mut self) {
        self.shutdown();
    }
}
