use chrono::{Datelike, NaiveDate, NaiveDateTime, Timelike};
use regex::Regex;
use std::sync::LazyLock;

static YEAR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[0-9]{4}").unwrap());
static SIMPLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([0-9]{4})(?:([-/.])([0-9]{2})(?:([-/.])([0-9]{2}))?)?$").unwrap()
});
static RFC3339: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:[.,]([0-9]+))?(Z|([-+])([0-9]{2}):([0-9]{2}))$").unwrap()
});

struct Date {
    value: NaiveDateTime,
    offset: i32,
    zone: String,
}

pub(super) fn format(
    raw: &str,
    pattern: &str,
    limit: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    let Some(date) = parse(raw) else {
        return Ok(String::new());
    };
    let mut layout = String::new();
    let mut chars = pattern.chars();
    let mut next_check = 0;
    while let Some(character) = chars.next() {
        if layout.len() >= next_check {
            check()?;
            next_check = layout.len().saturating_add(1024);
        }
        if layout.len() > limit {
            return Err("filename result exceeds output limit".into());
        }
        if character != '%' {
            layout.push(character);
            continue;
        }
        match chars.next() {
            Some('Y') => layout.push_str("2006"),
            Some('y') => layout.push_str("06"),
            Some('m') => layout.push_str("01"),
            Some('d') => layout.push_str("02"),
            Some('b') => layout.push_str("Jan"),
            Some('B') => layout.push_str("January"),
            Some('%') => layout.push('%'),
            Some(other) => {
                layout.push('%');
                layout.push(other);
            }
            None => layout.push('%'),
        }
    }
    render(&date, &layout, limit, check)
}

fn parse(raw: &str) -> Option<Date> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if let Some(value) = rfc3339(raw) {
        return Some(value);
    }
    if let Some(value) = simple(raw) {
        return Some(value);
    }
    if let Some(prefix) = raw.get(..10)
        && prefix.as_bytes().get(4) == Some(&b'-')
        && let Some(value) = simple(prefix)
    {
        return Some(value);
    }
    let year = YEAR.find(raw)?.as_str().parse::<i32>().ok()?;
    if year <= 0 {
        return None;
    }
    utc(year, 1, 1)
}

fn rfc3339(raw: &str) -> Option<Date> {
    let captures = RFC3339.captures(raw)?;
    let number = |index| captures.get(index)?.as_str().parse::<u32>().ok();
    let fraction = captures.get(7).map_or("", |value| value.as_str());
    let mut nanos = 0;
    for index in 0..9 {
        nanos = nanos * 10
            + fraction
                .as_bytes()
                .get(index)
                .map_or(0, |byte| u32::from(*byte - b'0'));
    }
    let value = NaiveDate::from_ymd_opt(number(1)? as i32, number(2)?, number(3)?)?
        .and_hms_nano_opt(number(4)?, number(5)?, number(6)?, nanos)?;
    if &captures[8] == "Z" {
        return Some(Date {
            value,
            offset: 0,
            zone: "UTC".into(),
        });
    }
    let (hours, minutes) = (number(10)?, number(11)?);
    // Go's non-strict RFC3339 path accepts inclusive 24-hour/60-minute offsets.
    if hours > 24 || minutes > 60 {
        return None;
    }
    let offset = (hours * 3600 + minutes * 60) as i32 * if &captures[9] == "-" { -1 } else { 1 };
    let (local_offset, name, _) =
        crate::clock::zone_at(value.and_utc().timestamp() - i64::from(offset));
    Some(Date {
        value,
        offset,
        zone: if offset == local_offset {
            name
        } else {
            String::new()
        },
    })
}

fn simple(raw: &str) -> Option<Date> {
    let captures = SIMPLE.captures(raw)?;
    if captures.get(4).is_some() && captures.get(2)?.as_str() != captures.get(4)?.as_str() {
        return None;
    }
    utc(
        captures[1].parse().ok()?,
        captures
            .get(3)
            .map_or(Some(1), |value| value.as_str().parse().ok())?,
        captures
            .get(5)
            .map_or(Some(1), |value| value.as_str().parse().ok())?,
    )
}

fn utc(year: i32, month: u32, day: u32) -> Option<Date> {
    Some(Date {
        value: NaiveDate::from_ymd_opt(year, month, day)?.and_hms_opt(0, 0, 0)?,
        offset: 0,
        zone: "UTC".into(),
    })
}

fn render(
    date: &Date,
    mut layout: &str,
    limit: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    let value = date.value;
    let mut output = String::new();
    while !layout.is_empty() {
        check()?;
        if output.len() > limit {
            return Err("filename result exceeds output limit".into());
        }
        let token = token(layout);
        let Some(token) = token else {
            let character = layout.chars().next().unwrap();
            output.push(character);
            layout = &layout[character.len_utf8()..];
            continue;
        };
        let text = match token {
            "January" => MONTHS[value.month0() as usize].into(),
            "Jan" => MONTHS[value.month0() as usize][..3].into(),
            "Monday" => DAYS[value.weekday().num_days_from_sunday() as usize].into(),
            "Mon" => DAYS[value.weekday().num_days_from_sunday() as usize][..3].into(),
            "2006" => format!("{:04}", value.year()),
            "06" => format!("{:02}", value.year().abs() % 100),
            "1" => value.month().to_string(),
            "01" => format!("{:02}", value.month()),
            "2" => value.day().to_string(),
            "02" => format!("{:02}", value.day()),
            "_2" => format!("{:2}", value.day()),
            "002" => format!("{:03}", value.ordinal()),
            "__2" => format!("{:3}", value.ordinal()),
            "15" => format!("{:02}", value.hour()),
            "3" => value.hour12().1.to_string(),
            "03" => format!("{:02}", value.hour12().1),
            "4" => value.minute().to_string(),
            "04" => format!("{:02}", value.minute()),
            "5" => value.second().to_string(),
            "05" => format!("{:02}", value.second()),
            "PM" => if value.hour() >= 12 { "PM" } else { "AM" }.into(),
            "pm" => if value.hour() >= 12 { "pm" } else { "am" }.into(),
            "MST" => {
                if date.zone.is_empty() {
                    timezone(date.offset, "-0700")
                } else {
                    date.zone.clone()
                }
            }
            other if other.starts_with(['.', ',']) => {
                let length = (other.len() - 1).min(9);
                let digits = format!("{:09}", value.nanosecond());
                let digits = &digits[..length];
                let digits = if other.as_bytes()[1] == b'9' {
                    digits.trim_end_matches('0')
                } else {
                    digits
                };
                if digits.is_empty() {
                    String::new()
                } else {
                    format!("{}{digits}", &other[..1])
                }
            }
            other => timezone(date.offset, other),
        };
        output.push_str(&text);
        layout = &layout[token.len()..];
    }
    if output.len() > limit {
        return Err("filename result exceeds output limit".into());
    }
    Ok(output)
}

fn token(layout: &str) -> Option<&str> {
    if layout.starts_with("_2006") {
        return None;
    }
    for token in [
        "January",
        "Monday",
        "Jan",
        "Mon",
        "MST",
        "002",
        "01",
        "02",
        "03",
        "04",
        "05",
        "06",
        "15",
        "1",
        "2006",
        "2",
        "_2",
        "__2",
        "3",
        "4",
        "5",
        "PM",
        "pm",
        "-070000",
        "-07:00:00",
        "-0700",
        "-07:00",
        "-07",
        "Z070000",
        "Z07:00:00",
        "Z0700",
        "Z07:00",
        "Z07",
    ] {
        if layout.starts_with(token)
            && !(matches!(token, "Jan" | "Mon")
                && layout
                    .as_bytes()
                    .get(token.len())
                    .is_some_and(u8::is_ascii_lowercase))
        {
            return Some(&layout[..token.len()]);
        }
    }
    let bytes = layout.as_bytes();
    if matches!(bytes[0], b'.' | b',')
        && bytes
            .get(1)
            .is_some_and(|value| matches!(value, b'0' | b'9'))
    {
        let length = 1 + bytes[1..]
            .iter()
            .take_while(|value| **value == bytes[1])
            .count();
        if !bytes.get(length).is_some_and(u8::is_ascii_digit) {
            return Some(&layout[..length]);
        }
    }
    None
}

fn timezone(offset: i32, token: &str) -> String {
    if offset == 0 && token.starts_with('Z') {
        return "Z".into();
    }
    let minutes = offset.abs() / 60;
    let mut result = format!("{}{:02}", if offset < 0 { '-' } else { '+' }, minutes / 60);
    if token.len() > 3 {
        if token.contains(':') {
            result.push(':');
        }
        result.push_str(&format!("{:02}", minutes % 60));
    }
    if token.len() >= 7 {
        if token.contains(':') {
            result.push(':');
        }
        result.push_str(&format!("{:02}", offset.abs() % 60));
    }
    result
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];
const DAYS: [&str; 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
];
