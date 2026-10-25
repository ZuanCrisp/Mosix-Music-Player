use serde::Serialize;
use std::io::Read;

const MAX_SCANNER_BUFFER: usize = 64 * 1024;
const READ_BUFFER_SIZE: usize = 8 * 1024;

#[derive(Clone, Debug, Serialize)]
pub struct CueSheet {
    pub performer: String,
    pub title: String,
    pub file_name: String,
    pub file_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub genre: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub date: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub comment: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub composer: String,
    pub tracks: Vec<CueTrack>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CueTrack {
    pub number: i64,
    pub title: String,
    pub performer: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub isrc: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub composer: String,
    pub start_time: f64,
    pub pre_gap: f64,
}

/// Parse a CUE sheet from a bounded stream.
pub fn parse(
    reader: &mut impl Read,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<CueSheet, String> {
    check()?;
    let mut lines = Lines {
        reader,
        check,
        buffer: [0; READ_BUFFER_SIZE],
        start: 0,
        end: 0,
        eof: false,
    };
    let mut raw_line = Vec::new();
    let mut sheet = CueSheet {
        performer: String::new(),
        title: String::new(),
        file_name: String::new(),
        file_type: String::new(),
        genre: String::new(),
        date: String::new(),
        comment: String::new(),
        composer: String::new(),
        tracks: Vec::new(),
    };
    let mut current_track: Option<CueTrack> = None;

    while lines.next(&mut raw_line)? {
        let mut line = crate::text::utf8(&raw_line);
        line = line.trim().to_owned();
        if line.is_empty() {
            continue;
        }

        if let Some(without_bom) = line.strip_prefix('\u{feff}') {
            line = without_bom.trim().to_owned();
            if line.is_empty() {
                continue;
            }
        }

        if let Some((key, value)) = parse_rem(&line) {
            let value = unquote(value);
            match key.to_uppercase().as_str() {
                "GENRE" => sheet.genre = value,
                "DATE" => sheet.date = value,
                "COMMENT" => sheet.comment = value,
                "COMPOSER" => {
                    if let Some(track) = current_track.as_mut() {
                        track.composer = value;
                    } else {
                        sheet.composer = value;
                    }
                }
                _ => {}
            }
            continue;
        }

        if let Some(rest) = command_rest(&line, "PERFORMER ") {
            let value = unquote(rest);
            if let Some(track) = current_track.as_mut() {
                track.performer = value;
            } else {
                sheet.performer = value;
            }
            continue;
        }

        if let Some(rest) = command_rest(&line, "TITLE ") {
            let value = unquote(rest);
            if let Some(track) = current_track.as_mut() {
                track.title = value;
            } else {
                sheet.title = value;
            }
            continue;
        }

        if let Some(rest) = command_rest(&line, "FILE ") {
            let (file_name, file_type) = parse_file_line(rest);
            sheet.file_name = file_name;
            sheet.file_type = file_type;
            continue;
        }

        if command_rest(&line, "TRACK ").is_some() {
            if let Some(track) = current_track.take() {
                sheet.tracks.push(track);
            }
            let number = line
                .split_whitespace()
                .nth(1)
                .and_then(|value| value.parse::<i64>().ok())
                .unwrap_or(0);
            current_track = Some(CueTrack {
                number,
                title: String::new(),
                performer: String::new(),
                isrc: String::new(),
                composer: String::new(),
                start_time: 0.0,
                pre_gap: -1.0,
            });
            continue;
        }

        if command_rest(&line, "INDEX ").is_some() && current_track.is_some() {
            let parts: Vec<_> = line.split_whitespace().collect();
            if parts.len() >= 3 {
                let index = parts[1].parse::<i64>().unwrap_or(0);
                let seconds = timestamp(parts[2]);
                if let Some(track) = current_track.as_mut() {
                    match index {
                        0 => track.pre_gap = seconds,
                        1 => track.start_time = seconds,
                        _ => {}
                    }
                }
            }
            continue;
        }

        if let Some(rest) = command_rest(&line, "ISRC ") {
            if let Some(track) = current_track.as_mut() {
                track.isrc = rest.trim().to_owned();
            }
            continue;
        }

        if let Some(rest) = command_rest(&line, "SONGWRITER ") {
            let value = unquote(rest);
            if let Some(track) = current_track.as_mut() {
                track.composer = value;
            } else {
                sheet.composer = value;
            }
        }
    }

    if let Some(track) = current_track {
        sheet.tracks.push(track);
    }
    if sheet.tracks.is_empty() {
        return Err("no tracks found in cue file".into());
    }
    Ok(sheet)
}

struct Lines<'a, R> {
    reader: &'a mut R,
    check: &'a dyn Fn() -> Result<(), String>,
    buffer: [u8; READ_BUFFER_SIZE],
    start: usize,
    end: usize,
    eof: bool,
}

impl<R: Read> Lines<'_, R> {
    fn next(&mut self, line: &mut Vec<u8>) -> Result<bool, String> {
        line.clear();
        let mut raw_length = 0;
        loop {
            (self.check)()?;
            if self.start == self.end {
                if self.eof {
                    if line.is_empty() {
                        return Ok(false);
                    }
                    strip_carriage_return(line);
                    return Ok(true);
                }
                let count = self
                    .reader
                    .read(&mut self.buffer)
                    .map_err(|error| format!("error reading cue file: {error}"))?;
                if count == 0 {
                    self.eof = true;
                    continue;
                }
                self.start = 0;
                self.end = count;
            }

            let remaining = &self.buffer[self.start..self.end];
            if let Some(offset) = remaining.iter().position(|byte| *byte == b'\n') {
                if raw_length + offset + 1 > MAX_SCANNER_BUFFER {
                    return Err("error reading cue file: bufio.Scanner: token too long".into());
                }
                line.extend_from_slice(&remaining[..offset]);
                self.start += offset + 1;
                strip_carriage_return(line);
                return Ok(true);
            }

            raw_length += remaining.len();
            if raw_length >= MAX_SCANNER_BUFFER {
                return Err("error reading cue file: bufio.Scanner: token too long".into());
            }
            line.extend_from_slice(remaining);
            self.start = self.end;
        }
    }
}

fn strip_carriage_return(line: &mut Vec<u8>) {
    if line.last() == Some(&b'\r') {
        line.pop();
    }
}

fn command_rest<'a>(line: &'a str, command: &str) -> Option<&'a str> {
    let prefix = line.get(..command.len())?;
    if prefix.eq_ignore_ascii_case(command) {
        line.get(command.len()..)
    } else {
        None
    }
}

fn parse_rem(line: &str) -> Option<(&str, &str)> {
    if !line.starts_with("REM ") {
        return None;
    }
    let bytes = line.as_bytes();
    let mut key_start = 3;
    while key_start < bytes.len() && rem_space(bytes[key_start]) {
        key_start += 1;
    }
    if key_start == bytes.len() {
        return None;
    }
    let mut key_end = key_start;
    while key_end < bytes.len() && !rem_space(bytes[key_end]) {
        key_end += 1;
    }
    if key_end == bytes.len() {
        return None;
    }
    let mut value_start = key_end;
    while value_start < bytes.len() && rem_space(bytes[value_start]) {
        value_start += 1;
    }
    if value_start == bytes.len() {
        return None;
    }
    Some((&line[key_start..key_end], &line[value_start..]))
}

fn rem_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n' | b'\x0c')
}

fn timestamp(value: &str) -> f64 {
    let parts: Vec<_> = value.split(':').collect();
    if parts.len() != 3 {
        return 0.0;
    }
    let minutes = parts[0].parse::<i64>().unwrap_or(0);
    let seconds = parts[1].parse::<i64>().unwrap_or(0);
    let frames = parts[2].parse::<i64>().unwrap_or(0);
    minutes as f64 * 60.0 + seconds as f64 + frames as f64 / 75.0
}

fn unquote(value: &str) -> String {
    let value = value.trim();
    let Some(start) = value.find('"') else {
        return value.to_owned();
    };
    let Some(end) = value[start + 1..].find('"') else {
        return value.to_owned();
    };
    value[start + 1..start + 1 + end].to_owned()
}

fn parse_file_line(rest: &str) -> (String, String) {
    let rest = rest.trim();
    if let Some(end) = rest.strip_prefix('"').and_then(|value| value.find('"')) {
        let file_name = rest[1..end + 1].to_owned();
        let file_type = rest[end + 2..].trim().to_owned();
        return (file_name, file_type);
    }
    if rest.starts_with('"') {
        return (rest.to_owned(), String::new());
    }

    let parts: Vec<_> = rest.split_whitespace().collect();
    match parts.len() {
        0 => (String::new(), String::new()),
        1 => (parts[0].to_owned(), String::new()),
        _ => (
            parts[..parts.len() - 1].join(" "),
            parts[parts.len() - 1].to_owned(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::io::Cursor;

    #[test]
    fn parse_cue_semantics_and_bounds() {
        let input = "\u{feff}PERFORMER \"Album Artist\"\nREM COMPOSER \"Album Writer\"\nTITLE \"Album\"\nFILE \"album.flac\" FLAC\nTRACK 01 AUDIO\nTITLE \"Song\"\nPERFORMER \"Track Artist\"\nREM COMPOSER \"Track Writer\"\nINDEX 01 01:02:37\nTRACK 02 AUDIO\nTITLE \"Second\"\nINDEX 00 03:00:00\n";
        let sheet = parse(&mut Cursor::new(input.as_bytes()), &|| Ok(())).unwrap();
        assert_eq!(sheet.performer, "Album Artist");
        assert_eq!(sheet.composer, "Album Writer");
        assert_eq!(sheet.file_name, "album.flac");
        assert_eq!(sheet.tracks.len(), 2);
        assert_eq!(sheet.tracks[0].composer, "Track Writer");
        assert!((sheet.tracks[0].start_time - (62.0 + 37.0 / 75.0)).abs() < f64::EPSILON);
        assert_eq!(sheet.tracks[0].pre_gap, -1.0);
        assert_eq!(sheet.tracks[1].pre_gap, 180.0);

        let mut malformed = Cursor::new(b"TITLE \"no tracks\"\n".to_vec());
        assert_eq!(
            parse(&mut malformed, &|| Ok(())).unwrap_err(),
            "no tracks found in cue file"
        );

        let mut oversized = Cursor::new(vec![b'x'; MAX_SCANNER_BUFFER]);
        assert!(
            parse(&mut oversized, &|| Ok(()))
                .unwrap_err()
                .contains("token too long")
        );

        let checks = Cell::new(0);
        let mut cancelled = Cursor::new(b"TRACK 01 AUDIO\n".to_vec());
        let error = parse(&mut cancelled, &|| {
            checks.set(checks.get() + 1);
            if checks.get() > 1 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        })
        .unwrap_err();
        assert_eq!(error, "cancelled");
    }
}
