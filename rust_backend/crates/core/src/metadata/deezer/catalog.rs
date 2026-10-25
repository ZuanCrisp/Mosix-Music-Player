use super::{Artist, Track, Tracks, best_image};
use crate::json::lenient_deserialize;

#[derive(Clone, Debug, Default)]
pub struct TrackPage {
    pub data: Option<Vec<Track>>,
    pub next: String,
}
lenient_deserialize!(TrackPage { "data" => data, "next" => next, });

#[derive(Clone, Debug, Default)]
pub struct Genre {
    pub id: isize,
    pub name: String,
}
lenient_deserialize!(Genre { "id" => id, "name" => name, });

#[derive(Clone, Debug, Default)]
pub struct Genres {
    pub data: Option<Vec<Genre>>,
}
lenient_deserialize!(Genres { "data" => data, });

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
lenient_deserialize!(FullAlbum {
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
lenient_deserialize!(FullArtist {
    "id" => id, "name" => name, "picture" => picture, "picture_medium" => picture_medium,
    "picture_big" => picture_big, "picture_xl" => picture_xl, "nb_fan" => nb_fan, "nb_album" => nb_album,
});

#[derive(Clone, Debug, Default)]
pub struct Name {
    pub name: String,
}
lenient_deserialize!(Name { "name" => name, });

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
lenient_deserialize!(FullPlaylist {
    "id" => id, "title" => title, "picture" => picture, "picture_medium" => picture_medium,
    "picture_big" => picture_big, "picture_xl" => picture_xl, "nb_tracks" => nb_tracks,
    "creator" => creator, "tracks" => tracks,
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
lenient_deserialize!(ArtistAlbum {
    "id" => id, "title" => title, "release_date" => release_date, "nb_tracks" => nb_tracks,
    "cover" => cover, "cover_medium" => cover_medium, "cover_big" => cover_big,
    "cover_xl" => cover_xl, "record_type" => record_type,
});

#[derive(Clone, Debug, Default)]
pub struct ArtistAlbums {
    pub data: Option<Vec<ArtistAlbum>>,
}
lenient_deserialize!(ArtistAlbums { "data" => data, });

#[derive(Clone, Debug, Default)]
pub struct AlbumTrackCount {
    pub nb_tracks: isize,
}
lenient_deserialize!(AlbumTrackCount { "nb_tracks" => nb_tracks, });

macro_rules! cover_image {
    ($($name:ty),*) => {$(
        impl $name {
            pub fn image(&self) -> String {
                best_image([self.cover_xl.as_str(), &self.cover_big, &self.cover_medium, &self.cover])
            }
        }
    )*};
}
cover_image!(FullAlbum, ArtistAlbum);

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
