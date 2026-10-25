use super::Backend;
use spotiflac_providers::resolver::Check;

impl Backend {
    pub fn fetch_music_brainz_genre_by_isrc(
        &self,
        isrc: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        // Three 10-second HTTP attempts plus two 2-second retry waits fit
        // within this root deadline. Cancellation still applies per caller.
        self.metadata_operation(35, check, |check| self.musicbrainz.genre(isrc, check))
    }

    pub fn fetch_music_brainz_album_artist_by_isrc(
        &self,
        isrc: &str,
        album_name: &str,
        check: &Check<'_>,
    ) -> Result<String, String> {
        self.metadata_operation(35, check, |check| {
            self.musicbrainz.album_artist(isrc, album_name, check)
        })
    }
}
