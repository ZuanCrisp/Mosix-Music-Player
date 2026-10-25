use super::{EnvironmentError, ExtensionEnvironment};
use spotiflac_core::isrc::{IndexCache, NativeFiles};
use std::sync::atomic::Ordering;

type Check<'a> = &'a (dyn Fn() -> Result<(), String> + Sync);

impl ExtensionEnvironment {
    fn with_index<T>(
        &self,
        check: Check<'_>,
        operation: impl FnOnce(&IndexCache, &NativeFiles, Check<'_>) -> Result<T, String>,
    ) -> Result<T, EnvironmentError> {
        let _operation = self.enter()?;
        let guarded = || {
            if self.closed.load(Ordering::Acquire) {
                Err("extension environment closed".into())
            } else {
                check()
            }
        };
        guarded().map_err(EnvironmentError::Index)?;
        let result =
            operation(&self.isrc, &NativeFiles, &guarded).map_err(EnvironmentError::Index)?;
        guarded().map_err(EnvironmentError::Index)?;
        Ok(result)
    }

    /// Trusted native entry points share the SDK's index, while JavaScript uses
    /// a scoped IndexFiles adapter and revalidates native directory grants.
    pub fn add_to_isrc_index(
        &self,
        directory: &str,
        isrc: &str,
        path: &str,
        check: Check<'_>,
    ) -> Result<(), EnvironmentError> {
        self.with_index(check, |cache, files, check| {
            cache.add(directory, isrc, path, files, check)
        })
    }

    pub fn invalidate_isrc_cache(&self, directory: &str) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.isrc.invalidate(directory);
        Ok(())
    }

    pub(crate) fn clear_isrc_cache(&self) -> Result<(), EnvironmentError> {
        let _operation = self.enter()?;
        self.isrc.clear();
        Ok(())
    }
}
