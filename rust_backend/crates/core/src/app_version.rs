//! One application version shared by native owners, VMs and HTTP clients.

use std::sync::{Arc, RwLock};

#[derive(Debug, Default)]
struct State {
    version: String,
    closed: bool,
}

#[derive(Clone, Debug, Default)]
pub struct AppVersion(Arc<RwLock<State>>);

#[derive(Clone, Copy, Debug)]
pub struct AppVersionClosed;

impl std::fmt::Display for AppVersionClosed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("application version state closed")
    }
}

impl std::error::Error for AppVersionClosed {}

impl AppVersion {
    pub fn get(&self) -> String {
        self.0
            .read()
            .expect("application version lock")
            .version
            .clone()
    }

    pub fn user_agent(&self) -> String {
        let version = self.get();
        if version.is_empty() {
            "Mosix".into()
        } else {
            format!("Mosix/{version}")
        }
    }

    pub fn set(&self, version: &str) -> Result<(), AppVersionClosed> {
        let mut state = self.0.write().expect("application version lock");
        if state.closed {
            return Err(AppVersionClosed);
        }
        state.version = version.trim().into();
        Ok(())
    }

    /// Reads keep the last snapshot for calls already unwinding. Owners reject
    /// new calls separately; no retained handle can change a closed version.
    pub fn close(&self) {
        self.0.write().expect("application version lock").closed = true;
    }
}

impl From<&str> for AppVersion {
    fn from(version: &str) -> Self {
        Self(Arc::new(RwLock::new(State {
            version: version.trim().into(),
            closed: false,
        })))
    }
}

impl From<String> for AppVersion {
    fn from(version: String) -> Self {
        Self::from(version.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::AppVersion;

    #[test]
    fn shared_updates_are_atomic_trimmed_and_cannot_outlive_the_owner() {
        let version = AppVersion::from("\u{0085} 1.0 \u{2003}");
        assert_eq!(version.get(), "1.0");
        let retained = version.clone();
        std::thread::scope(|scope| {
            for value in ["", "first version", "second version"] {
                let version = &version;
                scope.spawn(move || {
                    for _ in 0..1000 {
                        version.set(value).unwrap();
                        assert!(matches!(
                            version.user_agent().as_str(),
                            "Mosix"
                                | "Mosix/first version"
                                | "Mosix/second version"
                        ));
                    }
                });
            }
        });
        version.set("").unwrap();
        assert_eq!(retained.user_agent(), "Mosix");
        version.close();
        assert!(retained.set("new").is_err());
        assert_eq!(retained.get(), "");
        assert_eq!(AppVersion::from("separate owner").get(), "separate owner");
    }
}
