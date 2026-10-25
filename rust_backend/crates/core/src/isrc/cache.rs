use crate::matching::uppercase;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError, Weak};
use std::time::{Duration, Instant};

type Check<'a> = &'a (dyn Fn() -> Result<(), String> + Sync);
const MAX_DIRECTORIES: usize = 32;
const MAX_INDEX_BYTES: usize = 16 << 20;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileStamp {
    pub path: String,
    pub size: u64,
    pub modified_ns: i128,
    pub directory: bool,
}

/// The native owner supplies filesystem access. A cache hit never grants access
/// to a path: adapters must validate directory authority before each operation.
pub trait IndexFiles: Sync {
    /// Return entries in lexical depth-first walk order, preserving directory
    /// boundaries rather than sorting the complete path strings afterward.
    fn list(&self, directory: &str, check: Check<'_>) -> Result<Vec<FileStamp>, String>;
    fn read(&self, path: &str, check: Check<'_>) -> Result<String, String>;
    fn stat(&self, path: &str) -> Result<Option<FileStamp>, String>;
}

struct FileEntry {
    stamp: FileStamp,
    isrc: String,
}

struct Index {
    entries: BTreeMap<String, String>,
    files: Arc<BTreeMap<String, Arc<FileEntry>>>,
    bytes: usize,
    built_at: Instant,
}

#[derive(Default)]
struct Builder {
    lock: Mutex<()>,
    generation: AtomicU64,
}

struct Cached {
    index: Arc<Mutex<Index>>,
    bytes: usize,
    used: u64,
}

#[derive(Default)]
struct State {
    indexes: BTreeMap<String, Cached>,
    builders: BTreeMap<String, Weak<Builder>>,
    bytes: usize,
    sequence: u64,
}

impl State {
    fn remove(&mut self, directory: &str) {
        if let Some(entry) = self.indexes.remove(directory) {
            self.bytes -= entry.bytes;
        }
    }

    fn store(&mut self, directory: &str, index: Arc<Mutex<Index>>, bytes: usize) {
        self.remove(directory);
        // Include a conservative allowance for tree nodes/control blocks. This
        // bounds retained cache memory, not snapshots owned by active callers.
        let bytes = bytes.saturating_add(directory.len() + std::mem::size_of::<Cached>() + 64);
        if bytes > MAX_INDEX_BYTES {
            return;
        }
        while self.indexes.len() >= MAX_DIRECTORIES || self.bytes + bytes > MAX_INDEX_BYTES {
            let oldest = self
                .indexes
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(directory, _)| directory.clone())
                .expect("nonempty ISRC cache");
            self.remove(&oldest);
        }
        self.sequence += 1;
        self.bytes += bytes;
        self.indexes.insert(
            directory.into(),
            Cached {
                index,
                bytes,
                used: self.sequence,
            },
        );
    }
}

impl Index {
    fn insert_match(&mut self, isrc: String, path: String) {
        // Replacing a value retains the map's existing key allocation.
        match self.entries.entry(isrc) {
            std::collections::btree_map::Entry::Occupied(mut entry) => {
                self.bytes -= entry.get().capacity();
                self.bytes += path.capacity();
                entry.insert(path);
            }
            std::collections::btree_map::Entry::Vacant(entry) => {
                self.bytes += std::mem::size_of::<(String, String)>()
                    + 64
                    + entry.key().capacity()
                    + path.capacity();
                entry.insert(path);
            }
        }
    }

    fn insert_file(&mut self, path: String, file: Arc<FileEntry>) {
        let cost = |file: &FileEntry| {
            std::mem::size_of::<FileEntry>()
                + 32
                + file.stamp.path.capacity()
                + file.isrc.capacity()
        };
        match Arc::make_mut(&mut self.files).entry(path) {
            std::collections::btree_map::Entry::Occupied(mut entry) => {
                self.bytes -= cost(entry.get());
                self.bytes += cost(&file);
                entry.insert(file);
            }
            std::collections::btree_map::Entry::Vacant(entry) => {
                self.bytes += std::mem::size_of::<(String, Arc<FileEntry>)>()
                    + 64
                    + entry.key().capacity()
                    + cost(&file);
                entry.insert(file);
            }
        }
    }
}

pub struct IndexCache {
    state: Mutex<State>,
    ttl: Duration,
}

impl Default for IndexCache {
    fn default() -> Self {
        Self::with_ttl(Duration::from_secs(5 * 60))
    }
}

impl IndexCache {
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            state: Mutex::default(),
            ttl,
        }
    }

    fn cached(&self, directory: &str) -> Option<Arc<Mutex<Index>>> {
        let mut state = self.state.lock().expect("ISRC cache lock");
        state.sequence += 1;
        let sequence = state.sequence;
        state.indexes.get_mut(directory).map(|entry| {
            entry.used = sequence;
            Arc::clone(&entry.index)
        })
    }

    fn fresh(&self, directory: &str) -> Option<Arc<Mutex<Index>>> {
        self.cached(directory)
            .filter(|index| index.lock().expect("ISRC index lock").built_at.elapsed() < self.ttl)
    }

    fn index(
        &self,
        directory: &str,
        files: &dyn IndexFiles,
        force: bool,
        check: Check<'_>,
    ) -> Result<Arc<Mutex<Index>>, String> {
        check()?;
        if !force && let Some(index) = self.fresh(directory) {
            return Ok(index);
        }
        let builder = {
            let mut state = self.state.lock().expect("ISRC cache lock");
            state
                .builders
                .retain(|_, builder| builder.strong_count() > 0);
            let entry = state.builders.entry(directory.into()).or_default();
            entry.upgrade().unwrap_or_else(|| {
                let lock = Arc::new(Builder::default());
                *entry = Arc::downgrade(&lock);
                lock
            })
        };
        let _building = wait_for_builder(&builder.lock, check)?;
        if !force && let Some(index) = self.fresh(directory) {
            return Ok(index);
        }
        let generation = builder.generation.load(Ordering::Acquire);
        let previous = self
            .cached(directory)
            .map(|index| index.lock().expect("ISRC index lock").files.clone())
            .unwrap_or_default();
        let mut index = Index {
            entries: BTreeMap::new(),
            files: Arc::default(),
            // Account for the two maps' sparsely populated root nodes too.
            bytes: std::mem::size_of::<Index>() + 2048,
            built_at: Instant::now(),
        };
        let mut changed = Vec::new();
        if !directory.is_empty() {
            let listed = files.list(directory, check)?;
            for stamp in listed {
                check()?;
                if stamp.directory || !super::supported(&stamp.path) {
                    continue;
                }
                if let Some(entry) = previous.get(&stamp.path)
                    && entry.stamp == stamp
                {
                    if !entry.isrc.is_empty() {
                        index.insert_match(entry.isrc.clone(), stamp.path.clone());
                    }
                    index.insert_file(stamp.path, Arc::clone(entry));
                } else {
                    changed.push(stamp);
                }
            }
        }
        let next = AtomicUsize::new(0);
        let values = Mutex::new(vec![String::new(); changed.len()]);
        std::thread::scope(|scope| {
            let handles = (0..changed.len().min(4))
                .map(|_| {
                    scope.spawn(|| {
                        loop {
                            check()?;
                            let position = next.fetch_add(1, Ordering::Relaxed);
                            let Some(stamp) = changed.get(position) else {
                                break;
                            };
                            let isrc = uppercase(&files.read(&stamp.path, check)?);
                            values.lock().expect("ISRC parse results lock")[position] = isrc;
                        }
                        Ok::<_, String>(())
                    })
                })
                .collect::<Vec<_>>();
            for handle in handles {
                handle
                    .join()
                    .map_err(|_| "ISRC reader worker panicked".to_owned())??;
            }
            Ok::<_, String>(())
        })?;
        // Changed files are applied after reused entries, in walk order, just
        // as Go does after joining its four parsing workers.
        for (stamp, isrc) in changed
            .into_iter()
            .zip(values.into_inner().expect("ISRC parse results lock"))
        {
            check()?;
            if !isrc.is_empty() {
                index.insert_match(isrc.clone(), stamp.path.clone());
            }
            index.insert_file(stamp.path.clone(), Arc::new(FileEntry { stamp, isrc }));
        }
        check()?;
        let bytes = index.bytes;
        let index = Arc::new(Mutex::new(index));
        if !directory.is_empty() {
            let mut state = self.state.lock().expect("ISRC cache lock");
            if builder.generation.load(Ordering::Acquire) == generation {
                state.store(directory, Arc::clone(&index), bytes);
            }
        }
        Ok(index)
    }

    pub fn check(
        &self,
        directory: &str,
        isrc: &str,
        files: &dyn IndexFiles,
        check: Check<'_>,
    ) -> Result<String, String> {
        check()?;
        if directory.is_empty() || isrc.is_empty() {
            return Ok(String::new());
        }
        let index = self.index(directory, files, false, check)?;
        let key = uppercase(isrc);
        let path = index
            .lock()
            .expect("ISRC index lock")
            .entries
            .get(&key)
            .cloned();
        let Some(path) = path else {
            return Ok(String::new());
        };
        check()?;
        let exists = files
            .stat(&path)?
            .is_some_and(|stamp| !stamp.directory && stamp.size > 0);
        check()?;
        if exists {
            Ok(path)
        } else {
            index.lock().expect("ISRC index lock").entries.remove(&key);
            Ok(String::new())
        }
    }

    pub fn add(
        &self,
        directory: &str,
        isrc: &str,
        path: &str,
        files: &dyn IndexFiles,
        check: Check<'_>,
    ) -> Result<(), String> {
        check()?;
        if directory.is_empty() || isrc.is_empty() || path.is_empty() {
            return Ok(());
        }
        if let Some(index_owner) = self.cached(directory) {
            let stamp = files.stat(path)?;
            check()?;
            let mut index = index_owner.lock().expect("ISRC index lock");
            let isrc = uppercase(isrc);
            index.insert_match(isrc.clone(), path.into());
            if let Some(stamp) = stamp {
                index.insert_file(path.into(), Arc::new(FileEntry { stamp, isrc }));
            }
            index.built_at = Instant::now();
            let bytes = index.bytes;
            drop(index);
            let mut state = self.state.lock().expect("ISRC cache lock");
            if let Some(current) = state.indexes.get(directory)
                && Arc::ptr_eq(&current.index, &index_owner)
            {
                state.store(directory, index_owner, bytes);
            }
        }
        Ok(())
    }

    pub fn invalidate(&self, directory: &str) {
        let mut state = self.state.lock().expect("ISRC cache lock");
        state.remove(directory);
        if let Some(builder) = state.builders.get(directory).and_then(Weak::upgrade) {
            builder.generation.fetch_add(1, Ordering::AcqRel);
        }
        state
            .builders
            .retain(|_, builder| builder.strong_count() > 0);
    }

    pub fn clear(&self) {
        let mut state = self.state.lock().expect("ISRC cache lock");
        state.indexes.clear();
        state.bytes = 0;
        state.builders.retain(|_, builder| {
            if let Some(builder) = builder.upgrade() {
                builder.generation.fetch_add(1, Ordering::AcqRel);
                true
            } else {
                false
            }
        });
    }
}

fn wait_for_builder<'a>(
    builder: &'a Mutex<()>,
    check: Check<'_>,
) -> Result<MutexGuard<'a, ()>, String> {
    loop {
        check()?;
        match builder.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(TryLockError::Poisoned(error)) => return Ok(error.into_inner()),
            Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(5)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Barrier;

    struct Files {
        listed: Mutex<Vec<FileStamp>>,
        reads: AtomicUsize,
        lists: AtomicUsize,
        block_first: Option<(Arc<Barrier>, Arc<Barrier>)>,
    }

    impl Files {
        fn new() -> Self {
            Self {
                listed: Mutex::new(vec![FileStamp {
                    path: "example.flac".into(),
                    size: 1,
                    modified_ns: 1,
                    directory: false,
                }]),
                reads: AtomicUsize::new(0),
                lists: AtomicUsize::new(0),
                block_first: None,
            }
        }
    }

    impl IndexFiles for Files {
        fn list(&self, _: &str, check: Check<'_>) -> Result<Vec<FileStamp>, String> {
            if self.lists.fetch_add(1, Ordering::SeqCst) == 0
                && let Some((started, release)) = &self.block_first
            {
                started.wait();
                release.wait();
            }
            check()?;
            Ok(self.listed.lock().unwrap().clone())
        }
        fn read(&self, _: &str, check: Check<'_>) -> Result<String, String> {
            check()?;
            self.reads.fetch_add(1, Ordering::SeqCst);
            Ok("EXAMPLE".into())
        }
        fn stat(&self, path: &str) -> Result<Option<FileStamp>, String> {
            Ok(self
                .listed
                .lock()
                .unwrap()
                .iter()
                .find(|stamp| stamp.path == path)
                .cloned())
        }
    }

    #[test]
    fn rebuild_shares_unchanged_entries_and_keeps_changed_duplicate_walk_order() {
        let files = Files::new();
        files.listed.lock().unwrap().push(FileStamp {
            path: "second.flac".into(),
            size: 1,
            modified_ns: 1,
            directory: false,
        });
        let cache = IndexCache::default();
        let first = cache.index("directory", &files, false, &|| Ok(())).unwrap();
        let previous = Arc::clone(&first.lock().unwrap().files);
        let second = cache.index("directory", &files, true, &|| Ok(())).unwrap();
        let next = Arc::clone(&second.lock().unwrap().files);
        assert!(Arc::ptr_eq(
            &previous["example.flac"],
            &next["example.flac"]
        ));
        assert_eq!(files.reads.load(Ordering::SeqCst), 2);
        assert_eq!(
            cache
                .check("directory", "example", &files, &|| Ok(()))
                .unwrap(),
            "second.flac"
        );
        files.listed.lock().unwrap()[0].size = 2;
        cache.index("directory", &files, true, &|| Ok(())).unwrap();
        assert_eq!(
            cache
                .check("directory", "example", &files, &|| Ok(()))
                .unwrap(),
            "example.flac"
        );
        assert_eq!(files.reads.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn cache_bounds_directories_bytes_and_dead_builder_keys() {
        let files = Files::new();
        let cache = IndexCache::default();
        for directory in 0..MAX_DIRECTORIES * 2 {
            cache
                .index(&directory.to_string(), &files, false, &|| Ok(()))
                .unwrap();
        }
        {
            let state = cache.state.lock().unwrap();
            assert_eq!(state.indexes.len(), MAX_DIRECTORIES);
            assert!(state.bytes <= MAX_INDEX_BYTES);
            assert!(state.builders.len() <= 1);
        }
        let last = cache
            .cached(&(MAX_DIRECTORIES * 2 - 1).to_string())
            .unwrap();
        let mut state = cache.state.lock().unwrap();
        state.store("oversized", last, MAX_INDEX_BYTES);
        assert!(!state.indexes.contains_key("oversized"));
        drop(state);
        cache.clear();
        let state = cache.state.lock().unwrap();
        assert!(state.indexes.is_empty());
        assert!(state.builders.is_empty());
        assert_eq!(state.bytes, 0);
    }

    #[test]
    fn invalidation_and_clear_preserve_active_builder_and_reject_its_stale_publish() {
        for clear in [false, true] {
            let started = Arc::new(Barrier::new(2));
            let release = Arc::new(Barrier::new(2));
            let mut files = Files::new();
            files.block_first = Some((started.clone(), release.clone()));
            let cache = IndexCache::default();
            std::thread::scope(|scope| {
                let first = scope.spawn(|| cache.index("directory", &files, false, &|| Ok(())));
                started.wait();
                let original = cache.state.lock().unwrap().builders["directory"]
                    .upgrade()
                    .unwrap();
                if clear {
                    cache.clear();
                } else {
                    cache.invalidate("directory");
                }
                let same = cache.state.lock().unwrap().builders["directory"]
                    .upgrade()
                    .unwrap();
                assert!(Arc::ptr_eq(&original, &same));
                release.wait();
                first.join().unwrap().unwrap();
                assert!(cache.cached("directory").is_none());
                cache.index("directory", &files, false, &|| Ok(())).unwrap();
                assert!(cache.cached("directory").is_some());
                assert_eq!(files.lists.load(Ordering::SeqCst), 2);
            });
        }
    }

    #[test]
    fn cancelled_rebuild_never_replaces_previous_snapshot() {
        let files = Files::new();
        let cache = IndexCache::default();
        let previous = cache.index("directory", &files, false, &|| Ok(())).unwrap();
        let checks = AtomicUsize::new(0);
        let result = cache.index("directory", &files, true, &|| {
            if checks.fetch_add(1, Ordering::SeqCst) >= 3 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert!(matches!(result, Err(error) if error == "cancelled"));
        assert!(Arc::ptr_eq(&previous, &cache.cached("directory").unwrap()));
    }
}
