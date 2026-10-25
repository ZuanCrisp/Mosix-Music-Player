//! Windows local time zone. Like Go's `initLocalFromTZI`, the current
//! `GetDynamicTimeZoneInformation` rules become one recurring standard and
//! daylight rule, and the location is named `Local`.

/// A `SYSTEMTIME` in the Windows "day in month" rule form: `day` is the week
/// of the month (1 to 5, where 5 is the last), `day_of_week` counts from
/// Sunday, and the time is the local wall clock before the transition.
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct RuleDate {
    pub month: u16,
    pub day_of_week: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
    pub second: u16,
}

/// The fields of `DYNAMIC_TIME_ZONE_INFORMATION` that select local time.
/// Biases are minutes, with UTC = local time + bias.
#[derive(Clone, Debug, Default)]
pub(super) struct ZoneInformation {
    pub bias: i32,
    pub standard_name: String,
    pub standard_date: RuleDate,
    pub standard_bias: i32,
    pub daylight_name: String,
    pub daylight_date: RuleDate,
    pub daylight_bias: i32,
    pub key_name: String,
    pub dynamic_daylight_disabled: bool,
}

#[cfg(windows)]
pub(super) fn load() -> (tz::TimeZone, String) {
    // Go names the zone "UTC" when Windows cannot report one.
    match query().as_ref().and_then(zone) {
        Some(zone) => (zone, "Local".into()),
        None => (tz::TimeZone::utc(), "UTC".into()),
    }
}

#[cfg(windows)]
#[allow(unsafe_code)] // One FFI call that fills a caller-owned struct.
fn query() -> Option<ZoneInformation> {
    use windows_sys::Win32::Foundation::SYSTEMTIME;
    use windows_sys::Win32::System::Time::{
        DYNAMIC_TIME_ZONE_INFORMATION, GetDynamicTimeZoneInformation, TIME_ZONE_ID_INVALID,
    };

    fn text(wide: &[u16]) -> String {
        let end = wide
            .iter()
            .position(|unit| *unit == 0)
            .unwrap_or(wide.len());
        String::from_utf16_lossy(&wide[..end])
    }
    fn date(time: SYSTEMTIME) -> RuleDate {
        RuleDate {
            month: time.wMonth,
            day_of_week: time.wDayOfWeek,
            day: time.wDay,
            hour: time.wHour,
            minute: time.wMinute,
            second: time.wSecond,
        }
    }

    let mut raw = DYNAMIC_TIME_ZONE_INFORMATION::default();
    // SAFETY: `raw` is a valid, writable DYNAMIC_TIME_ZONE_INFORMATION that
    // lives for the whole call, and the function only writes into it.
    if unsafe { GetDynamicTimeZoneInformation(&mut raw) } == TIME_ZONE_ID_INVALID {
        return None;
    }
    Some(ZoneInformation {
        bias: raw.Bias,
        standard_name: text(&raw.StandardName),
        standard_date: date(raw.StandardDate),
        standard_bias: raw.StandardBias,
        daylight_name: text(&raw.DaylightName),
        daylight_date: date(raw.DaylightDate),
        daylight_bias: raw.DaylightBias,
        key_name: text(&raw.TimeZoneKeyName),
        dynamic_daylight_disabled: raw.DynamicDaylightTimeDisabled,
    })
}

/// Build the zone Windows uses for local time this year. Returns `None` only
/// when even the standard offset is unusable.
pub(super) fn zone(info: &ZoneInformation) -> Option<tz::TimeZone> {
    let (standard_label, daylight_label) = labels(info);
    if info.standard_date.month == 0 {
        // Go ignores StandardBias when no transition date is set.
        return fixed(info.bias.checked_mul(-60)?, &standard_label);
    }
    let standard_offset = info
        .bias
        .checked_add(info.standard_bias)?
        .checked_mul(-60)?;
    if info.dynamic_daylight_disabled {
        // "Adjust for daylight saving time automatically" is off.
        return fixed(standard_offset, &standard_label);
    }
    let daylight = || {
        let daylight_offset = info
            .bias
            .checked_add(info.daylight_bias)?
            .checked_mul(-60)?;
        let rule = tz::timezone::AlternateTime::new(
            local_type(standard_offset, false, &standard_label)?,
            local_type(daylight_offset, true, &daylight_label)?,
            rule_day(info.daylight_date)?,
            seconds(info.daylight_date),
            rule_day(info.standard_date)?,
            seconds(info.standard_date),
        )
        .ok()?;
        tz::TimeZone::new(
            Vec::new(),
            vec![local_type(standard_offset, false, &standard_label)?],
            Vec::new(),
            Some(tz::timezone::TransitionRule::Alternate(rule)),
        )
        .ok()
    };
    // A malformed daylight rule keeps standard time rather than UTC.
    daylight().or_else(|| fixed(standard_offset, &standard_label))
}

fn fixed(offset: i32, label: &str) -> Option<tz::TimeZone> {
    tz::TimeZone::new(
        Vec::new(),
        vec![local_type(offset, false, label)?],
        Vec::new(),
        None,
    )
    .ok()
}

fn local_type(offset: i32, is_dst: bool, label: &str) -> Option<tz::LocalTimeType> {
    // POSIX abbreviations have at least three characters; tz-rs allows seven.
    if (3..=7).contains(&label.len())
        && let Ok(kind) = tz::LocalTimeType::new(offset, is_dst, Some(label.as_bytes()))
    {
        return Some(kind);
    }
    tz::LocalTimeType::new(offset, is_dst, Some(numeric_label(offset).as_bytes())).ok()
}

/// Go maps zone names through its CLDR table, then falls back to the capital
/// letters of the localized names. The registry key name is always English,
/// so its capitals stay stable across display languages ("Pacific Standard
/// Time" gives PST and PDT).
fn labels(info: &ZoneInformation) -> (String, String) {
    if info.key_name.is_empty() {
        return (capitals(&info.standard_name), capitals(&info.daylight_name));
    }
    (
        capitals(&info.key_name),
        capitals(&info.key_name.replace("Standard Time", "Daylight Time")),
    )
}

fn capitals(name: &str) -> String {
    name.chars().filter(char::is_ascii_uppercase).collect()
}

/// The numeric form tzdata uses for zones without an abbreviation.
fn numeric_label(offset: i32) -> String {
    let sign = if offset < 0 { '-' } else { '+' };
    let minutes = offset.unsigned_abs() / 60;
    let (hours, minutes) = (minutes / 60, minutes % 60);
    if minutes == 0 {
        format!("{sign}{hours:02}")
    } else {
        format!("{sign}{hours:02}{minutes:02}")
    }
}

fn rule_day(date: RuleDate) -> Option<tz::timezone::RuleDay> {
    tz::timezone::MonthWeekDay::new(
        u8::try_from(date.month).ok()?,
        u8::try_from(date.day).ok()?,
        u8::try_from(date.day_of_week).ok()?,
    )
    .ok()
    .map(tz::timezone::RuleDay::MonthWeekDay)
}

fn seconds(date: RuleDate) -> i32 {
    i32::from(date.hour) * 3600 + i32::from(date.minute) * 60 + i32::from(date.second)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> i64 {
        chrono::NaiveDate::from_ymd_opt(year, month, day)
            .unwrap()
            .and_hms_opt(hour, minute, 0)
            .unwrap()
            .and_utc()
            .timestamp()
    }

    fn local(zone: &tz::TimeZone, timestamp: i64) -> (i32, bool, String) {
        let kind = zone.find_local_time_type(timestamp).unwrap();
        (
            kind.ut_offset(),
            kind.is_dst(),
            kind.time_zone_designation().into(),
        )
    }

    fn rule(month: u16, day: u16, hour: u16) -> RuleDate {
        RuleDate {
            month,
            day,
            hour,
            ..RuleDate::default()
        }
    }

    fn pacific() -> ZoneInformation {
        ZoneInformation {
            bias: 480,
            standard_name: "Pacific Standard Time".into(),
            standard_date: rule(11, 1, 2),
            daylight_name: "Pacific Daylight Time".into(),
            daylight_date: rule(3, 2, 2),
            daylight_bias: -60,
            key_name: "Pacific Standard Time".into(),
            ..ZoneInformation::default()
        }
    }

    #[test]
    fn northern_rules_switch_at_local_wall_clock_times() {
        let zone = zone(&pacific()).unwrap();
        assert_eq!(
            local(&zone, at(2026, 1, 15, 12, 0)),
            (-8 * 3600, false, "PST".into())
        );
        assert_eq!(
            local(&zone, at(2026, 7, 1, 12, 0)),
            (-7 * 3600, true, "PDT".into())
        );
        // Second Sunday of March at 02:00 PST, first Sunday of November at
        // 02:00 PDT.
        let start = at(2026, 3, 8, 10, 0);
        assert!(!local(&zone, start - 1).1);
        assert!(local(&zone, start).1);
        let end = at(2026, 11, 1, 9, 0);
        assert!(local(&zone, end - 1).1);
        assert!(!local(&zone, end).1);
    }

    #[test]
    fn last_week_rules_and_southern_hemisphere_zones() {
        let europe = zone(&ZoneInformation {
            bias: -60,
            standard_date: rule(10, 5, 3),
            daylight_date: rule(3, 5, 2),
            daylight_bias: -60,
            key_name: "W. Europe Standard Time".into(),
            ..ZoneInformation::default()
        })
        .unwrap();
        // Last Sundays: March 29 and October 25, 2026, both at 01:00 UTC.
        assert_eq!(
            local(&europe, at(2026, 3, 29, 0, 59)),
            (3600, false, "WEST".into())
        );
        assert_eq!(
            local(&europe, at(2026, 3, 29, 1, 0)),
            (7200, true, "WEDT".into())
        );
        assert!(local(&europe, at(2026, 10, 25, 0, 59)).1);
        assert!(!local(&europe, at(2026, 10, 25, 1, 0)).1);

        let sydney = zone(&ZoneInformation {
            bias: -600,
            standard_date: rule(4, 1, 3),
            daylight_date: rule(10, 1, 2),
            daylight_bias: -60,
            key_name: "AUS Eastern Standard Time".into(),
            ..ZoneInformation::default()
        })
        .unwrap();
        assert_eq!(local(&sydney, at(2026, 1, 15, 0, 0)).0, 11 * 3600);
        assert_eq!(local(&sydney, at(2026, 7, 15, 0, 0)).0, 10 * 3600);
        // First Sunday of October (October 4) at 02:00 AEST = 16:00 UTC.
        assert!(!local(&sydney, at(2026, 10, 3, 15, 59)).1);
        assert!(local(&sydney, at(2026, 10, 3, 16, 0)).1);
    }

    #[test]
    fn zones_without_daylight_rules_use_the_bias_alone() {
        let india = zone(&ZoneInformation {
            bias: -330,
            // Go ignores StandardBias without a StandardDate.
            standard_bias: 15,
            key_name: "India Standard Time".into(),
            ..ZoneInformation::default()
        })
        .unwrap();
        assert_eq!(
            local(&india, at(2026, 7, 1, 0, 0)),
            (19800, false, "IST".into())
        );
    }

    #[test]
    fn disabled_or_malformed_daylight_rules_keep_standard_time() {
        let disabled = zone(&ZoneInformation {
            dynamic_daylight_disabled: true,
            ..pacific()
        })
        .unwrap();
        assert_eq!(
            local(&disabled, at(2026, 7, 1, 12, 0)),
            (-8 * 3600, false, "PST".into())
        );
        let malformed = zone(&ZoneInformation {
            daylight_date: rule(13, 2, 2),
            ..pacific()
        })
        .unwrap();
        assert_eq!(local(&malformed, at(2026, 7, 1, 12, 0)).0, -8 * 3600);
    }

    #[test]
    fn labels_fall_back_to_localized_capitals_then_numeric_offsets() {
        let localized = zone(&ZoneInformation {
            key_name: String::new(),
            ..pacific()
        })
        .unwrap();
        assert_eq!(local(&localized, at(2026, 7, 1, 12, 0)).2, "PDT");
        let unnamed = zone(&ZoneInformation {
            bias: -330,
            standard_name: "Mitteleurop\u{e4}ische Zeit".into(),
            ..ZoneInformation::default()
        })
        .unwrap();
        assert_eq!(local(&unnamed, 0).2, "+0530");
        assert_eq!(numeric_label(-3 * 3600), "-03");
        assert_eq!(numeric_label(0), "+00");
    }
}
