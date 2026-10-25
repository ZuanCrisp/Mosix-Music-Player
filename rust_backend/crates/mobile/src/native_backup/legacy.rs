//! Deserialize the legacy envelope one history object at a time. Large history
//! arrays never become a Value/List or cross the platform bridge.
use super::*;
use serde::de::{self, DeserializeSeed, IgnoredAny, MapAccess, SeqAccess, Visitor};
use std::{
    fmt,
    io::{Seek, SeekFrom},
};

struct History<'a> {
    writer: &'a mut BufWriter<File>,
    count: u64,
    bytes: u64,
    check: Check<'a>,
}
impl History<'_> {
    fn reset(&mut self) -> Result<(), String> {
        self.writer
            .flush()
            .map_err(|e| err("flush legacy history", e))?;
        self.writer
            .get_mut()
            .set_len(0)
            .map_err(|e| err("reset legacy history", e))?;
        self.writer
            .seek(SeekFrom::Start(0))
            .map_err(|e| err("seek legacy history", e))?;
        self.count = 0;
        self.bytes = 0;
        Ok(())
    }
}
struct RootSeed<'a, 'b>(&'a mut History<'b>);
impl<'de> DeserializeSeed<'de> for RootSeed<'_, '_> {
    type Value = Value;
    fn deserialize<D: de::Deserializer<'de>>(self, deserializer: D) -> Result<Value, D::Error> {
        deserializer.deserialize_map(RootVisitor(self.0))
    }
}
struct RootVisitor<'a, 'b>(&'a mut History<'b>);
impl<'de> Visitor<'de> for RootVisitor<'_, '_> {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("backup envelope")
    }
    fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Value, M::Error> {
        let mut root = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            (self.0.check)().map_err(de::Error::custom)?;
            let value = if key == "data" {
                map.next_value_seed(DataSeed(self.0))?
            } else {
                map.next_value::<Value>()?
            };
            root.insert(key, value);
        }
        Ok(root.into())
    }
}
struct DataSeed<'a, 'b>(&'a mut History<'b>);
impl<'de> DeserializeSeed<'de> for DataSeed<'_, '_> {
    type Value = Value;
    fn deserialize<D: de::Deserializer<'de>>(self, deserializer: D) -> Result<Value, D::Error> {
        self.0.reset().map_err(de::Error::custom)?;
        deserializer.deserialize_map(DataVisitor(self.0))
    }
}
struct DataVisitor<'a, 'b>(&'a mut History<'b>);
impl<'de> Visitor<'de> for DataVisitor<'_, '_> {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("backup data")
    }
    fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Value, M::Error> {
        let mut data = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            (self.0.check)().map_err(de::Error::custom)?;
            let value = if key == "history" {
                self.0.reset().map_err(de::Error::custom)?;
                if map.next_value_seed(HistorySeed(self.0))? {
                    Value::Array(Vec::new())
                } else {
                    Value::Null
                }
            } else {
                map.next_value::<Value>()?
            };
            data.insert(key, value);
        }
        Ok(data.into())
    }
}
struct HistorySeed<'a, 'b>(&'a mut History<'b>);
impl<'de> DeserializeSeed<'de> for HistorySeed<'_, '_> {
    type Value = bool;
    fn deserialize<D: de::Deserializer<'de>>(self, deserializer: D) -> Result<bool, D::Error> {
        deserializer.deserialize_any(HistoryVisitor(self.0))
    }
}
struct HistoryVisitor<'a, 'b>(&'a mut History<'b>);
impl<'de> Visitor<'de> for HistoryVisitor<'_, '_> {
    type Value = bool;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("optional history array")
    }
    fn visit_seq<S: SeqAccess<'de>>(self, mut seq: S) -> Result<bool, S::Error> {
        while let Some(row) = seq.next_element::<Value>()? {
            (self.0.check)().map_err(de::Error::custom)?;
            if !row.is_object() {
                continue;
            }
            let encoded = serde_json::to_vec(&row).map_err(de::Error::custom)?;
            if encoded.len() as u64 > MAX_ROW_BYTES {
                return Err(de::Error::custom(
                    "Legacy backup history row exceeds size limit",
                ));
            }
            self.0.bytes += encoded.len() as u64 + 1;
            if self.0.bytes > MAX_HISTORY_BYTES {
                return Err(de::Error::custom(
                    "Legacy backup history exceeds size limit",
                ));
            }
            self.0
                .writer
                .write_all(&encoded)
                .and_then(|_| self.0.writer.write_all(b"\n"))
                .map_err(de::Error::custom)?;
            self.0.count += 1;
        }
        Ok(true)
    }
    fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<bool, M::Error> {
        while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
        Ok(false)
    }
    fn visit_bool<E: de::Error>(self, _: bool) -> Result<bool, E> {
        Ok(false)
    }
    fn visit_i64<E: de::Error>(self, _: i64) -> Result<bool, E> {
        Ok(false)
    }
    fn visit_u64<E: de::Error>(self, _: u64) -> Result<bool, E> {
        Ok(false)
    }
    fn visit_f64<E: de::Error>(self, _: f64) -> Result<bool, E> {
        Ok(false)
    }
    fn visit_str<E: de::Error>(self, _: &str) -> Result<bool, E> {
        Ok(false)
    }
    fn visit_none<E: de::Error>(self) -> Result<bool, E> {
        Ok(false)
    }
    fn visit_unit<E: de::Error>(self) -> Result<bool, E> {
        Ok(false)
    }
}

pub(super) fn split(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let input = required(request, "input_path")?;
    if fs::metadata(input)
        .map_err(|e| err("legacy backup metadata", e))?
        .len()
        > MAX_HISTORY_BYTES + (8 << 20)
    {
        return Err("Legacy backup exceeds size limit".into());
    }
    let history_path = output_path(request, "ndjson_path")?;
    let metadata_path = output_path(request, "metadata_path")?;
    if history_path == metadata_path || history_path == input || metadata_path == input {
        return Err("Backup staging paths must be distinct".into());
    }
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(history_path)
        .map_err(|e| err("create legacy history", e))?;
    let mut metadata_created = false;
    let result = (|| {
        let mut writer = BufWriter::new(file);
        let mut context = History {
            writer: &mut writer,
            count: 0,
            bytes: 0,
            check,
        };
        let input = File::open(input).map_err(|e| err("open legacy backup", e))?;
        let mut deserializer = serde_json::Deserializer::from_reader(BufReader::new(input));
        let root = RootSeed(&mut context)
            .deserialize(&mut deserializer)
            .map_err(|e| err("decode legacy backup", e))?;
        deserializer
            .end()
            .map_err(|e| err("legacy backup trailing data", e))?;
        if root["magic"] != "spotiflac-backup" || !root["data"].is_object() {
            return Err("Invalid legacy backup envelope".into());
        }
        let count = context.count;
        writer
            .flush()
            .and_then(|_| writer.get_ref().sync_all())
            .map_err(|e| err("publish legacy history", e))?;
        let encoded = serde_json::to_vec(&root).map_err(|e| err("encode legacy metadata", e))?;
        if encoded.len() > 8 << 20 {
            return Err("Legacy backup metadata exceeds size limit".into());
        }
        check()?;
        let mut metadata = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(metadata_path)
            .map_err(|e| err("create legacy metadata", e))?;
        metadata_created = true;
        metadata
            .write_all(&encoded)
            .and_then(|_| metadata.sync_all())
            .map_err(|e| err("publish legacy metadata", e))?;
        check()?;
        Ok(
            json!({"published":true,"count":count,"history_path":history_path,"metadata_path":metadata_path}),
        )
    })();
    if result.is_err() {
        let _ = fs::remove_file(history_path);
        if metadata_created {
            let _ = fs::remove_file(metadata_path);
        }
    }
    // A create_new conflict must never remove the owner's preexisting file.
    result
}
