use super::{PENDING_TTL, PendingAuthRequest, State};
use crate::storage::{StorageMasterKey, atomic_write, decrypt, encrypt, valid_extension_id};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

#[derive(Serialize, Deserialize)]
pub(super) struct SavedPending {
    pub request: PendingAuthRequest,
    pub nonce: String,
    pub created_at: i128,
    pub verifier: String,
}

pub(super) struct PendingStore {
    path: PathBuf,
    key: Zeroizing<[u8; 32]>,
}

impl PendingStore {
    pub fn new(root: &Path, key: &StorageMasterKey) -> Self {
        Self {
            path: root.join(".pending-auth.enc"),
            key: key.derive("host", "pending-auth"),
        }
    }

    pub fn load(&self, now: i128) -> Result<Vec<SavedPending>, String> {
        let metadata = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(_) => return Err("cannot read pending verification".into()),
        };
        if !metadata.is_file() || metadata.len() > 2 * 1024 * 1024 {
            return Err("invalid pending verification file".into());
        }
        let encrypted = fs::read(&self.path).map_err(|_| "cannot read pending verification")?;
        let plaintext =
            decrypt(&encrypted, &self.key).map_err(|_| "invalid pending verification")?;
        let mut saved: Vec<SavedPending> =
            serde_json::from_slice(&plaintext).map_err(|_| "invalid pending verification")?;
        saved.retain(|entry| {
            valid_extension_id(&entry.request.extension_id)
                && !entry.nonce.is_empty()
                && (0..PENDING_TTL).contains(&(now - entry.created_at))
        });
        Ok(saved)
    }

    pub fn save(&self, state: &State, now: i128) -> Result<(), String> {
        let saved: Vec<_> = state
            .pending
            .values()
            .filter(|request| (0..PENDING_TTL).contains(&(now - request.created_at)))
            .map(|request| SavedPending {
                request: request.clone(),
                nonce: request.state.clone(),
                created_at: request.created_at,
                verifier: state
                    .records
                    .get(&request.extension_id)
                    .map(|record| record.verifier.to_string())
                    .unwrap_or_default(),
            })
            .collect();
        let bytes = Zeroizing::new(
            serde_json::to_vec(&saved).map_err(|_| "cannot encode pending verification")?,
        );
        let encrypted =
            encrypt(&bytes, &self.key).map_err(|_| "cannot encrypt pending verification")?;
        atomic_write(&self.path, &encrypted).map_err(|_| "cannot save pending verification".into())
    }
}
