use super::{RepositoryError, error};
use spotiflac_network::url::UrlParts;

#[derive(Debug, PartialEq, Eq)]
pub enum RegistryLocation {
    Direct(String),
    GitHub { owner: String, repository: String },
}

pub fn registry_location(input: &str) -> Result<RegistryLocation, RepositoryError> {
    let input = input.trim();
    if input.is_empty() {
        return Err(error("registry URL is empty"));
    }
    if input.contains("raw.githubusercontent.com") {
        return Ok(RegistryLocation::Direct(input.into()));
    }
    let Some(path) = input
        .strip_prefix("https://github.com/")
        .or_else(|| input.strip_prefix("http://github.com/"))
    else {
        return Ok(RegistryLocation::Direct(input.into()));
    };
    let mut parts = path.splitn(3, '/');
    let owner = parts.next().unwrap_or("");
    let repository = parts.next().unwrap_or("");
    if owner.is_empty() || repository.is_empty() {
        return Err(error(
            "invalid GitHub URL: expected github.com/<owner>/<repo>",
        ));
    }
    Ok(RegistryLocation::GitHub {
        owner: owner.into(),
        repository: repository.strip_suffix(".git").unwrap_or(repository).into(),
    })
}

pub fn require_https(input: &str, context: &str) -> Result<(), RepositoryError> {
    if input.is_empty() {
        return Err(error(format!("{context} URL is empty")));
    }
    let url = UrlParts::parse(input)
        .filter(|url| !url.hostname.is_empty())
        .ok_or_else(|| error(format!("{context} URL is invalid: {input}")))?;
    if url.scheme != "https" {
        return Err(error(format!("{context} URL must use https: {input}")));
    }
    Ok(())
}
