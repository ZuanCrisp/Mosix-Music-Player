//! Discord Rich Presence through the Discord client's local RPC IPC socket
//! (`discord-ipc-N`), the desktop replacement for the Discord Social SDK the
//! `mornye_discord` plugin uses on Android and iOS. Setting an activity over
//! IPC needs no OAuth, so desktop behaves like Android: no account link.
//!
//! Dart's `DiscordPresenceService` drives it with `discordPresenceInitialize`,
//! `discordPresenceUpdate`, `discordPresenceClear` and
//! `discordPresenceShutdown`; status changes come back as the inbound call
//! `discordPresenceStatus` with `"active"` or `"unavailable"`, the values the
//! mobile plugin reports.

use serde_json::{Map, Value, json};
use std::io::{self, Read, Write};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The Mosix application registered with Discord (same as mobile).
pub(crate) const CLIENT_ID: &str = "1549854098801692862";

const OP_HANDSHAKE: u32 = 0;
const OP_FRAME: u32 = 1;
const OP_CLOSE: u32 = 2;
const OP_PING: u32 = 3;
const OP_PONG: u32 = 4;
/// Discord rejects larger frames; ours are a few hundred bytes.
const MAX_FRAME: usize = 64 * 1024;
const ACTIVITY_TYPE_LISTENING: u8 = 2;

pub(crate) trait Ipc: Read + Write + Send {}

impl<T: Read + Write + Send> Ipc for T {}

type Connector = Arc<dyn Fn() -> io::Result<Box<dyn Ipc>> + Send + Sync>;
type StatusSink = Arc<dyn Fn(&'static str) + Send + Sync>;

enum Command {
    Update(Value),
    Clear,
    Shutdown,
}

pub(crate) struct Discord {
    connect: Connector,
    status: StatusSink,
    worker: Mutex<Option<Sender<Command>>>,
}

impl Default for Discord {
    fn default() -> Self {
        Self::new(
            Arc::new(connect_local),
            Arc::new(|status| crate::runtime::inbound("discordPresenceStatus", json!(status))),
        )
    }
}

impl Discord {
    pub(crate) fn new(connect: Connector, status: StatusSink) -> Self {
        Self {
            connect,
            status,
            worker: Mutex::new(None),
        }
    }

    /// Starts the worker. The IPC itself is always available; whether the
    /// Discord client runs is reported per update.
    pub(crate) fn initialize(&self) -> bool {
        let mut worker = self.worker.lock().expect("discord worker");
        if worker.is_none() {
            let (sender, receiver) = mpsc::channel();
            let connect = Arc::clone(&self.connect);
            let status = Arc::clone(&self.status);
            let spawned = std::thread::Builder::new()
                .name("mornye-discord".into())
                .spawn(move || run(receiver, connect, status));
            if spawned.is_err() {
                return false;
            }
            *worker = Some(sender);
        }
        true
    }

    pub(crate) fn update(&self, payload: Value) {
        self.send(Command::Update(payload));
    }

    pub(crate) fn clear(&self) {
        self.send(Command::Clear);
    }

    pub(crate) fn shutdown(&self) {
        if let Some(worker) = self.worker.lock().expect("discord worker").take() {
            let _ = worker.send(Command::Shutdown);
        }
    }

    fn send(&self, command: Command) {
        if let Some(worker) = self.worker.lock().expect("discord worker").as_ref() {
            let _ = worker.send(command);
        }
    }
}

fn run(commands: Receiver<Command>, connect: Connector, status: StatusSink) {
    let mut client: Option<Client> = None;
    while let Ok(command) = commands.recv() {
        match command {
            Command::Update(payload) => {
                let activity = activity(&payload);
                let result = (0..2).find_map(|_| {
                    if client.is_none() {
                        client = Client::open(&connect).ok();
                    }
                    let current = client.as_mut()?;
                    match current.set_activity(Some(&activity)) {
                        Ok(()) => Some(true),
                        // A restarted Discord client: reconnect once.
                        Err(error) if error.kind() != io::ErrorKind::InvalidData => {
                            client = None;
                            None
                        }
                        Err(_) => Some(false),
                    }
                });
                status(if result == Some(true) {
                    "active"
                } else {
                    "unavailable"
                });
            }
            Command::Clear => {
                if let Some(current) = client.as_mut()
                    && current.set_activity(None).is_err()
                {
                    client = None;
                }
            }
            Command::Shutdown => break,
        }
    }
    if let Some(mut current) = client {
        let _ = current.set_activity(None);
        let _ = current.write_frame(OP_CLOSE, &json!({}));
    }
}

/// The Rich Presence activity for the Dart payload
/// (`discordPresencePayload`: title, artist, state, artwork, start, end in
/// Unix seconds).
pub(crate) fn activity(payload: &Value) -> Value {
    let text = |key: &str| {
        let value = payload[key].as_str().unwrap_or("").trim();
        match value.chars().count() {
            0 => None,
            // Discord requires at least two characters.
            1 => Some(format!("{value}\u{2800}")),
            _ => Some(value.to_owned()),
        }
    };
    let mut activity = Map::new();
    activity.insert("type".into(), json!(ACTIVITY_TYPE_LISTENING));
    if let Some(title) = text("title") {
        activity.insert("details".into(), json!(title));
    }
    if let Some(state) = text("state").or_else(|| text("artist")) {
        activity.insert("state".into(), json!(state));
    }
    if let Some(artwork) = text("artwork") {
        activity.insert("assets".into(), json!({"large_image": artwork}));
    }
    let mut timestamps = Map::new();
    for key in ["start", "end"] {
        if let Some(seconds) = payload[key].as_i64().filter(|value| *value > 0) {
            timestamps.insert(key.into(), json!(seconds * 1000));
        }
    }
    if !timestamps.is_empty() {
        activity.insert("timestamps".into(), Value::Object(timestamps));
    }
    Value::Object(activity)
}

pub(crate) fn encode_frame(opcode: u32, payload: &Value) -> Vec<u8> {
    let body = payload.to_string().into_bytes();
    let mut frame = Vec::with_capacity(body.len() + 8);
    frame.extend_from_slice(&opcode.to_le_bytes());
    frame.extend_from_slice(&(body.len() as u32).to_le_bytes());
    frame.extend_from_slice(&body);
    frame
}

pub(crate) fn read_frame(reader: &mut impl Read) -> io::Result<(u32, Value)> {
    let mut header = [0u8; 8];
    reader.read_exact(&mut header)?;
    let opcode = u32::from_le_bytes(header[..4].try_into().expect("4 bytes"));
    let len = u32::from_le_bytes(header[4..].try_into().expect("4 bytes")) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body)?;
    let value = serde_json::from_slice(&body)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    Ok((opcode, value))
}

struct Client {
    stream: Box<dyn Ipc>,
    nonce: u64,
}

impl Client {
    fn open(connect: &Connector) -> io::Result<Self> {
        let mut client = Self {
            stream: connect()?,
            nonce: 0,
        };
        client.write_frame(OP_HANDSHAKE, &json!({"v": 1, "client_id": CLIENT_ID}))?;
        let (opcode, ready) = client.read_reply()?;
        if opcode != OP_FRAME || ready["evt"] != "READY" {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                "Discord refused the handshake",
            ));
        }
        Ok(client)
    }

    fn write_frame(&mut self, opcode: u32, payload: &Value) -> io::Result<()> {
        self.stream.write_all(&encode_frame(opcode, payload))?;
        self.stream.flush()
    }

    /// Reads the next frame, answering pings and failing on close.
    fn read_reply(&mut self) -> io::Result<(u32, Value)> {
        loop {
            let (opcode, value) = read_frame(&mut self.stream)?;
            match opcode {
                OP_PING => self.write_frame(OP_PONG, &value)?,
                OP_CLOSE => {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionAborted,
                        "Discord closed the connection",
                    ));
                }
                _ => return Ok((opcode, value)),
            }
        }
    }

    /// Errors with `InvalidData` mean Discord rejected the activity; other
    /// errors mean the connection is gone.
    fn set_activity(&mut self, activity: Option<&Value>) -> io::Result<()> {
        self.nonce += 1;
        let nonce = self.nonce.to_string();
        let request = json!({
            "cmd": "SET_ACTIVITY",
            "args": {"pid": std::process::id(), "activity": activity},
            "nonce": nonce,
        });
        self.write_frame(OP_FRAME, &request)?;
        loop {
            let (_, reply) = self.read_reply()?;
            if reply["nonce"] != nonce.as_str() {
                continue;
            }
            if reply["evt"] == "ERROR" {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    reply["data"]["message"]
                        .as_str()
                        .unwrap_or("Discord rejected the activity")
                        .to_owned(),
                ));
            }
            return Ok(());
        }
    }
}

#[cfg(unix)]
fn connect_local() -> io::Result<Box<dyn Ipc>> {
    use std::os::unix::net::UnixStream;
    let mut roots: Vec<std::path::PathBuf> = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
        .iter()
        .filter_map(std::env::var_os)
        .map(Into::into)
        .collect();
    roots.push("/tmp".into());
    // Flatpak and Snap Discord builds put the socket in a subdirectory.
    let subdirectories = ["", "app/com.discordapp.Discord", "snap.discord"];
    for root in &roots {
        for subdirectory in subdirectories {
            for index in 0..10 {
                let path = root.join(subdirectory).join(format!("discord-ipc-{index}"));
                if let Ok(stream) = UnixStream::connect(&path) {
                    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
                    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
                    return Ok(Box::new(stream));
                }
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "Discord is not running",
    ))
}

#[cfg(windows)]
fn connect_local() -> io::Result<Box<dyn Ipc>> {
    for index in 0..10 {
        let path = format!(r"\\?\pipe\discord-ipc-{index}");
        if let Ok(pipe) = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
        {
            return Ok(Box::new(pipe));
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "Discord is not running",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_a_listening_activity_in_milliseconds() {
        let activity = activity(&json!({
            "title": "Song",
            "artist": "Artist",
            "state": "Artist",
            "artwork": "https://example.com/cover.jpg",
            "start": 1_700_000_000,
            "end": 1_700_000_200,
        }));
        assert_eq!(
            activity,
            json!({
                "type": 2,
                "details": "Song",
                "state": "Artist",
                "assets": {"large_image": "https://example.com/cover.jpg"},
                "timestamps": {"start": 1_700_000_000_000i64, "end": 1_700_000_200_000i64},
            })
        );
    }

    #[test]
    fn omits_empty_fields_and_pads_short_text() {
        let activity = activity(&json!({"title": "X", "artist": "", "artwork": ""}));
        assert_eq!(activity, json!({"type": 2, "details": "X\u{2800}"}));
    }

    #[test]
    fn frames_round_trip() {
        let frame = encode_frame(OP_FRAME, &json!({"a": 1}));
        assert_eq!(&frame[..4], &1u32.to_le_bytes());
        assert_eq!(
            read_frame(&mut frame.as_slice()).unwrap(),
            (1, json!({"a": 1}))
        );
        let mut oversized = Vec::new();
        oversized.extend_from_slice(&1u32.to_le_bytes());
        oversized.extend_from_slice(&(MAX_FRAME as u32 + 1).to_le_bytes());
        assert!(read_frame(&mut oversized.as_slice()).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn talks_to_a_local_discord_server() {
        use std::os::unix::net::UnixListener;
        use std::sync::mpsc::channel;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("discord-ipc-0");
        let listener = UnixListener::bind(&path).unwrap();
        let (activities, received) = channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let (opcode, handshake) = read_frame(&mut stream).unwrap();
            assert_eq!(opcode, OP_HANDSHAKE);
            assert_eq!(handshake["client_id"], CLIENT_ID);
            stream
                .write_all(&encode_frame(
                    OP_FRAME,
                    &json!({"cmd": "DISPATCH", "evt": "READY"}),
                ))
                .unwrap();
            for _ in 0..2 {
                let (_, request) = read_frame(&mut stream).unwrap();
                // Unrelated traffic first: a ping the client must answer.
                stream
                    .write_all(&encode_frame(OP_PING, &json!({"n": 1})))
                    .unwrap();
                let (opcode, _) = read_frame(&mut stream).unwrap();
                assert_eq!(opcode, OP_PONG);
                stream
                    .write_all(&encode_frame(
                        OP_FRAME,
                        &json!({"cmd": "SET_ACTIVITY", "nonce": request["nonce"]}),
                    ))
                    .unwrap();
                activities
                    .send(request["args"]["activity"].clone())
                    .unwrap();
            }
        });

        let (statuses, status_events) = channel();
        let statuses = Mutex::new(statuses);
        let discord = Discord::new(
            Arc::new(move || {
                Ok(Box::new(std::os::unix::net::UnixStream::connect(&path)?) as Box<dyn Ipc>)
            }),
            Arc::new(move |status| {
                let _ = statuses.lock().unwrap().send(status);
            }),
        );
        assert!(discord.initialize());
        discord.update(json!({"title": "Song", "artist": "Artist"}));
        let timeout = Duration::from_secs(10);
        assert_eq!(received.recv_timeout(timeout).unwrap()["details"], "Song");
        assert_eq!(status_events.recv_timeout(timeout).unwrap(), "active");
        discord.clear();
        assert_eq!(received.recv_timeout(timeout).unwrap(), Value::Null);
        discord.shutdown();
        server.join().unwrap();
    }

    #[test]
    fn reports_unavailable_without_discord() {
        let (statuses, status_events) = mpsc::channel();
        let statuses = Mutex::new(statuses);
        let discord = Discord::new(
            Arc::new(|| Err(io::Error::new(io::ErrorKind::NotFound, "none"))),
            Arc::new(move |status| {
                let _ = statuses.lock().unwrap().send(status);
            }),
        );
        assert!(discord.initialize());
        discord.update(json!({"title": "Song"}));
        assert_eq!(
            status_events.recv_timeout(Duration::from_secs(5)).unwrap(),
            "unavailable"
        );
        discord.shutdown();
    }
}
