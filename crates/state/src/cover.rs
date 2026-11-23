use std::collections::HashMap;
use std::sync::Arc;

use gpui::{Context, Entity, Task};
use music::{CoverSize, MusicApi};

use crate::{Io, Playback, Session, SessionEvent, join};

/// The artwork of one album or recovered track: the large cover, and the full-resolution one
/// when the provider serves something bigger.
#[derive(Clone)]
struct Art {
    large: String,
    full: Option<String>,
}

pub struct Cover {
    session: Entity<Session>,
    playback: Entity<Playback>,
    album: Option<String>,
    track_key: Option<String>,
    large: Option<String>,
    full: Option<String>,
    cache: HashMap<String, Art>,
    io: Io,
    task: Option<Task<()>>,
}

impl Cover {
    pub fn new(
        session: Entity<Session>,
        playback: Entity<Playback>,
        io: Io,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.observe(&playback, |this, _, cx| this.follow(cx))
            .detach();
        cx.subscribe(&session, |this, _, event, cx| match event {
            SessionEvent::SignedOut => this.forget(cx),
            SessionEvent::SignedIn
            | SessionEvent::Reconnected
            | SessionEvent::WentOffline
            | SessionEvent::LocalChanged => {}
        })
        .detach();

        Self {
            session,
            playback,
            album: None,
            track_key: None,
            large: None,
            full: None,
            cache: HashMap::new(),
            io,
            task: None,
        }
    }

    pub fn large(&self) -> Option<&str> {
        self.large.as_deref()
    }

    /// Returns the large artwork only when it belongs to `album`.
    pub fn large_for(&self, album: &str) -> Option<&str> {
        self.large
            .as_deref()
            .filter(|_| self.album.as_deref() == Some(album))
    }

    /// The full-resolution artwork for a cover that fills the screen, only when it belongs to
    /// `album` and the provider serves something bigger than the large one.
    pub fn full_for(&self, album: &str) -> Option<&str> {
        self.full
            .as_deref()
            .filter(|_| self.album.as_deref() == Some(album))
    }

    fn forget(&mut self, cx: &mut Context<Self>) {
        self.task = None;
        self.album = None;
        self.track_key = None;
        self.large = None;
        self.full = None;
        self.cache.clear();
        cx.notify();
    }

    /// Follows the shown track's album. Both covers come straight from the track's thumbnail
    /// when it is a genuine album cover the provider can scale; otherwise the album is loaded
    /// from the provider or recovered from public catalogues.
    fn follow(&mut self, cx: &mut Context<Self>) {
        let shown = self.playback.read(cx).shown_track(cx);
        let (album, track_key, thumbnail) = match &shown {
            Some(track) => (
                track.album_id.clone(),
                Some(cache_key(track)),
                track.cover.clone(),
            ),
            None => (None, None, None),
        };
        if album == self.album && track_key == self.track_key {
            return;
        }
        self.task = None;
        self.album = album.clone();
        self.track_key = track_key.clone();

        let key = album.as_ref().or(track_key.as_ref());
        let cached = key.and_then(|id| self.cache.get(id)).cloned();
        let usable_thumb = thumbnail
            .as_deref()
            .filter(|url| !music::artwork::is_video_or_artist_image(url));
        let client = album
            .as_deref()
            .and_then(|id| self.client(id, cx))
            .or_else(|| self.session.read(cx).client());
        let derive = |size| client.as_ref()?.cover_at(usable_thumb?, size);

        self.large = cached
            .as_ref()
            .map(|art| art.large.clone())
            .or_else(|| derive(CoverSize::Large));
        self.full = cached
            .and_then(|art| art.full)
            .or_else(|| derive(CoverSize::Full));
        cx.notify();

        if self.large.is_some() {
            return;
        }

        if let Some(id) = album {
            self.load(id, shown, cx);
        } else if let Some(track) = shown {
            self.recover(track, cx);
        }
    }

    /// Recovers a missing or video-frame cover by searching public catalogues (Apple Music and
    /// Deezer) for the official album artwork.
    fn recover(&mut self, track: music::Track, cx: &mut Context<Self>) {
        let Some(query) = music::artwork::ArtworkQuery::for_track(&track) else {
            return;
        };
        let key = track.album_id.clone().unwrap_or_else(|| cache_key(&track));
        let expected_track = Some(cache_key(&track));
        let io = self.io.clone();
        self.task = Some(cx.spawn(async move |this, cx| {
            let search = music::artwork::ArtworkSearch::new();
            let found = join(io.spawn(async move { search.find(&query).await })).await;
            this.update(cx, |this, cx| {
                this.task = None;
                if let Ok(Some(url)) = found {
                    this.cache.insert(
                        key,
                        Art {
                            large: url.clone(),
                            full: Some(url.clone()),
                        },
                    );
                    if this.track_key == expected_track {
                        this.large = Some(url.clone());
                        this.full = Some(url);
                        cx.notify();
                    }
                }
            })
            .ok();
        }));
    }

    fn load(&mut self, id: String, fallback: Option<music::Track>, cx: &mut Context<Self>) {
        let Some(client) = self.client(&id, cx) else {
            if let Some(track) = fallback {
                self.recover(track, cx);
            }
            return;
        };

        let io = self.io.clone();
        let wanted = id.clone();
        self.task = Some(cx.spawn(async move |this, cx| {
            let found = join(io.spawn(async move {
                let album = client.album(&wanted).await?.album;
                let large = album
                    .cover_large
                    .or(album.cover)
                    .filter(|url| !music::artwork::is_video_or_artist_image(url));
                let full = large
                    .as_deref()
                    .and_then(|cover| client.cover_at(cover, CoverSize::Full));
                anyhow::Ok(large.map(|large| Art { large, full }))
            }))
            .await;

            this.update(cx, |this, cx| {
                this.task = None;
                match found {
                    Ok(Some(art)) => {
                        this.cache.insert(id.clone(), art.clone());
                        if this.album.as_deref() == Some(id.as_str()) {
                            this.large = Some(art.large);
                            let kept = this.full.take();
                            this.full = art.full.or(kept);
                            cx.notify();
                        }
                    }
                    Ok(None) => {
                        if this.album.as_deref() == Some(id.as_str())
                            && let Some(track) = fallback
                        {
                            this.recover(track, cx);
                        }
                    }
                    Err(error) => {
                        log::warn!("cover: cannot load {id}: {error:#}");
                        crate::noted(&error, cx);
                        if this.album.as_deref() == Some(id.as_str())
                            && let Some(track) = fallback
                        {
                            this.recover(track, cx);
                        }
                    }
                }
            })
            .ok();
        }));
    }

    /// The client that serves album `id`: the local library for a local id, the signed-in
    /// provider otherwise.
    fn client(&self, id: &str, cx: &Context<Self>) -> Option<Arc<dyn MusicApi>> {
        let session = self.session.read(cx);
        match music::is_local_id(id) {
            true => session.local_client(),
            false => session.client(),
        }
    }
}

fn cache_key(track: &music::Track) -> String {
    track
        .id
        .clone()
        .unwrap_or_else(|| format!("{}::{}", track.artists, track.name))
}
