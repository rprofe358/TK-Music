//! La portada oficial del álbum para lo que suena cuando el servicio solo dio la miniatura de
//! un video musical (un cuadro del clip o la foto del artista) o ninguna portada.
//!
//! Primero pide el álbum al propio servicio; si sigue sin portada buena, busca la versión
//! «canción» en el servicio exigiendo mismo artista y mismo título; y si tampoco aparece,
//! busca la portada oficial en los catálogos públicos (Apple Music / Deezer).

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use music::artwork::{
    ArtworkQuery, ArtworkSearch, is_video_or_artist_image, same_artist, same_title,
};

use super::{Inner, google_sized, lock};
use crate::runtime;

/// Cuántas respuestas se recuerdan antes de empezar de cero.
const REMEMBERED: usize = 500;

/// La portada hallada para cada canción (`None`: se buscó y no hubo una mejor).
static FOUND: LazyLock<Mutex<HashMap<String, Option<String>>>> = LazyLock::new(Mutex::default);

/// Si lo que suena no trae portada o trae un cuadro de video / foto de artista, busca en
/// segundo plano la portada oficial del álbum y la pone en la cola, para que la muestren el
/// reproductor, la barra y la lista.
pub(super) fn fix(inner: &Arc<Inner>) {
    let (slug, track) = {
        let queue = lock(&inner.queue);
        let (Some(slug), Some(track)) =
            (queue.slug.clone(), queue.tracks.get(queue.index).cloned())
        else {
            return;
        };
        (slug, track)
    };
    let needs_fix = track.cover.as_deref().is_none_or(is_video_or_artist_image);
    if !needs_fix {
        return;
    }
    if let Some(known) = lock(&FOUND).get(&track.id).cloned() {
        if let Some(cover) = known {
            apply(inner, &track.id, cover);
        }
        return;
    }
    let api = inner.api(&slug).ok();
    let this = Arc::downgrade(inner);
    runtime().spawn(async move {
        let mut found: Option<String> = None;

        // 1. Si tiene álbum en el servicio actual, usar la portada real del álbum.
        if let (Some(api), Some(album_id)) = (&api, &track.album_id)
            && let Ok(detail) = api.album(album_id).await
        {
            found = detail
                .album
                .cover_large
                .or(detail.album.cover)
                .filter(|url| !is_video_or_artist_image(url));
        }

        // 2. Buscar la versión «canción» en el mismo servicio exigiendo mismo artista y título.
        if found.is_none()
            && let Some(api) = &api
        {
            let query = format!("{} {}", track.artists, track.title);
            if let Ok(songs) = api.search(&query).await {
                found = album_art(&track.artists, &track.title, &songs);
            }
        }

        // 3. Buscar la portada oficial del álbum en catálogos públicos (Apple Music / Deezer).
        if found.is_none()
            && let Some(query) = ArtworkQuery::new(&track.artists, &track.album, &track.title)
        {
            let search = ArtworkSearch::new();
            if let Ok(Some(url)) = search.find(&query).await {
                found = Some(url);
            }
        }

        {
            let mut memory = lock(&FOUND);
            if memory.len() > REMEMBERED {
                memory.clear();
            }
            memory.insert(track.id.clone(), found.clone());
        }
        if let (Some(cover), Some(inner)) = (found, this.upgrade()) {
            apply(&inner, &track.id, cover);
        }
    });
}

/// La carátula de la primera canción de la búsqueda que pertenece al mismo artista y al mismo
/// tema que el video, descartando fotogramas de video y retratos de artista.
fn album_art(artists: &str, title: &str, songs: &[music::Track]) -> Option<String> {
    songs
        .iter()
        .take(8)
        .filter(|song| {
            song.cover
                .as_deref()
                .is_some_and(|cover| !is_video_or_artist_image(cover))
        })
        .find(|song| same_artist(&song.artists, artists) && same_title(&song.name, title))
        .and_then(|song| song.cover.clone())
}

/// Pone la portada en cada copia de la canción en la cola y avisa a la app.
fn apply(inner: &Inner, id: &str, cover: String) {
    let cover = google_sized(&cover, 600).unwrap_or(cover);
    let changed = {
        let mut queue = lock(&inner.queue);
        let mut changed = false;
        for track in queue.tracks.iter_mut().filter(|track| track.id == id) {
            if track.cover.as_deref() != Some(cover.as_str()) {
                track.cover = Some(cover.clone());
                changed = true;
            }
        }
        changed
    };
    if changed {
        inner.notify();
    }
}
