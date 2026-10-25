#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum FilenameError {
    #[error("{message}")]
    Invalid { message: String },
}

#[uniffi::export]
pub fn build_filename(template: String, metadata_json: String) -> Result<String, FilenameError> {
    spotiflac_core::filename::build_filename_json(&template, &metadata_json)
        .map_err(|message| FilenameError::Invalid { message })
}
