//! Bounded thumbnail reuse for tracks that embed the same album artwork.

use std::collections::{VecDeque, hash_map::DefaultHasher};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, OnceLock, TryLockError};
use std::time::Duration;

const MAX_BYTES: usize = 8 << 20;
const MAX_ENTRIES: usize = 32;
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();

struct Entry {
    hash: u64,
    original: Arc<[u8]>,
    thumbnail: Arc<[u8]>,
    bytes: usize,
}

#[derive(Default)]
struct Cache {
    entries: VecDeque<Entry>,
    bytes: usize,
}

impl Cache {
    fn insert(&mut self, entry: Entry) {
        if entry.bytes > MAX_BYTES {
            return;
        }
        while self.bytes + entry.bytes > MAX_BYTES || self.entries.len() >= MAX_ENTRIES {
            self.bytes -= self
                .entries
                .pop_front()
                .expect("nonempty thumbnail cache")
                .bytes;
        }
        self.bytes += entry.bytes;
        self.entries.push_back(entry);
    }
}

/// Serialize large image decodes while keeping tag reads parallel. Reuse resized
/// artwork by content, not filename or album name; never confuse alternate covers.
pub fn library_thumbnail(
    data: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Arc<[u8]>, String> {
    check()?;
    let mut hasher = DefaultHasher::new();
    data.hash(&mut hasher);
    let hash = hasher.finish();
    let mutex = CACHE.get_or_init(Mutex::default);
    let mut cache = loop {
        check()?;
        match mutex.try_lock() {
            Ok(cache) => break cache,
            Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(10)),
            Err(TryLockError::Poisoned(_)) => return Err("thumbnail cache unavailable".into()),
        }
    };
    if let Some(index) = cache
        .entries
        .iter()
        .position(|entry| entry.hash == hash && &*entry.original == data)
    {
        let entry = cache.entries.remove(index).expect("cached thumbnail");
        let thumbnail = entry.thumbnail.clone();
        cache.entries.push_back(entry);
        return Ok(thumbnail);
    }
    let resized = super::resize(data, super::LIBRARY_MAX_DIMENSION, check)?;
    if let std::borrow::Cow::Owned(thumbnail) = &resized
        && data.len().saturating_add(thumbnail.len()) > MAX_BYTES
    {
        check()?;
        let std::borrow::Cow::Owned(thumbnail) = resized else {
            unreachable!("owned resized thumbnail");
        };
        return Ok(thumbnail.into());
    }
    let original: Arc<[u8]> = data.into();
    let thumbnail = match resized {
        std::borrow::Cow::Borrowed(_) => original.clone(),
        std::borrow::Cow::Owned(data) => data.into(),
    };
    check()?;
    let bytes = original.len()
        + if Arc::ptr_eq(&original, &thumbnail) {
            0
        } else {
            thumbnail.len()
        };
    cache.insert(Entry {
        hash,
        original,
        thumbnail: thumbnail.clone(),
        bytes,
    });
    Ok(thumbnail)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, ImageFormat, Rgb};
    use std::io::Cursor;

    #[test]
    fn repeated_artwork_reuses_pixels_and_checks_cancellation_on_hits() {
        let mut png = Cursor::new(Vec::new());
        ImageBuffer::from_pixel(1000, 1000, Rgb([30_u8, 90, 150]))
            .write_to(&mut png, ImageFormat::Png)
            .unwrap();
        let first = library_thumbnail(png.get_ref(), &|| Ok(())).unwrap();
        let second = library_thumbnail(png.get_ref(), &|| Ok(())).unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(super::super::dimensions(&first), (800, 800));
        assert!(library_thumbnail(png.get_ref(), &|| Err("cancelled".into())).is_err());
    }

    #[test]
    fn oversized_original_still_returns_a_resized_thumbnail() {
        let mut png = Cursor::new(Vec::new());
        ImageBuffer::from_pixel(1000, 1000, Rgb([30_u8, 90, 150]))
            .write_to(&mut png, ImageFormat::Png)
            .unwrap();
        // Trailing bytes leave the decoded pixels unchanged but put the
        // original beyond the cache budget.
        png.get_mut().resize(MAX_BYTES + 1, 0);
        let thumbnail = library_thumbnail(png.get_ref(), &|| Ok(())).unwrap();
        assert_eq!(super::super::dimensions(&thumbnail), (800, 800));
        assert!(thumbnail.len() < MAX_BYTES);
        let cache = CACHE.get().unwrap().lock().unwrap();
        assert!(
            cache
                .entries
                .iter()
                .all(|entry| entry.original.len() <= MAX_BYTES)
        );
    }

    #[test]
    fn cache_has_fixed_byte_and_entry_bounds() {
        let mut cache = Cache::default();
        for hash in 0..100 {
            let data: Arc<[u8]> = vec![0; 1 << 20].into();
            cache.insert(Entry {
                hash,
                original: data.clone(),
                thumbnail: data,
                bytes: 1 << 20,
            });
            assert!(cache.bytes <= MAX_BYTES);
            assert!(cache.entries.len() <= MAX_ENTRIES);
        }
        assert_eq!(cache.bytes, MAX_BYTES);
        assert_eq!(cache.entries.front().unwrap().hash, 92);
    }
}
