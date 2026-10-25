//! USB Audio Feature Unit volume. Values are signed 1/256 dB, not PCM gain.
use super::UsbHardwareVolume;
use std::collections::HashMap;

pub trait Control {
    fn transfer(
        &self,
        input: bool,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
    ) -> Result<(), String>;
}

#[derive(Clone, Debug, PartialEq)]
pub struct Feature {
    pub unit: u8,
    pub interface: u8,
    pub uac2: bool,
    pub channels: Vec<u8>,
}

/// Follow only an unambiguous playback terminal chain. Never change a capture
/// Feature Unit or guess which input of a mixer/selector is currently routed.
pub fn feature(raw: &[u8], interface: u8, terminal: u8, channels: u8) -> Option<Feature> {
    let mut active = false;
    let mut uac2 = false;
    let mut sources = HashMap::new();
    let mut features = HashMap::new();
    let mut outputs = Vec::new();
    let mut offset = 0;
    while offset + 2 <= raw.len() {
        let len = raw[offset] as usize;
        if len < 2 || len > raw.len() - offset {
            return None;
        }
        let d = &raw[offset..offset + len];
        offset += len;
        if d[1] == 4 && len >= 9 {
            active = d[2] == interface && d[5] == 1 && d[6] == 1;
            uac2 = d[7] == 0x20;
        } else if active && d[1] == 0x24 && len >= 4 {
            match d[2] {
                3 if len >= 9 => {
                    sources.insert(d[3], d[7]);
                    outputs.push(d[3]);
                }
                6 if len >= 7 => {
                    sources.insert(d[3], d[4]);
                    let size = if uac2 { 4 } else { d[5] as usize };
                    let start = if uac2 { 5 } else { 6 };
                    if size == 0 || size > 4 || len < start + size + 1 {
                        continue;
                    }
                    let writable = |channel: usize| {
                        let pos = start + channel * size;
                        if pos + size >= len {
                            return false;
                        }
                        if uac2 {
                            (d[pos] >> 2) & 3 == 3
                        } else {
                            d[pos] & 2 != 0
                        }
                    };
                    let controlled = if writable(0) {
                        vec![0]
                    } else if (1..=channels as usize).all(writable) {
                        (1..=channels).collect()
                    } else {
                        continue;
                    };
                    features.insert(
                        d[3],
                        Feature {
                            unit: d[3],
                            interface,
                            uac2,
                            channels: controlled,
                        },
                    );
                }
                _ => {}
            }
        }
    }
    let mut matches = Vec::new();
    for mut id in outputs {
        let mut seen = Vec::new();
        let mut candidate = None;
        while id != terminal && !seen.contains(&id) {
            seen.push(id);
            if candidate.is_none() {
                candidate = features.get(&id).cloned();
            }
            id = match sources.get(&id) {
                Some(source) => *source,
                None => break,
            };
        }
        if id == terminal
            && let Some(f) = candidate
        {
            matches.push(f);
        }
    }
    matches.dedup();
    if matches.len() == 1 {
        matches.pop()
    } else {
        None
    }
}

#[derive(Clone, Copy, Debug)]
struct Range {
    min: i16,
    max: i16,
    step: i16,
}

impl Range {
    fn parse(bytes: &[u8]) -> Result<Self, String> {
        let r = Self {
            min: i16::from_le_bytes([bytes[0], bytes[1]]),
            max: i16::from_le_bytes([bytes[2], bytes[3]]),
            step: i16::from_le_bytes([bytes[4], bytes[5]]),
        };
        if r.min == i16::MIN || r.min > r.max || r.step < 0 {
            return Err("Invalid USB volume range".into());
        }
        Ok(r)
    }
    fn floor(self, value: i32) -> i16 {
        let value = value.clamp(self.min as i32, self.max as i32);
        let step = i32::from(self.step).max(1);
        (self.min as i32 + (value - self.min as i32) / step * step) as i16
    }
}

pub struct Volume {
    feature: Feature,
    ranges: Vec<Vec<Range>>,
    snapshot: UsbHardwareVolume,
}

impl Volume {
    pub fn open(control: &impl Control, feature: Feature) -> Result<Self, String> {
        let index = (feature.unit as u16) << 8 | feature.interface as u16;
        let mut ranges = Vec::new();
        let mut current = i16::MIN;
        let mut startup = Vec::new();
        let mut restore_limit = i16::MAX;
        for channel in &feature.channels {
            let selector = 0x200 | *channel as u16;
            let mut data = [0; 2];
            control.transfer(
                true,
                if feature.uac2 { 1 } else { 0x81 },
                selector,
                index,
                &mut data,
            )?;
            current = current.max(i16::from_le_bytes(data));
            restore_limit = restore_limit.min(i16::from_le_bytes(data));
            startup.push(i32::from(i16::from_le_bytes(data).min(-40 * 256)));
            let r = if feature.uac2 {
                control.transfer(true, 2, selector, index, &mut data)?;
                let count = u16::from_le_bytes(data) as usize;
                if !(1..=16).contains(&count) {
                    return Err("Unsupported USB volume ranges".into());
                }
                let mut data = vec![0; 2 + 6 * count];
                control.transfer(true, 2, selector, index, &mut data)?;
                if u16::from_le_bytes([data[0], data[1]]) as usize != count {
                    return Err("USB volume range changed".into());
                }
                data[2..]
                    .as_chunks::<6>()
                    .0
                    .iter()
                    .map(|bytes| Range::parse(bytes))
                    .collect::<Result<Vec<_>, _>>()?
            } else {
                let mut data = [0; 6];
                for (request, bytes) in (0x82..=0x84).zip(data.as_chunks_mut::<2>().0) {
                    control.transfer(true, request, selector, index, bytes)?;
                }
                vec![Range::parse(&data)?]
            };
            ranges.push(r);
        }
        let min = ranges
            .iter()
            .map(|r| r.iter().map(|r| r.min).min().unwrap())
            .max()
            .unwrap();
        let max = ranges
            .iter()
            .map(|r| r.iter().map(|r| r.max).max().unwrap())
            .min()
            .unwrap()
            .min(0);
        if min >= max || min > -40 * 256 {
            return Err("USB volume cannot provide startup attenuation".into());
        }
        let mut volume = Self {
            feature,
            ranges,
            snapshot: UsbHardwareVolume {
                available: true,
                min_db: min as f64 / 256.0,
                max_db: max as f64 / 256.0,
                current_db: current as f64 / 256.0,
                restore_limit_db: restore_limit as f64 / 256.0,
            },
        };
        // Never raise the device's current volume on connection. Read-back is
        // mandatory before any audio transfer can start.
        volume.set_targets(control, &startup)?;
        Ok(volume)
    }
    pub fn snapshot(&self) -> UsbHardwareVolume {
        self.snapshot.clone()
    }

    pub fn set(&mut self, control: &impl Control, db: f64) -> Result<UsbHardwareVolume, String> {
        if !db.is_finite() || db > 0.0 || db < -128.0 {
            return Err("Invalid USB volume".into());
        }
        let target = (db.min(self.snapshot.max_db) * 256.0).floor() as i32;
        self.set_targets(control, &vec![target; self.feature.channels.len()])
    }

    fn set_targets(
        &mut self,
        control: &impl Control,
        targets: &[i32],
    ) -> Result<UsbHardwareVolume, String> {
        let index = (self.feature.unit as u16) << 8 | self.feature.interface as u16;
        let mut loudest = i16::MIN;
        for ((channel, ranges), target) in self
            .feature
            .channels
            .iter()
            .zip(&self.ranges)
            .zip(targets.iter().copied())
        {
            // -32768 is USB's negative-infinity value. Preserve a channel that
            // was already silent; startup must never raise a quieter channel.
            let value = if target == i16::MIN as i32 {
                i16::MIN
            } else {
                ranges
                    .iter()
                    .filter(|r| r.min as i32 <= target)
                    .map(|r| r.floor(target))
                    .max()
                    .ok_or("USB volume below supported range")?
            };
            let selector = 0x200 | *channel as u16;
            control.transfer(false, 1, selector, index, &mut value.to_le_bytes())?;
            let mut readback = [0; 2];
            control.transfer(
                true,
                if self.feature.uac2 { 1 } else { 0x81 },
                selector,
                index,
                &mut readback,
            )?;
            let actual = i16::from_le_bytes(readback);
            if actual != value {
                return Err("USB volume read-back mismatch".into());
            }
            loudest = loudest.max(actual);
        }
        self.snapshot.current_db = loudest as f64 / 256.0;
        Ok(self.snapshot())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    struct Fake {
        db: Cell<i16>,
        mismatch: bool,
    }
    impl Control for Fake {
        fn transfer(
            &self,
            input: bool,
            request: u8,
            _: u16,
            _: u16,
            data: &mut [u8],
        ) -> Result<(), String> {
            if !input {
                if !self.mismatch {
                    self.db.set(i16::from_le_bytes([data[0], data[1]]));
                }
            } else if request == 2 {
                let range = [1, 0, 0, 0xa0, 0, 0, 0, 1]; // -96..0 dB, 1 dB steps.
                data.copy_from_slice(&range[..data.len()]);
            } else {
                data.copy_from_slice(&self.db.get().to_le_bytes());
            }
            Ok(())
        }
    }
    #[test]
    fn startup_attenuates_without_raising_and_rounds_down() {
        let io = Fake {
            db: Cell::new(0),
            mismatch: false,
        };
        let f = Feature {
            unit: 2,
            interface: 0,
            uac2: true,
            channels: vec![0],
        };
        let mut volume = Volume::open(&io, f.clone()).unwrap();
        assert_eq!(volume.snapshot().current_db, -40.0);
        assert_eq!(volume.set(&io, -25.2).unwrap().current_db, -26.0);
        io.db.set(-70 * 256);
        assert_eq!(Volume::open(&io, f).unwrap().snapshot().current_db, -70.0);
    }
    #[test]
    fn failed_readback_cannot_report_safe_volume() {
        let io = Fake {
            db: Cell::new(0),
            mismatch: true,
        };
        assert!(
            Volume::open(
                &io,
                Feature {
                    unit: 2,
                    interface: 0,
                    uac2: true,
                    channels: vec![0]
                }
            )
            .is_err()
        );
    }
    #[test]
    fn startup_preserves_silent_channels() {
        let io = Fake {
            db: Cell::new(i16::MIN),
            mismatch: false,
        };
        let v = Volume::open(
            &io,
            Feature {
                unit: 2,
                interface: 0,
                uac2: true,
                channels: vec![0],
            },
        )
        .unwrap();
        assert_eq!(v.snapshot().current_db, -128.0);
        assert_eq!(io.db.get(), i16::MIN);
    }
    #[test]
    fn topology_selects_playback_not_capture() {
        let raw = [
            9, 4, 0, 0, 0, 1, 1, 0x20, 0, 18, 0x24, 6, 2, 1, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 12, 0x24, 3, 3, 1, 3, 0, 2, 1, 0, 0, 0,
        ];
        assert_eq!(feature(&raw, 0, 1, 2).unwrap().unit, 2);
        assert!(feature(&raw, 0, 9, 2).is_none());
        assert!(feature(&raw, 1, 1, 2).is_none());
    }

    #[test]
    fn uac1_control_uses_min_max_resolution_and_verified_current() {
        struct Uac1(Cell<i16>);
        impl Control for Uac1 {
            fn transfer(
                &self,
                input: bool,
                request: u8,
                value: u16,
                index: u16,
                data: &mut [u8],
            ) -> Result<(), String> {
                assert_eq!((value, index), (0x200, 0x200));
                if !input {
                    assert_eq!(request, 1);
                    self.0.set(i16::from_le_bytes([data[0], data[1]]));
                } else {
                    let value: i16 = match request {
                        0x81 => self.0.get(),
                        0x82 => -80 * 256,
                        0x83 => 0,
                        0x84 => 128,
                        _ => panic!("Unexpected UAC1 request"),
                    };
                    data.copy_from_slice(&value.to_le_bytes());
                }
                Ok(())
            }
        }
        let raw = [
            9, 4, 0, 0, 0, 1, 1, 0, 0, 10, 0x24, 6, 2, 1, 1, 3, 0, 0, 0, 9, 0x24, 3, 3, 1, 3, 0, 2,
            0,
        ];
        let control = Uac1(Cell::new(-10 * 256));
        let mut volume = Volume::open(&control, feature(&raw, 0, 1, 2).unwrap()).unwrap();
        assert_eq!(volume.snapshot().current_db, -40.0);
        assert_eq!(volume.set(&control, -23.1).unwrap().current_db, -23.5);
        assert!(volume.set(&control, f64::NAN).is_err());
        assert!(volume.set(&control, 2.0).is_err());
    }

    #[test]
    fn startup_keeps_independent_channels_at_or_below_their_old_levels() {
        struct Stereo([Cell<i16>; 2]);
        impl Control for Stereo {
            fn transfer(
                &self,
                input: bool,
                request: u8,
                value: u16,
                _: u16,
                data: &mut [u8],
            ) -> Result<(), String> {
                let channel = (value & 255) as usize - 1;
                if !input {
                    self.0[channel].set(i16::from_le_bytes([data[0], data[1]]));
                } else if request == 2 {
                    data.copy_from_slice(&[1, 0, 0, 0xa0, 0, 0, 0, 1][..data.len()]);
                } else {
                    data.copy_from_slice(&self.0[channel].get().to_le_bytes());
                }
                Ok(())
            }
        }
        let io = Stereo([Cell::new(-70 * 256), Cell::new(-10 * 256)]);
        let volume = Volume::open(
            &io,
            Feature {
                unit: 2,
                interface: 0,
                uac2: true,
                channels: vec![1, 2],
            },
        )
        .unwrap();
        assert_eq!(io.0[0].get(), -70 * 256);
        assert_eq!(io.0[1].get(), -40 * 256);
        assert_eq!(volume.snapshot().restore_limit_db, -70.0);
    }
}
