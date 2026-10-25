use super::Backend;
use serde_json::Value;
use spotiflac_core::metadata::share::{self, Provider, Request, ShareResult};
use spotiflac_providers::resolver::{Check, ResolverError};
use std::collections::{BTreeMap, VecDeque};

#[derive(Default)]
pub(super) struct Cache {
    values: BTreeMap<(u64, String), String>,
    order: VecDeque<(u64, String)>,
}

impl Cache {
    pub fn clear(&mut self) {
        self.values.clear();
        self.order.clear();
    }

    fn put(&mut self, key: (u64, String), value: String) {
        if !self.values.contains_key(&key) {
            self.order.push_back(key.clone());
        }
        self.values.insert(key, value);
        while self.order.len() > 128 {
            if let Some(oldest) = self.order.pop_front() {
                self.values.remove(&oldest);
            }
        }
    }
}

impl Backend {
    pub fn find_collection_across_extensions_json(
        &self,
        request_json: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(60, check, |check| {
            let request = Request::parse(request_json)
                .map_err(|error| ResolverError::Failed(error.to_string()))?;
            if request.name.is_empty() {
                return Ok("[]".into());
            }
            let revision = self.manager.metadata_revision();
            let providers = self
                .manager
                .share_providers(&request.source_extension_id)
                .map_err(|error| ResolverError::Failed(error.to_string()))?;
            let key = (revision, request.cache_key(&providers));
            if let Some(cached) = self
                .share_cache
                .lock()
                .expect("share cache lock")
                .values
                .get(&key)
            {
                return Ok(cached.clone());
            }
            let query = request.query();
            // Go searches all providers concurrently; retain snapshot order on join.
            let results = std::thread::scope(|scope| {
                let workers: Vec<_> = providers
                    .iter()
                    .map(|provider| {
                        let request = &request;
                        let query = &query;
                        scope
                            .spawn(move || self.share_for_provider(provider, request, query, check))
                    })
                    .collect();
                workers
                    .into_iter()
                    .map(|worker| {
                        worker
                            .join()
                            .map_err(|_| ResolverError::Failed("collection search panicked".into()))
                    })
                    .collect::<Result<Vec<_>, _>>()
            })?;
            check().map_err(ResolverError::Cancelled)?;
            let response = serde_json::to_string(&results)
                .map_err(|error| ResolverError::Failed(error.to_string()))?;
            if revision == self.manager.metadata_revision()
                && results.iter().all(ShareResult::cacheable)
            {
                self.share_cache
                    .lock()
                    .expect("share cache lock")
                    .put(key, response.clone());
            }
            Ok(response)
        })
    }

    fn share_for_provider(
        &self,
        provider: &Provider,
        request: &Request,
        query: &str,
        check: &Check<'_>,
    ) -> ShareResult {
        let fetch = || -> Result<Vec<Value>, ResolverError> {
            let filter = match request.kind.as_str() {
                "album" => "albums",
                "artist" => "artists",
                _ => "",
            };
            if !filter.is_empty() {
                let arguments =
                    serde_json::json!([query, {"filter":filter,"limit":10}]).to_string();
                let custom =
                    self.provider_metadata_call(&provider.id, "customSearch", &arguments, check);
                check().map_err(ResolverError::Cancelled)?;
                if let Ok(Value::Array(tracks)) = custom
                    && !tracks.is_empty()
                {
                    return Ok(tracks);
                }
            }
            let arguments = serde_json::json!([query, 10]).to_string();
            let result =
                self.provider_metadata_call(&provider.id, "searchTracks", &arguments, check)?;
            Ok(result["tracks"].as_array().cloned().unwrap_or_default())
        };
        match fetch() {
            Ok(tracks) => share::select(provider, request, &tracks),
            Err(error) => {
                let mut result = ShareResult::new(provider);
                result.error = error.to_string();
                result
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Cache;

    #[test]
    fn collection_share_cache_is_bounded_fifo_and_revisions_are_distinct() {
        let mut cache = Cache::default();
        for index in 0..128 {
            cache.put((0, index.to_string()), "original".into());
        }
        assert!(cache.values.contains_key(&(0, "0".into())));
        cache.put((0, "0".into()), "updated".into());
        cache.put((1, "0".into()), "new revision".into());
        assert_eq!(cache.values.len(), 128);
        assert!(!cache.values.contains_key(&(0, "0".into())));
        assert!(cache.values.contains_key(&(0, "1".into())));
        assert_eq!(cache.values[&(1, "0".into())], "new revision");
        cache.clear();
        assert!(cache.values.is_empty() && cache.order.is_empty());
    }
}
