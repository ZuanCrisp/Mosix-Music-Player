use crate::manager::ExtensionManager;
use spotiflac_extensions::repository::{ExtensionRepository as CoreRepository, RepositoryError};
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ExtensionRepositoryError {
    #[error("{0}")]
    Operation(String),
}

impl From<RepositoryError> for ExtensionRepositoryError {
    fn from(error: RepositoryError) -> Self {
        Self::Operation(error.to_string())
    }
}

/// Retains the manager for current installed versions and shares its network
/// policy. Registry and package IO must run on a native background thread.
#[derive(uniffi::Object)]
pub struct ExtensionRepository {
    inner: CoreRepository,
    manager: Arc<ExtensionManager>,
}

#[uniffi::export]
impl ExtensionRepository {
    #[uniffi::constructor]
    pub fn new(
        manager: Arc<ExtensionManager>,
        cache_directory: String,
    ) -> Result<Self, ExtensionRepositoryError> {
        let inner = manager
            .inner
            .environment()
            .repository(Path::new(&cache_directory))?;
        Ok(Self { inner, manager })
    }

    pub fn registry_url(&self) -> Result<String, ExtensionRepositoryError> {
        self.inner.registry_url().map_err(Into::into)
    }

    pub fn set_registry_url(&self, url: String) -> Result<(), ExtensionRepositoryError> {
        self.inner.set_registry_url(&url).map_err(Into::into)
    }

    pub fn clear_registry_url(&self) -> Result<(), ExtensionRepositoryError> {
        self.inner.clear_registry_url().map_err(Into::into)
    }

    pub fn extensions(&self, force_refresh: bool) -> Result<String, ExtensionRepositoryError> {
        self.search_inner(force_refresh, "", "")
    }

    pub fn download(
        &self,
        extension_id: String,
        destination_directory: String,
    ) -> Result<String, ExtensionRepositoryError> {
        self.inner
            .download(&extension_id, Path::new(&destination_directory))
            .map(|path| path.to_string_lossy().into_owned())
            .map_err(Into::into)
    }

    pub fn shutdown(&self) {
        self.inner.shutdown();
    }
}

impl ExtensionRepository {
    fn search_inner(
        &self,
        force: bool,
        query: &str,
        category: &str,
    ) -> Result<String, ExtensionRepositoryError> {
        let installed = self
            .manager
            .inner
            .installed_versions()
            .map_err(|e| ExtensionRepositoryError::Operation(e.to_string()))?;
        self.inner
            .extensions(force, &installed, query, category)
            .map_err(Into::into)
    }
}
