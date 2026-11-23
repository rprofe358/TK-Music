use anyhow::{Context as _, Result};
use serde::Deserialize;
use serde::de::DeserializeOwned;

use crate::{Album, Track};

const ITUNES_SEARCH: &str = "https://itunes.apple.com/search";
const DEEZER_ALBUMS: &str = "https://api.deezer.com/search/album";
const DEEZER_TRACKS: &str = "https://api.deezer.com/search/track";
const RESULTS: &str = "10";

/// Finds official square album artwork across public catalogues (Apple Music / iTunes and Deezer)
/// without needing an account. Used when a provider only gives a video frame, an artist portrait,
/// or no cover at all. A miss is `None` rather than a wrong cover.
#[derive(Clone, Default)]
pub struct ArtworkSearch {
    http: reqwest::Client,
}

/// What a lookup searches for. When an album is present, album search runs first and falls back to
/// track search if the album name differs across platforms.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ArtworkQuery {
    artist: String,
    album: String,
    title: String,
}

#[derive(Deserialize)]
struct ItunesResponse {
    #[serde(default)]
    results: Vec<ItunesItem>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItunesItem {
    #[serde(default)]
    artist_name: String,
    #[serde(default)]
    collection_name: String,
    #[serde(default)]
    track_name: String,
    artwork_url100: Option<String>,
}

#[derive(Deserialize)]
struct DeezerPage<T> {
    #[serde(default = "Vec::new")]
    data: Vec<T>,
    error: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct FoundAlbum {
    title: String,
    artist: Named,
    cover_xl: Option<String>,
}

#[derive(Deserialize)]
struct FoundTrack {
    title: String,
    artist: Named,
    album: Covered,
}

#[derive(Deserialize)]
struct Named {
    name: String,
}

#[derive(Deserialize)]
struct Covered {
    cover_xl: Option<String>,
}

/// Whether `url` is a video frame, wide banner, or artist portrait rather than a square album
/// cover.
pub fn is_video_or_artist_image(url: &str) -> bool {
    if url.contains("ytimg.com/") || url.contains("dzcdn.net/images/artist/") {
        return true;
    }
    if url.contains(".googleusercontent.com/")
        && let Some((_, options)) = url.rsplit_once('=')
    {
        let size = |prefix: char| {
            options
                .split('-')
                .find_map(|option| option.strip_prefix(prefix)?.parse::<u32>().ok())
        };
        if let (Some(width), Some(height)) = (size('w'), size('h'))
            && width > 0
            && height > 0
            && width * 10 > height * 13
        {
            return true;
        }
    }
    false
}

/// Whether `found` and `wanted` name the same artist (ignoring case, accents, and featured
/// collaborators).
pub fn same_artist(found: &str, wanted: &str) -> bool {
    let found_primary = primary_artist(found);
    let wanted_primary = primary_artist(wanted);
    let found = compared(found_primary);
    let wanted = compared(wanted_primary);
    !found.is_empty() && !wanted.is_empty() && (found == wanted || extends(&found, &wanted))
}

/// Whether `found` and `wanted` name the same song or album title.
pub fn same_title(found: &str, wanted: &str) -> bool {
    let found = compared(&searchable(found));
    let wanted = compared(&searchable(wanted));
    !found.is_empty() && !wanted.is_empty() && (found == wanted || extends(&found, &wanted))
}

impl ArtworkQuery {
    /// Builds a query from raw artist, album, and title strings, or `None` when there is no artist
    /// or nothing else to search by.
    pub fn new(artist: &str, album: &str, title: &str) -> Option<Self> {
        let artist = searchable(primary_artist(artist));
        let album = searchable(album);
        let title = searchable(title);
        if artist.is_empty() || (album.is_empty() && title.is_empty()) {
            return None;
        }
        Some(Self {
            artist,
            album,
            title,
        })
    }

    /// The query for `track`, or `None` when it has no artist or nothing else to search by.
    pub fn for_track(track: &Track) -> Option<Self> {
        let artist = track
            .artist_refs
            .first()
            .map(|artist| artist.name.as_str())
            .or_else(|| track.artists.split(", ").next())
            .unwrap_or_default();
        Self::new(artist, &track.album, &track.name)
    }

    /// The query for `album`, or `None` when it has no artist or name.
    pub fn for_album(album: &Album) -> Option<Self> {
        let artist = album
            .artist_refs
            .first()
            .map(|artist| artist.name.as_str())
            .or_else(|| album.artists.split(", ").next())
            .unwrap_or_default();
        Self::new(artist, &album.name, "")
    }
}

impl ArtworkSearch {
    pub fn new() -> Self {
        Self::default()
    }

    /// The url of a verified square album cover for `query`, or `None` when no platform returns a
    /// result with the same artist and a close enough album or title to trust.
    pub async fn find(&self, query: &ArtworkQuery) -> Result<Option<String>> {
        if let Ok(Some(url)) = self.find_itunes(query).await {
            return Ok(Some(url));
        }
        self.find_deezer(query).await
    }

    async fn find_itunes(&self, query: &ArtworkQuery) -> Result<Option<String>> {
        if !query.album.is_empty() {
            let items = self.search_itunes("album", &query.album, query).await?;
            let candidates = items
                .into_iter()
                .filter(|item| same_artist(&item.artist_name, &query.artist))
                .map(|item| (item.collection_name, item.artwork_url100.map(itunes_large)));
            if let Some(cover) = closest(candidates, &query.album) {
                return Ok(Some(cover));
            }
        }
        if !query.title.is_empty() {
            let items = self.search_itunes("song", &query.title, query).await?;
            let candidates = items
                .into_iter()
                .filter(|item| same_artist(&item.artist_name, &query.artist))
                .map(|item| (item.track_name, item.artwork_url100.map(itunes_large)));
            if let Some(cover) = closest(candidates, &query.title) {
                return Ok(Some(cover));
            }
        }
        Ok(None)
    }

    async fn search_itunes(
        &self,
        entity: &str,
        name: &str,
        query: &ArtworkQuery,
    ) -> Result<Vec<ItunesItem>> {
        let terms = format!("{} {name}", query.artist);
        let response = self
            .http
            .get(ITUNES_SEARCH)
            .query(&[
                ("term", terms.as_str()),
                ("media", "music"),
                ("entity", entity),
                ("limit", RESULTS),
            ])
            .send()
            .await
            .context("cannot reach itunes")?;
        let status = response.status();
        if !status.is_success() {
            anyhow::bail!("itunes answered with status {status}");
        }
        let body: ItunesResponse = response
            .json()
            .await
            .context("cannot read the itunes search")?;
        Ok(body.results)
    }

    async fn find_deezer(&self, query: &ArtworkQuery) -> Result<Option<String>> {
        if !query.album.is_empty() {
            let found: Vec<FoundAlbum> = self
                .search_deezer(DEEZER_ALBUMS, &query.album, query)
                .await?;
            let candidates = found
                .into_iter()
                .filter(|album| same_artist(&album.artist.name, &query.artist))
                .map(|album| (album.title, album.cover_xl));
            if let Some(cover) = closest(candidates, &query.album) {
                return Ok(Some(cover));
            }
        }
        if !query.title.is_empty() {
            let found: Vec<FoundTrack> = self
                .search_deezer(DEEZER_TRACKS, &query.title, query)
                .await?;
            let candidates = found
                .into_iter()
                .filter(|track| same_artist(&track.artist.name, &query.artist))
                .map(|track| (track.title, track.album.cover_xl));
            if let Some(cover) = closest(candidates, &query.title) {
                return Ok(Some(cover));
            }
        }
        Ok(None)
    }

    /// One page of results for the artist and `name`. Deezer reports a refused search, such as
    /// one over its rate limit, in the body of a successful response.
    async fn search_deezer<T: DeserializeOwned>(
        &self,
        endpoint: &str,
        name: &str,
        query: &ArtworkQuery,
    ) -> Result<Vec<T>> {
        let terms = format!("{} {name}", query.artist);
        let response = self
            .http
            .get(endpoint)
            .query(&[("q", terms.as_str()), ("limit", RESULTS)])
            .send()
            .await
            .context("cannot reach deezer")?;
        let status = response.status();
        if !status.is_success() {
            anyhow::bail!("deezer answered with status {status}");
        }
        let page: DeezerPage<T> = response
            .json()
            .await
            .context("cannot read the deezer search")?;
        if let Some(error) = page.error {
            anyhow::bail!("deezer refused the search: {error}");
        }
        Ok(page.data)
    }
}

fn itunes_large(url: String) -> String {
    url.replace("100x100bb", "1200x1200bb")
        .replace("100x100-75", "1200x1200-75")
}

/// The cover of the candidate whose name matches `wanted` exactly, or failing that the first one
/// that only adds words to it, as an edition or a feature credit does.
fn closest(
    candidates: impl Iterator<Item = (String, Option<String>)>,
    wanted: &str,
) -> Option<String> {
    let wanted = compared(wanted);
    let mut near = None;
    for (name, cover) in candidates {
        let Some(cover) =
            cover.filter(|cover| cover.starts_with("https://") && !is_video_or_artist_image(cover))
        else {
            continue;
        };
        let name = compared(&searchable(&name));
        if name == wanted {
            return Some(cover);
        }
        if near.is_none() && extends(&name, &wanted) {
            near = Some(cover);
        }
    }
    near
}

/// Whether one of two compared names is the other with whole words added after it.
fn extends(one: &str, other: &str) -> bool {
    let starts = |long: &str, short: &str| {
        !short.is_empty()
            && long
                .strip_prefix(short)
                .is_some_and(|rest| rest.starts_with(' '))
    };
    starts(one, other) || starts(other, one)
}

/// The lead artist before any collaboration separator, so `"Artist A, Artist B"` or
/// `"Artist A feat. B"` still matches `"Artist A"`.
fn primary_artist(text: &str) -> &str {
    let mut out = text.trim();
    for sep in [
        ", ",
        " & ",
        " feat. ",
        " ft. ",
        " Feat. ",
        " Ft. ",
        " featuring ",
    ] {
        if let Some((head, _)) = out.split_once(sep) {
            out = head.trim();
        }
    }
    out
}

/// `text` without anything in brackets or release suffixes like `- Single` / `- EP`, since
/// catalogues want the core release name.
fn searchable(text: &str) -> String {
    let mut kept = String::with_capacity(text.len());
    let mut depth = 0usize;
    for character in text.chars() {
        match character {
            '(' | '[' => depth += 1,
            ')' | ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => kept.push(character),
            _ => {}
        }
    }
    let mut cleaned = kept.split_whitespace().collect::<Vec<_>>().join(" ");
    for suffix in [" - Single", " - EP", " - single", " - ep"] {
        if let Some(stripped) = cleaned.strip_suffix(suffix) {
            cleaned = stripped.trim().to_owned();
        }
    }
    cleaned
}

/// `text` lowercased with common Latin diacritics folded and every run of punctuation and spaces
/// turned into one space.
fn compared(text: &str) -> String {
    let folded: String = text.chars().map(fold_char).collect();
    folded
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

fn fold_char(c: char) -> char {
    match c {
        'á' | 'à' | 'ä' | 'â' | 'ã' | 'å' | 'Á' | 'À' | 'Ä' | 'Â' | 'Ã' | 'Å' => 'a',
        'é' | 'è' | 'ë' | 'ê' | 'É' | 'È' | 'Ë' | 'Ê' => 'e',
        'í' | 'ì' | 'ï' | 'î' | 'Í' | 'Ì' | 'Ï' | 'Î' => 'i',
        'ó' | 'ò' | 'ö' | 'ô' | 'õ' | 'Ó' | 'Ò' | 'Ö' | 'Ô' | 'Õ' => 'o',
        'ú' | 'ù' | 'ü' | 'û' | 'Ú' | 'Ù' | 'Ü' | 'Û' => 'u',
        'ñ' | 'Ñ' => 'n',
        'ç' | 'Ç' => 'c',
        _ => c,
    }
}
