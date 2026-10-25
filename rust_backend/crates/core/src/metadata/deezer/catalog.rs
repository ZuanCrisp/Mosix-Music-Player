use super::{Artist, Track, Tracks, best_image};
use crate::lyrics::json::{Update, go_deserialize};
use serde::Deserialize;

#[derive(Clone, Debug, Default)]
pub struct ApiError {
    pub error_type: String,
    pub message: String,
    pub code: isize,
}
go_deserialize!(ApiError { "type" => error_type, "message" => message, "code" => code, });

/// A repeated non-null Go pointer field merges into the existing object.
#[derive(Clone, Debug, Default)]
pub struct OptionalApiError(pub Option<ApiError>);

impl<'de> Update<'de> for OptionalApiError {
    fn update<D: serde::Deserializer<'de>>(&mut self, decoder: D) -> Result<(), D::Error> {
        match Option::<&serde_json::value::RawValue>::deserialize(decoder)? {
            None => self.0 = None,
            Some(raw) => {
                self.0
                    .get_or_insert_default()
                    .update(&mut serde_json::Deserializer::from_str(raw.get()))
                    .map_err(serde::de::Error::custom)?;
            }
        }
        Ok(())
    }
}

macro_rules! search_page {
    ($name:ident, $item:ty) => {
        #[derive(Clone, Debug, Default)]
        pub struct $name {
            pub data: Option<Vec<$item>>,
            pub error: OptionalApiError,
        }
        go_deserialize!($name { "data" => data, "error" => error, });
    };
}
search_page!(TrackSearch, Track);
search_page!(ArtistSearch, Artist);
search_page!(AlbumSearch, SearchAlbum);
search_page!(PlaylistSearch, SearchPlaylist);

#[derive(Clone, Debug, Default)]
pub struct TrackPage {
    pub data: Option<Vec<Track>>,
    pub next: String,
}
go_deserialize!(TrackPage { "data" => data, "next" => next, });

#[derive(Clone, Debug, Default)]
pub struct Genre {
    pub id: isize,
    pub name: String,
}
go_deserialize!(Genre { "id" => id, "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct Genres {
    pub data: Option<Vec<Genre>>,
}
go_deserialize!(Genres { "data" => data, });

impl Genres {
    pub fn display(&self) -> String {
        self.data
            .iter()
            .flatten()
            .map(|genre| genre.name.as_str())
            .filter(|name| !name.is_empty())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

#[derive(Clone, Debug, Default)]
pub struct FullAlbum {
    pub id: i64,
    pub title: String,
    pub cover: String,
    pub cover_medium: String,
    pub cover_big: String,
    pub cover_xl: String,
    pub release_date: String,
    pub nb_tracks: isize,
    pub record_type: String,
    pub label: String,
    pub copyright: String,
    pub genres: Genres,
    pub artist: Artist,
    pub contributors: Option<Vec<Artist>>,
    pub tracks: Tracks,
}
go_deserialize!(FullAlbum {
    "id" => id, "title" => title, "cover" => cover, "cover_medium" => cover_medium,
    "cover_big" => cover_big, "cover_xl" => cover_xl, "release_date" => release_date,
    "nb_tracks" => nb_tracks, "record_type" => record_type, "label" => label,
    "copyright" => copyright, "genres" => genres, "artist" => artist,
    "contributors" => contributors, "tracks" => tracks,
});

#[derive(Clone, Debug, Default)]
pub struct FullArtist {
    pub id: i64,
    pub name: String,
    pub picture: String,
    pub picture_medium: String,
    pub picture_big: String,
    pub picture_xl: String,
    pub nb_fan: isize,
    pub nb_album: isize,
}
go_deserialize!(FullArtist {
    "id" => id, "name" => name, "picture" => picture, "picture_medium" => picture_medium,
    "picture_big" => picture_big, "picture_xl" => picture_xl, "nb_fan" => nb_fan, "nb_album" => nb_album,
});

#[derive(Clone, Debug, Default)]
pub struct Name {
    pub name: String,
}
go_deserialize!(Name { "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct FullPlaylist {
    pub id: i64,
    pub title: String,
    pub picture: String,
    pub picture_medium: String,
    pub picture_big: String,
    pub picture_xl: String,
    pub nb_tracks: isize,
    pub creator: Name,
    pub tracks: Tracks,
}
go_deserialize!(FullPlaylist {
    "id" => id, "title" => title, "picture" => picture, "picture_medium" => picture_medium,
    "picture_big" => picture_big, "picture_xl" => picture_xl, "nb_tracks" => nb_tracks,
    "creator" => creator, "tracks" => tracks,
});

#[derive(Clone, Debug, Default)]
pub struct SearchAlbum {
    pub id: i64,
    pub title: String,
    pub cover: String,
    pub cover_medium: String,
    pub cover_big: String,
    pub cover_xl: String,
    pub nb_tracks: isize,
    pub release_date: String,
    pub record_type: String,
    pub artist: Artist,
}
go_deserialize!(SearchAlbum {
    "id" => id, "title" => title, "cover" => cover, "cover_medium" => cover_medium,
    "cover_big" => cover_big, "cover_xl" => cover_xl, "nb_tracks" => nb_tracks,
    "release_date" => release_date, "record_type" => record_type, "artist" => artist,
});

#[derive(Clone, Debug, Default)]
pub struct ArtistAlbum {
    pub id: i64,
    pub title: String,
    pub release_date: String,
    pub nb_tracks: isize,
    pub cover: String,
    pub cover_medium: String,
    pub cover_big: String,
    pub cover_xl: String,
    pub record_type: String,
}
go_deserialize!(ArtistAlbum {
    "id" => id, "title" => title, "release_date" => release_date, "nb_tracks" => nb_tracks,
    "cover" => cover, "cover_medium" => cover_medium, "cover_big" => cover_big,
    "cover_xl" => cover_xl, "record_type" => record_type,
});

#[derive(Clone, Debug, Default)]
pub struct ArtistAlbums {
    pub data: Option<Vec<ArtistAlbum>>,
}
go_deserialize!(ArtistAlbums { "data" => data, });

#[derive(Clone, Debug, Default)]
pub struct AlbumTrackCount {
    pub nb_tracks: isize,
}
go_deserialize!(AlbumTrackCount { "nb_tracks" => nb_tracks, });

#[derive(Clone, Debug, Default)]
pub struct SearchPlaylist {
    pub id: i64,
    pub title: String,
    pub picture: String,
    pub picture_medium: String,
    pub picture_big: String,
    pub picture_xl: String,
    pub nb_tracks: isize,
    pub user: Name,
}
go_deserialize!(SearchPlaylist {
    "id" => id, "title" => title, "picture" => picture, "picture_medium" => picture_medium,
    "picture_big" => picture_big, "picture_xl" => picture_xl, "nb_tracks" => nb_tracks, "user" => user,
});

macro_rules! cover_image {
    ($($name:ty),*) => {$(
        impl $name {
            pub fn image(&self) -> String {
                best_image([self.cover_xl.as_str(), &self.cover_big, &self.cover_medium, &self.cover])
            }
        }
    )*};
}
cover_image!(FullAlbum, SearchAlbum, ArtistAlbum);

impl FullArtist {
    pub fn image(&self) -> String {
        best_image([
            self.picture_xl.as_str(),
            &self.picture_big,
            &self.picture_medium,
            &self.picture,
        ])
    }
}

impl SearchPlaylist {
    pub fn image(&self) -> String {
        best_image([
            self.picture_xl.as_str(),
            &self.picture_big,
            &self.picture_medium,
            &self.picture,
        ])
    }
}
