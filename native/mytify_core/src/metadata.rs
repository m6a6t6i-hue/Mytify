//! Non-destructive metadata edits and opt-in MusicBrainz / CAA lookup.
use crate::catalog::{hex, search_key, Catalog, Track};
use anyhow::{anyhow, bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Cursor, Read},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use url::Url;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Edit {
    pub id: String,
    pub patch: Value,
}

fn validate_patch(patch: &Value) -> Result<()> {
    let fields = patch
        .as_object()
        .ok_or_else(|| anyhow!("Nieprawidłowe poprawki."))?;
    for (key, value) in fields {
        match key.as_str() {
            "title" | "artist" | "album" | "albumArtist" => {
                let text = value
                    .as_str()
                    .ok_or_else(|| anyhow!("Pole {key} musi być tekstem."))?;
                if text.chars().count() > 500 || text.contains('\0') {
                    bail!("Pole {key} jest za długie lub nieprawidłowe.");
                }
                if key == "title" && text.trim().is_empty() {
                    bail!("Tytuł nie może być pusty.");
                }
            }
            "trackNumber" | "discNumber" => {
                if value.as_u64().is_none_or(|v| v > 9999) {
                    bail!("Numer utworu/płyty musi być od 0 do 9999.");
                }
            }
            "cover" => {
                let s = value
                    .as_str()
                    .ok_or_else(|| anyhow!("Nieprawidłowa okładka."))?;
                if !s.is_empty() && !hash_id(s) {
                    bail!("Okładka musi pochodzić z lokalnego katalogu.");
                }
            }
            "releaseId" => {
                if !value.as_str().is_some_and(valid_mbid) {
                    bail!("Nieprawidłowy identyfikator wydania.");
                }
            }
            "source" => {
                if !matches!(value.as_str(), Some("manual" | "MusicBrainz")) {
                    bail!("Nieprawidłowe źródło metadanych.");
                }
            }
            _ => bail!("Nieobsługiwane pole: {key}"),
        }
    }
    Ok(())
}
fn hash_id(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit())
}
pub fn valid_mbid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
pub(crate) fn overlay(track: &mut Track, patch: &Value) -> Result<()> {
    validate_patch(patch)?;
    if let Some(v) = patch["title"].as_str() {
        track.title = v.trim().into();
    }
    if let Some(v) = patch["artist"].as_str() {
        track.artist = v.trim().into();
    }
    if let Some(v) = patch["album"].as_str() {
        track.album = v.trim().into();
    }
    if let Some(v) = patch["albumArtist"].as_str() {
        track.album_artist = v.trim().into();
    }
    if let Some(v) = patch["trackNumber"].as_u64() {
        track.track_number = v as u32;
    }
    if let Some(v) = patch["discNumber"].as_u64() {
        track.disc_number = v as u32;
    }
    if let Some(v) = patch["cover"].as_str() {
        track.cover = if v.is_empty() { None } else { Some(v.into()) };
    }
    track.edited = true;
    track.metadata_source = patch["source"].as_str().unwrap_or("manual").into();
    track.release_id = patch["releaseId"].as_str().map(str::to_string);
    Ok(())
}
pub(crate) fn reindex(db: &Connection, id: &str) -> Result<()> {
    let (title, artist, album, album_artist, name): (String, String, String, String, String) = db
        .query_row(
        "SELECT title,artist,album,album_artist,file_name FROM tracks WHERE id=?",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
    )?;
    let patch: Option<String> = db
        .query_row(
            "SELECT patch FROM metadata_overrides WHERE track_id=?",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    let patch: Value = patch
        .map(|p| serde_json::from_str(&p))
        .transpose()?
        .unwrap_or_else(|| json!({}));
    let text = format!(
        "{} {} {} {} {}",
        patch["title"].as_str().unwrap_or(&title),
        patch["artist"].as_str().unwrap_or(&artist),
        patch["album"].as_str().unwrap_or(&album),
        patch["albumArtist"].as_str().unwrap_or(&album_artist),
        name
    );
    db.execute("DELETE FROM tracks_search WHERE track_id=?", [id])?;
    db.execute(
        "INSERT INTO tracks_search(track_id,text) VALUES(?1,?2)",
        params![id, search_key(&text)],
    )?;
    Ok(())
}
impl Catalog {
    pub fn edit_metadata(&self, edits: Vec<Edit>) -> Result<()> {
        if edits.is_empty() || edits.len() > 500 {
            bail!("Wybierz od 1 do 500 utworów.");
        }
        let mut ids = std::collections::HashSet::new();
        for edit in &edits {
            if !hash_id(&edit.id) || !ids.insert(&edit.id) {
                bail!("Nieprawidłowy lub powtórzony utwór.");
            }
            validate_patch(&edit.patch)?;
            if let Some(cover) = edit.patch["cover"].as_str().filter(|c| !c.is_empty()) {
                self.artwork_path(cover)?;
            }
        }
        let mut db = self.db()?;
        let tx = db.transaction()?;
        for edit in edits {
            let exists: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM tracks WHERE id=?)",
                [&edit.id],
                |r| r.get(0),
            )?;
            if !exists {
                bail!("Nie znaleziono utworu. Odśwież bibliotekę.");
            }
            let old: Option<String> = tx
                .query_row(
                    "SELECT patch FROM metadata_overrides WHERE track_id=?",
                    [&edit.id],
                    |r| r.get(0),
                )
                .optional()?;
            let mut patch: Map<String, Value> = old
                .map(|p| serde_json::from_str(&p))
                .transpose()?
                .unwrap_or_default();
            for (key, value) in edit.patch.as_object().unwrap() {
                patch.insert(key.clone(), value.clone());
            }
            tx.execute("INSERT INTO metadata_overrides(track_id,patch) VALUES(?1,?2) ON CONFLICT(track_id) DO UPDATE SET patch=excluded.patch",params![edit.id,serde_json::to_string(&patch)?])?;
            reindex(&tx, &edit.id)?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn reset_metadata(&self, ids: &[String]) -> Result<()> {
        if ids.is_empty() || ids.len() > 500 || ids.iter().any(|id| !hash_id(id)) {
            bail!("Nieprawidłowy wybór utworów.");
        }
        let mut db = self.db()?;
        let tx = db.transaction()?;
        for id in ids {
            tx.execute("DELETE FROM metadata_overrides WHERE track_id=?", [id])?;
            reindex(&tx, id)?;
        }
        tx.commit()?;
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseSummary {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub date: String,
    pub country: String,
    pub format: String,
    pub label: String,
    pub barcode: String,
    pub disambiguation: String,
    pub track_count: u64,
    pub score: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseTrack {
    pub title: String,
    pub artist: String,
    pub disc_number: u64,
    pub track_number: u64,
    pub duration_ms: u64,
    /// Printed position, e.g. "A1" on vinyl.
    #[serde(default)]
    pub number: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseDetail {
    pub release: ReleaseSummary,
    pub tracks: Vec<ReleaseTrack>,
}
fn text(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or_default().to_string()
}
fn credit(v: &Value) -> String {
    v.as_array()
        .map(|a| {
            a.iter()
                .map(|a| {
                    format!(
                        "{}{}",
                        a["name"]
                            .as_str()
                            .or_else(|| a["artist"]["name"].as_str())
                            .unwrap_or_default(),
                        a["joinphrase"].as_str().unwrap_or_default()
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}
fn summary(v: &Value) -> ReleaseSummary {
    ReleaseSummary {
        id: text(v, "id"),
        title: text(v, "title"),
        artist: credit(&v["artist-credit"]),
        date: text(v, "date"),
        country: text(v, "country"),
        format: v["media"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|m| m["format"].as_str())
                    .collect::<Vec<_>>()
                    .join(" + ")
            })
            .unwrap_or_default(),
        label: v["label-info"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|m| m["label"]["name"].as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default(),
        barcode: text(v, "barcode"),
        disambiguation: text(v, "disambiguation"),
        track_count: v["track-count"].as_u64().unwrap_or_else(|| {
            v["media"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|m| m["track-count"].as_u64().unwrap_or(0))
                        .sum()
                })
                .unwrap_or(0)
        }),
        score: v["score"]
            .as_u64()
            .or_else(|| v["score"].as_str().and_then(|s| s.parse().ok()))
            .unwrap_or(0),
    }
}
pub fn parse_search(v: &Value) -> Result<Vec<ReleaseSummary>> {
    let releases = v["releases"]
        .as_array()
        .ok_or_else(|| anyhow!("Nieprawidłowa odpowiedź MusicBrainz."))?;
    Ok(releases
        .iter()
        .filter(|r| r["id"].as_str().is_some_and(valid_mbid))
        .take(20)
        .map(summary)
        .collect())
}
pub fn parse_release(v: &Value) -> Result<ReleaseDetail> {
    if !v["id"].as_str().is_some_and(valid_mbid) {
        bail!("Nieprawidłowe wydanie MusicBrainz.");
    }
    let release = summary(v);
    let mut tracks = Vec::new();
    for medium in v["media"]
        .as_array()
        .ok_or_else(|| anyhow!("Wydanie nie zawiera listy płyt."))?
    {
        let disc = medium["position"].as_u64().unwrap_or(0);
        for track in medium["tracks"].as_array().into_iter().flatten() {
            let artist = credit(&track["artist-credit"]);
            let artist = if artist.is_empty() {
                credit(&track["recording"]["artist-credit"])
            } else {
                artist
            };
            tracks.push(ReleaseTrack {
                title: track["title"]
                    .as_str()
                    .or_else(|| track["recording"]["title"].as_str())
                    .unwrap_or_default()
                    .into(),
                artist: if artist.is_empty() {
                    release.artist.clone()
                } else {
                    artist
                },
                disc_number: disc,
                number: text(track, "number"),
                track_number: track["position"].as_u64().unwrap_or(0),
                duration_ms: track["length"]
                    .as_u64()
                    .or_else(|| track["recording"]["length"].as_u64())
                    .unwrap_or(0),
            });
            if tracks.len() > 500 {
                bail!("Wydanie ma ponad 500 utworów. Wybierz mniejsze wydanie.");
            }
        }
    }
    Ok(ReleaseDetail { release, tracks })
}
fn discogs_name(s: &str) -> String {
    // "Artist (2)" is Discogs' way of telling namesakes apart.
    let s = s.trim().trim_end_matches('*');
    match s.rfind(" (") {
        Some(i) if s.ends_with(')') && s[i + 2..s.len() - 1].bytes().all(|b| b.is_ascii_digit()) => s[..i].to_string(),
        _ => s.to_string(),
    }
}
fn discogs_artists(v: &Value) -> String {
    v.as_array()
        .map(|a| {
            a.iter()
                .map(|x| {
                    let join = x["join"].as_str().unwrap_or("");
                    let join = if join.is_empty() || join == "," { if join == "," { ", ".into() } else { String::new() } } else { format!(" {join} ") };
                    format!("{}{}", discogs_name(x["name"].as_str().unwrap_or("")), join)
                })
                .collect::<String>()
                .trim()
                .trim_end_matches(',')
                .to_string()
        })
        .unwrap_or_default()
}
pub fn parse_discogs(v: &Value) -> Result<ReleaseDetail> {
    let id = v["id"].as_u64().ok_or_else(|| anyhow!("Nieprawidłowa odpowiedź Discogs."))?;
    let artist = discogs_artists(&v["artists"]);
    let mut tracks = Vec::new();
    for t in v["tracklist"].as_array().into_iter().flatten() {
        if t["type_"].as_str().unwrap_or("track") != "track" {
            continue;
        }
        let duration_ms = t["duration"]
            .as_str()
            .and_then(|d| {
                let p: Vec<u64> = d.split(':').filter_map(|x| x.trim().parse().ok()).collect();
                match p.as_slice() {
                    [m, s] => Some((m * 60 + s) * 1000),
                    [h, m, s] => Some((h * 3600 + m * 60 + s) * 1000),
                    _ => None,
                }
            })
            .unwrap_or(0);
        let a = discogs_artists(&t["artists"]);
        tracks.push(ReleaseTrack {
            title: text(t, "title"),
            artist: if a.is_empty() { artist.clone() } else { a },
            disc_number: 1,
            track_number: tracks.len() as u64 + 1,
            duration_ms,
            number: text(t, "position"),
        });
        if tracks.len() > 500 {
            bail!("Wydanie ma ponad 500 utworów.");
        }
    }
    let release = ReleaseSummary {
        id: format!("discogs:{id}"),
        title: text(v, "title"),
        artist,
        date: v["released"].as_str().map(str::to_string).or_else(|| v["year"].as_u64().map(|y| y.to_string())).unwrap_or_default(),
        country: text(v, "country"),
        format: v["formats"][0]["name"].as_str().unwrap_or("").into(),
        label: v["labels"][0]["name"].as_str().map(discogs_name).unwrap_or_default(),
        barcode: String::new(),
        disambiguation: String::new(),
        track_count: tracks.len() as u64,
        score: 100,
    };
    Ok(ReleaseDetail { release, tracks })
}
fn phrase(s: &str) -> Result<String> {
    let s = s.trim();
    if s.chars().count() > 200 || s.contains('\0') {
        bail!("Wyszukiwana nazwa jest za długa.");
    }
    Ok(format!(
        "\"{}\"",
        s.replace('\\', "\\\\").replace('"', "\\\"")
    ))
}
fn permitted(url: &Url, art: bool) -> bool {
    let host = url.host_str().unwrap_or_default();
    url.scheme() == "https"
        && url.port_or_known_default() == Some(443)
        && url.username().is_empty()
        && url.password().is_none()
        && if art {
            host == "coverartarchive.org" || host == "archive.org" || host.ends_with(".archive.org")
        } else {
            host == "musicbrainz.org" || host == "api.discogs.com"
        }
}

struct Reply {
    status: u16,
    location: Option<String>,
    bytes: Vec<u8>,
}
trait Transport: Send + Sync {
    fn get(&self, url: &Url, limit: usize) -> Result<Reply>;
}
struct HttpsTransport {
    client: reqwest::blocking::Client,
}
impl Transport for HttpsTransport {
    fn get(&self, url: &Url, limit: usize) -> Result<Reply> {
        let response = self
            .client
            .get(url.clone())
            .header("Accept", "application/json, image/jpeg, image/png")
            .send()
            .context("Nie można połączyć się z serwisem. Sprawdź internet i spróbuj ponownie.")?;
        let status = response.status().as_u16();
        let location = response
            .headers()
            .get("Location")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        if response
            .content_length()
            .is_some_and(|size| size > limit as u64)
        {
            bail!("Odpowiedź serwisu jest za duża.");
        }
        let mut bytes = Vec::new();
        response.take(limit as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > limit {
            bail!("Odpowiedź serwisu jest za duża.");
        }
        Ok(Reply {
            status,
            location,
            bytes,
        })
    }
}
pub struct MetadataService {
    root: PathBuf,
    transport: Mutex<Option<Arc<dyn Transport>>>,
    gate: Mutex<Option<Instant>>,
}
impl MetadataService {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            transport: Mutex::new(None),
            gate: Mutex::new(None),
        }
    }
    fn transport(&self) -> Result<Arc<dyn Transport>> {
        let mut transport = self
            .transport
            .lock()
            .map_err(|_| anyhow!("Serwis metadanych jest zajęty."))?;
        if transport.is_none() {
            let client = reqwest::blocking::Client::builder()
                .connect_timeout(Duration::from_secs(8))
                .timeout(Duration::from_secs(22))
                .user_agent("Mytify/0.4.0 (local music library; personal development build)")
                .redirect(reqwest::redirect::Policy::none())
                .build()?;
            *transport = Some(Arc::new(HttpsTransport { client }));
        }
        Ok(transport.as_ref().unwrap().clone())
    }
    fn fetch(&self, mut url: Url, art: bool, limit: usize) -> Result<Option<Vec<u8>>> {
        let mut gate = self
            .gate
            .lock()
            .map_err(|_| anyhow!("Serwis metadanych jest zajęty."))?;
        let transport = self.transport()?;
        for _ in 0..6 {
            if !permitted(&url, art) {
                bail!("Serwis zwrócił niedozwolony adres.");
            }
            if let Some(last) = *gate {
                if let Some(wait) = Duration::from_millis(1100).checked_sub(last.elapsed()) {
                    std::thread::sleep(wait);
                }
            }
            *gate = Some(Instant::now());
            let r = transport.get(&url, limit)?;
            if [301, 302, 303, 307, 308].contains(&r.status) {
                url = url.join(
                    r.location
                        .as_deref()
                        .ok_or_else(|| anyhow!("Brak adresu przekierowania."))?,
                )?;
                if art && url.scheme() == "http" {
                    let _ = url.set_scheme("https");
                    if url.port() == Some(80) {
                        let _ = url.set_port(None);
                    }
                }
                continue;
            }
            if r.status == 404 && art {
                return Ok(None);
            }
            if r.status == 429 || r.status == 503 {
                bail!("Serwis jest chwilowo zajęty. Spróbuj ponownie za minutę.");
            }
            if !(200..300).contains(&r.status) {
                bail!(
                    "Serwis zwrócił błąd HTTP {}. Spróbuj ponownie później.",
                    r.status
                );
            }
            return Ok(Some(r.bytes));
        }
        bail!("Zbyt wiele przekierowań serwisu.")
    }
    fn cached_json(&self, url: Url, ttl: u64) -> Result<Value> {
        let key = hex(Sha256::digest(url.as_str().as_bytes()));
        let dir = self.root.join("metadata-cache");
        let path = dir.join(key);
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        if let Ok(data) = fs::read(&path) {
            if let Ok(v) = serde_json::from_slice::<Value>(&data) {
                if v["expires"].as_u64().unwrap_or(0) > now {
                    return Ok(v["value"].clone());
                }
            }
        }
        let bytes = self
            .fetch(url, false, 2 * 1024 * 1024)?
            .ok_or_else(|| anyhow!("Brak danych wydania."))?;
        let value: Value =
            serde_json::from_slice(&bytes).context("Nieprawidłowa odpowiedź MusicBrainz.")?;
        fs::create_dir_all(dir)?;
        let temporary = path.with_extension("partial");
        fs::write(
            &temporary,
            serde_json::to_vec(&json!({"expires":now+ttl,"value":value}))?,
        )?;
        if path.exists() {
            fs::remove_file(&path)?;
        }
        fs::rename(temporary, path)?;
        Ok(value)
    }
    pub fn disc(&self, id: &str) -> Result<Vec<ReleaseSummary>> {
        if id.len() != 28
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            bail!("Nieprawidłowy Disc ID")
        }
        let mut url = Url::parse(&format!("https://musicbrainz.org/ws/2/discid/{id}"))?;
        url.query_pairs_mut()
            .append_pair("inc", "artist-credits+labels")
            .append_pair("fmt", "json");
        parse_search(&self.cached_json(url, 24 * 3600)?)
    }
    pub fn search(&self, album: &str, artist: &str) -> Result<Vec<ReleaseSummary>> {
        if album.trim().is_empty() {
            bail!("Wpisz nazwę albumu.");
        }
        let mut query = format!("release:{}", phrase(album)?);
        if !artist.trim().is_empty() {
            query.push_str(&format!(" AND artist:{}", phrase(artist)?));
        }
        let mut url = Url::parse("https://musicbrainz.org/ws/2/release/")?;
        url.query_pairs_mut()
            .append_pair("query", &query)
            .append_pair("fmt", "json")
            .append_pair("limit", "15");
        parse_search(&self.cached_json(url, 24 * 3600)?)
    }
    pub fn release(&self, id: &str) -> Result<ReleaseDetail> {
        if !valid_mbid(id) {
            bail!("Nieprawidłowy identyfikator wydania.");
        }
        let mut url = Url::parse(&format!("https://musicbrainz.org/ws/2/release/{id}"))?;
        url.query_pairs_mut()
            .append_pair("inc", "recordings+artist-credits+labels")
            .append_pair("fmt", "json");
        let detail = parse_release(&self.cached_json(url, 7 * 24 * 3600)?)?;
        if detail.release.id != id {
            bail!("Odpowiedź dotyczy innego wydania.");
        }
        Ok(detail)
    }
    /// Discogs release by number or page address (tracklist with vinyl sides).
    pub fn discogs(&self, id: &str) -> Result<ReleaseDetail> {
        let t = id.trim();
        let after = t.rfind("release/").map(|i| &t[i + 8..]).unwrap_or(t);
        let digits: String = after.trim_start_matches(['[', 'r']).chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() || digits.len() > 12 {
            bail!("Wklej numer lub adres wydania z Discogs.");
        }
        let url = Url::parse(&format!("https://api.discogs.com/releases/{digits}"))?;
        parse_discogs(&self.cached_json(url, 7 * 24 * 3600)?)
    }
    pub fn cover(&self, id: &str) -> Result<Option<String>> {
        if !valid_mbid(id) {
            bail!("Nieprawidłowy identyfikator wydania.");
        }
        // Route through CAA, including its redirects; no arbitrary URL input.
        let bytes = self.fetch(
            Url::parse(&format!(
                "https://coverartarchive.org/release/{id}/front-500"
            ))?,
            true,
            8 * 1024 * 1024,
        )?;
        bytes.map(|b| self.store_cover(&b)).transpose()
    }
    pub fn store_cover(&self, bytes: &[u8]) -> Result<String> {
        if bytes.len() > 8 * 1024 * 1024 {
            bail!("Okładka jest za duża (maks. 8 MB).");
        }
        let mut reader = image::ImageReader::new(Cursor::new(bytes)).with_guessed_format()?;
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(6000);
        limits.max_image_height = Some(6000);
        limits.max_alloc = Some(96 * 1024 * 1024);
        reader.limits(limits);
        let image = reader
            .decode()
            .context("Okładka nie jest poprawnym obrazem PNG lub JPEG.")?
            .thumbnail(1200, 1200)
            .to_rgb8();
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 90).encode_image(&image)?;
        let hash = hex(Sha256::digest(&bytes));
        let dir = self.root.join("artwork");
        fs::create_dir_all(&dir)?;
        let target = dir.join(&hash);
        if !target.exists() {
            fs::write(&target, &bytes)?;
        }
        Ok(hash)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    const ID: &str = "12345678-1234-1234-1234-123456789abc";
    struct Fake {
        responses: Mutex<VecDeque<Reply>>,
        urls: Mutex<Vec<String>>,
    }
    impl Transport for Fake {
        fn get(&self, url: &Url, _: usize) -> Result<Reply> {
            self.urls.lock().unwrap().push(url.to_string());
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| anyhow!("Unexpected network request"))
        }
    }
    fn setup(responses: Vec<Reply>) -> (tempfile::TempDir, MetadataService, Arc<Fake>) {
        let root = tempfile::tempdir().unwrap();
        let fake = Arc::new(Fake {
            responses: Mutex::new(responses.into()),
            urls: Mutex::new(vec![]),
        });
        let service = MetadataService::new(root.path().into());
        *service.transport.lock().unwrap() = Some(fake.clone());
        (root, service, fake)
    }
    fn reply(status: u16, v: Value) -> Reply {
        Reply {
            status,
            location: None,
            bytes: serde_json::to_vec(&v).unwrap(),
        }
    }
    #[test]
    fn parses_multi_disc_credits_and_positions() {
        let v = json!({"id":ID,"title":"Album","artist-credit":[{"name":"A","joinphrase":" & "},{"artist":{"name":"B"}}],"media":[{"position":1,"tracks":[{"position":2,"recording":{"title":"Drugi","length":1234,"artist-credit":[{"name":"C"}]}}]},{"position":2,"tracks":[{"position":1,"title":"Bonus"}]}]});
        let r = parse_release(&v).unwrap();
        assert_eq!(r.release.artist, "A & B");
        assert_eq!(r.tracks[0].artist, "C");
        assert_eq!(r.tracks[0].track_number, 2);
        assert_eq!(r.tracks[1].disc_number, 2);
        assert_eq!(r.tracks[1].artist, "A & B");
    }
    #[test]
    fn search_cache_avoids_second_network_request_and_escapes_query() {
        let (_root, service, fake) = setup(vec![reply(
            200,
            json!({"releases":[{"id":ID,"title":"Album","score":"90","track-count":3}]}),
        )]);
        assert_eq!(service.search("A\" OR *", "B").unwrap()[0].score, 90);
        service.search("A\" OR *", "B").unwrap();
        let urls = fake.urls.lock().unwrap();
        assert_eq!(urls.len(), 1);
        let u = Url::parse(&urls[0]).unwrap();
        let query = u.query_pairs().find(|p| p.0 == "query").unwrap().1;
        assert_eq!(query, "release:\"A\\\" OR *\" AND artist:\"B\"");
    }
    #[test]
    fn throttling_errors_are_clear_and_not_cached() {
        let (_root, service, fake) = setup(vec![
            reply(503, json!({})),
            reply(200, json!({"releases":[]})),
        ]);
        assert!(service
            .search("Album", "")
            .unwrap_err()
            .to_string()
            .contains("minutę"));
        assert!(service.search("Album", "").unwrap().is_empty());
        assert_eq!(fake.urls.lock().unwrap().len(), 2);
    }
    #[test]
    fn ids_and_redirects_cannot_escape_allowed_https_services() {
        assert!(!valid_mbid("../../etc/passwd"));
        assert!(!permitted(
            &Url::parse("https://musicbrainz.org.evil.example/").unwrap(),
            false
        ));
        assert!(!permitted(
            &Url::parse("https://archive.org.evil.example/").unwrap(),
            true
        ));
        assert!(!permitted(
            &Url::parse("http://archive.org/").unwrap(),
            true
        ));
        let (_root, service, fake) = setup(vec![Reply {
            status: 307,
            location: Some("https://127.0.0.1/private".into()),
            bytes: vec![],
        }]);
        assert!(service.cover(ID).is_err());
        assert_eq!(fake.urls.lock().unwrap().len(), 1);
        assert!(service.release("invalid").is_err());
    }
    #[test]
    fn artwork_redirects_upgrade_https_decode_and_cache_locally() {
        let png = std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/cover.png"),
        )
        .unwrap();
        let (root, service, fake) = setup(vec![
            Reply {
                status: 307,
                location: Some("http://archive.org/download/test/front.jpg".into()),
                bytes: vec![],
            },
            Reply {
                status: 200,
                location: None,
                bytes: png,
            },
        ]);
        let hash = service.cover(ID).unwrap().unwrap();
        let bytes = fs::read(root.path().join("artwork").join(hash)).unwrap();
        assert!(bytes.starts_with(&[0xff, 0xd8]));
        assert!(fake.urls.lock().unwrap()[1].starts_with("https://archive.org/"));
    }
    #[test]
    fn missing_cover_is_optional_and_bad_images_are_rejected() {
        let (_root, service, _) = setup(vec![reply(404, json!({}))]);
        assert_eq!(service.cover(ID).unwrap(), None);
        assert!(service
            .store_cover(b"<svg><script>oops</script></svg>")
            .is_err());
        assert!(service.store_cover(&vec![0; 8 * 1024 * 1024 + 1]).is_err());
    }
    #[test]
    fn malformed_release_and_search_are_rejected() {
        assert!(parse_release(&json!({"id":"bad"})).is_err());
        assert!(parse_search(&json!({"unexpected":[]})).is_err());
    }
    #[test]
    fn discogs_vinyl_tracklist() {
        let v = json!({"id": 249504, "title": "Never Gonna Give You Up", "year": 1987, "country": "UK",
            "artists": [{"name": "Rick Astley", "join": ""}], "formats": [{"name": "Vinyl"}], "labels": [{"name": "RCA (2)"}],
            "tracklist": [
                {"position": "", "type_": "heading", "title": "Side A"},
                {"position": "A", "type_": "track", "title": "Never Gonna Give You Up", "duration": "3:32"},
                {"position": "B", "type_": "track", "title": "Never Gonna Give You Up (Instrumental)", "duration": "3:30",
                 "artists": [{"name": "Stock Aitken Waterman (2)", "join": ""}]}
            ]});
        let d = parse_discogs(&v).unwrap();
        assert_eq!(d.release.id, "discogs:249504");
        assert_eq!(d.release.label, "RCA");
        assert_eq!(d.tracks.len(), 2);
        assert_eq!(d.tracks[0].number, "A");
        assert_eq!(d.tracks[0].duration_ms, 212_000);
        assert_eq!(d.tracks[1].artist, "Stock Aitken Waterman");
    }
}
