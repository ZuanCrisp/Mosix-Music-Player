use chrono::{DateTime, Datelike, Timelike, Utc};
use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalTime {
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    weekday: u32,
    offset_minutes: i32,
    timezone: String,
    timestamp: i64,
}

pub fn local_time() -> LocalTime {
    local_time_at(Utc::now().timestamp()).expect("current timestamp fits calendar range")
}

pub fn local_time_at(timestamp: i64) -> Result<LocalTime, String> {
    let (offset, _, timezone) = zone_at(timestamp);
    let local = DateTime::from_timestamp(
        timestamp
            .checked_add(i64::from(offset))
            .ok_or("timestamp overflow")?,
        0,
    )
    .ok_or("timestamp outside calendar range")?;
    Ok(LocalTime {
        year: local.year(),
        month: local.month(),
        day: local.day(),
        hour: local.hour(),
        minute: local.minute(),
        second: local.second(),
        weekday: local.weekday().num_days_from_sunday(),
        offset_minutes: -(offset / 60),
        timezone,
        timestamp,
    })
}

pub(crate) fn zone_at(timestamp: i64) -> (i32, String, String) {
    // Go 1.26's Android and iOS initLocal use UTC. Host Unix builds load TZ or
    // /etc/localtime once; retain that distinction in the compatibility SDK.
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let _ = timestamp;
        (0, "UTC".into(), "UTC".into())
    }
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        static LOCAL: std::sync::LazyLock<(tz::TimeZone, String)> =
            std::sync::LazyLock::new(load_zone);
        let (zone, name) = &*LOCAL;
        match zone.find_local_time_type(timestamp) {
            Ok(kind) => (
                kind.ut_offset(),
                kind.time_zone_designation().into(),
                name.clone(),
            ),
            Err(_) => (0, "UTC".into(), "UTC".into()),
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn load_zone() -> (tz::TimeZone, String) {
    use std::io::Read;
    let load = |path: &std::path::Path| {
        let file = std::fs::File::open(path).ok()?;
        let mut data = Vec::new();
        file.take(10 * 1024 * 1024 + 1)
            .read_to_end(&mut data)
            .ok()?;
        if data.len() > 10 * 1024 * 1024 {
            return None;
        }
        tz::TimeZone::from_tz_data(&data).ok()
    };
    let configured = std::env::var("TZ").ok();
    if configured.is_none() {
        if let Some(zone) = load(std::path::Path::new("/etc/localtime")) {
            return (zone, "Local".into());
        }
    } else if let Some(raw) = configured {
        let name = raw.strip_prefix(':').unwrap_or(&raw);
        if name.starts_with('/') {
            if let Some(zone) = load(std::path::Path::new(name)) {
                return (
                    zone,
                    if name == "/etc/localtime" {
                        "Local"
                    } else {
                        name
                    }
                    .into(),
                );
            }
        } else if !name.is_empty() && name != "UTC" && !name.contains("..") {
            for directory in [
                "/usr/share/zoneinfo",
                "/usr/share/lib/zoneinfo",
                "/usr/lib/locale/TZ",
                "/etc/zoneinfo",
            ] {
                if let Some(zone) = load(&std::path::Path::new(directory).join(name)) {
                    return (zone, name.into());
                }
            }
        }
    }
    (tz::TimeZone::utc(), "UTC".into())
}
