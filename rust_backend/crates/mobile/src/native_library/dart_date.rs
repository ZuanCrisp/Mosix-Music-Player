//! DateTime.parse's accepted ISO subset, including compact dates, fractional
//! truncation and overflowing components used by old JSON backups.
use chrono::{DateTime, Duration, Local, NaiveDate, NaiveDateTime, SecondsFormat, TimeZone, Utc};
use regex::Regex;
use std::sync::OnceLock;

pub(crate) struct Parsed {
    pub instant: DateTime<Utc>,
    pub local: Option<NaiveDateTime>,
}

pub(crate) fn parse(value: &str) -> Option<Parsed> {
    static FORMAT: OnceLock<Regex> = OnceLock::new();
    let format=FORMAT.get_or_init(||Regex::new(r"^([+-]?[0-9]{4,6})-?([0-9]{2})-?([0-9]{2})(?:[ T]([0-9]{2})(?::?([0-9]{2})(?::?([0-9]{2})(?:[.,]([0-9]+))?)?)?( ?[zZ]| ?([-+])([0-9]{2})(?::?([0-9]{2}))?)?)?$").expect("Dart ISO pattern"));
    let parts = format.captures(value)?;
    let integer = |index| {
        parts
            .get(index)
            .map_or(Some(0_i64), |v| v.as_str().parse::<i64>().ok())
    };
    let year = integer(1)?;
    let month = integer(2)? - 1;
    let normalized_year = year.checked_add(month.div_euclid(12))?;
    let normalized_month = month.rem_euclid(12) + 1;
    let day = NaiveDate::from_ymd_opt(
        i32::try_from(normalized_year).ok()?,
        normalized_month as u32,
        1,
    )?;
    let mut minutes = integer(5)?;
    if parts.get(9).is_some() {
        let sign = if parts.get(9)?.as_str() == "-" { -1 } else { 1 };
        minutes -= sign * (60 * integer(10)? + integer(11)?);
    }
    let fraction = parts
        .get(7)
        .map(|v| {
            v.as_str()
                .bytes()
                .take(6)
                .fold((0_i64, 0), |(n, len), digit| {
                    (n * 10 + i64::from(digit - b'0'), len + 1)
                })
        })
        .unwrap_or((0, 6));
    let micros = fraction.0 * 10_i64.pow(6 - fraction.1);
    let seconds = (integer(3)? - 1)
        .checked_mul(86400)?
        .checked_add(integer(4)?.checked_mul(3600)?)?
        .checked_add(minutes.checked_mul(60)?)?
        .checked_add(integer(6)?)?;
    let naive = day
        .and_hms_opt(0, 0, 0)?
        .checked_add_signed(Duration::seconds(seconds))?
        .checked_add_signed(Duration::microseconds(micros))?;
    let utc = parts.get(8).is_some();
    let instant = if utc {
        naive.and_utc()
    } else {
        Local
            .from_local_datetime(&naive)
            .earliest()?
            .with_timezone(&Utc)
    };
    Some(Parsed {
        instant,
        local: if utc { None } else { Some(naive) },
    })
}

pub(crate) fn iso_utc(value: &DateTime<Utc>) -> String {
    value.to_rfc3339_opts(
        if value.timestamp_subsec_nanos().is_multiple_of(1_000_000) {
            SecondsFormat::Millis
        } else {
            SecondsFormat::Micros
        },
        true,
    )
}

pub(crate) fn iso(value: &Parsed) -> String {
    match value.local {
        None => iso_utc(&value.instant),
        Some(date) => date
            .format(
                if date
                    .and_utc()
                    .timestamp_subsec_nanos()
                    .is_multiple_of(1_000_000)
                {
                    "%Y-%m-%dT%H:%M:%S%.3f"
                } else {
                    "%Y-%m-%dT%H:%M:%S%.6f"
                },
            )
            .to_string(),
    }
}
