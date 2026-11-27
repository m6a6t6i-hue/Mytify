//! Artist photos. Read from a photo folder (`Amorphis.jpg` or `Amorphis/artist.jpg`)
//! and from the artist's own folder next to the music (`Music/Amorphis/artist.jpg`,
//! the Plex, Jellyfin and Kodi convention). Missing ones can be downloaded (Deezer,
//! then Wikimedia Commons through MusicBrainz and Wikidata) and are written to the
//! photo folder, or next to the music, so every player on the network sees them.
//! Existing files are never overwritten or deleted.
use crate::catalog::{now_ms, Catalog};
use crate::metadata::MetadataService;
use anyhow::{anyhow, bail, Result};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::{
    collections::{BTreeMap, HashMap},
    io::Read,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};
use url::Url;

/// File names an artist folder may hold its photo under, best first.
const NAMES: [&str; 6] = ["artist.jpg", "artist.jpeg", "artist.png", "folder.jpg", "folder.jpeg", "folder.png"];
const IMAGE: [&str; 4] = ["jpg", "jpeg", "png", "webp"];
const LIMIT: u64 = 8 * 1024 * 1024;
/// A failed lookup is tried again after this long.
const RETRY_MS: i64 = 14 * 24 * 3600 * 1000;

/// Same key as the app's artist grouping: spacing folded, lower case.
pub fn key(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Comparable form of a file or folder name: letters and digits only.
fn loose(name: &str) -> String {
    crate::catalog::search_key(name).chars().filter(|c| c.is_alphanumeric()).collect()
}

/// A file name that is safe on Windows, NAS shares and Android.
pub fn file_name(artist: &str) -> String {
    let cleaned: String = artist
        .chars()
        .map(|c| if "<>:\"/\\|?*".contains(c) || c.is_control() { '_' } else { c })
        .collect();
    let trimmed = cleaned.trim().trim_end_matches(['.', ' ']).to_string();
    let t = if trimmed.is_empty() { "_".to_string() } else { trimmed };
    t.chars().take(120).collect()
}

/// Several artists in one credit ("Amorphis, Hellscore", "A feat. B") have no single photo.
fn collaboration(name: &str) -> bool {
    let l = name.to_lowercase();
    // Compilations have no artist to show either.
    if ["various artists", "różni wykonawcy", "va", "various"].contains(&l.trim()) {
        return true;
    }
    [", ", " feat. ", " feat ", " ft. ", " & ", " x ", " vs. ", " with ", "; ", " / "].iter().any(|s| l.contains(s))
}

#[derive(Debug, Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub running: bool,
    pub done: usize,
    pub total: usize,
    pub found: usize,
    pub downloaded: usize,
    pub step: String,
    pub error: Option<String>,
}

pub struct ArtistPhotos {
    status: Mutex<Status>,
    stop: AtomicBool,
    last_mb: Mutex<Option<Instant>>,
}

impl Default for ArtistPhotos {
    fn default() -> Self {
        Self::new()
    }
}

fn ensure(db: &rusqlite::Connection) -> Result<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS artist_photos(key TEXT PRIMARY KEY,name TEXT NOT NULL,cover TEXT,origin TEXT NOT NULL,checked INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS app_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);",
    )?;
    Ok(())
}

impl ArtistPhotos {
    pub fn new() -> Self {
        Self { status: Mutex::new(Status::default()), stop: AtomicBool::new(false), last_mb: Mutex::new(None) }
    }

    pub fn status(&self) -> Status {
        self.status.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
    }

    pub fn folder(catalog: &Catalog) -> Result<Option<PathBuf>> {
        let db = catalog.db()?;
        ensure(&db)?;
        let v: Option<String> = db
            .query_row("SELECT value FROM app_settings WHERE key='artistPhotoFolder'", [], |r| r.get(0))
            .optional()?;
        Ok(v.filter(|s| !s.is_empty()).map(PathBuf::from))
    }

    pub fn set_folder(catalog: &Catalog, path: Option<&str>) -> Result<()> {
        let path = path.map(str::trim).filter(|p| !p.is_empty());
        if let Some(p) = path {
            if !Path::new(p).is_dir() {
                bail!("Nie ma takiego folderu albo nie jest dostępny: {p}")
            }
        }
        let db = catalog.db()?;
        ensure(&db)?;
        match path {
            Some(p) => db.execute(
                "INSERT INTO app_settings(key,value) VALUES('artistPhotoFolder',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                [p],
            )?,
            None => db.execute("DELETE FROM app_settings WHERE key='artistPhotoFolder'", [])?,
        };
        // A new folder can hold photos for artists already looked up.
        db.execute("DELETE FROM artist_photos WHERE origin IN ('none','folder')", [])?;
        Ok(())
    }

    /// Photos known now, by artist key: artwork hash and where it came from.
    pub fn photos(catalog: &Catalog) -> Result<BTreeMap<String, (String, String)>> {
        let db = catalog.db()?;
        ensure(&db)?;
        let mut stmt = db.prepare("SELECT key,cover,origin FROM artist_photos WHERE cover IS NOT NULL")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, (r.get::<_, String>(1)?, r.get::<_, String>(2)?))))?;
        Ok(rows.collect::<rusqlite::Result<BTreeMap<_, _>>>()?)
    }

    /// Artist names of the library with the local folders their files are in.
    fn artists(catalog: &Catalog) -> Result<BTreeMap<String, (String, Vec<PathBuf>)>> {
        let tracks = catalog.tracks()?;
        let mut names: BTreeMap<String, (String, Vec<PathBuf>)> = BTreeMap::new();
        let mut by_track: HashMap<String, Vec<String>> = HashMap::new();
        for t in &tracks {
            for name in [t.album_artist.as_str(), t.artist.as_str()] {
                let k = key(name);
                if k.is_empty() || collaboration(name) {
                    continue;
                }
                names.entry(k.clone()).or_insert_with(|| (name.trim().to_string(), Vec::new()));
                by_track.entry(t.id.clone()).or_default().push(k);
            }
        }
        let db = catalog.db()?;
        let mut stmt = db.prepare(
            "SELECT l.track_id,l.path FROM locations l JOIN sources s ON s.id=l.source_id WHERE s.kind NOT IN ('webdav','subsonic') AND l.available=1",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (id, path) = row?;
            let Some(keys) = by_track.get(&id) else { continue };
            let path = PathBuf::from(path);
            // Music/Artist/Album/track and Music/Artist/track.
            let dirs = [path.parent().and_then(Path::parent), path.parent()];
            for k in keys {
                let entry = names.get_mut(k).unwrap();
                for d in dirs.iter().flatten() {
                    let name = d.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    if loose(&name) == loose(&entry.0) && !entry.1.iter().any(|x| x == d) && entry.1.len() < 12 {
                        entry.1.push(d.to_path_buf());
                    }
                }
            }
        }
        Ok(names)
    }

    /// Photo file for an artist in the photo folder or in their own folder.
    fn find_file(folder: Option<&Path>, index: &HashMap<String, PathBuf>, name: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
        if folder.is_some() {
            if let Some(p) = index.get(&loose(name)) {
                return Some(p.clone());
            }
        }
        dirs.iter().find_map(|d| NAMES.iter().map(|n| d.join(n)).find(|p| p.is_file()))
    }

    /// Photo folder contents: `Name.jpg` and `Name/artist.jpg` (or folder.jpg).
    fn folder_index(folder: &Path) -> HashMap<String, PathBuf> {
        let mut out = HashMap::new();
        let Ok(entries) = std::fs::read_dir(folder) else { return out };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                if let Some(f) = NAMES.iter().map(|n| p.join(n)).find(|f| f.is_file()) {
                    out.entry(loose(&e.file_name().to_string_lossy())).or_insert(f);
                }
            } else if p.extension().and_then(|x| x.to_str()).is_some_and(|x| IMAGE.contains(&x.to_lowercase().as_str())) {
                if let Some(stem) = p.file_stem() {
                    out.insert(loose(&stem.to_string_lossy()), p);
                }
            }
        }
        out
    }

    fn save(catalog: &Catalog, k: &str, name: &str, cover: Option<&str>, origin: &str) -> Result<()> {
        let db = catalog.db()?;
        ensure(&db)?;
        db.execute(
            "INSERT INTO artist_photos(key,name,cover,origin,checked) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(key) DO UPDATE SET name=excluded.name,cover=excluded.cover,origin=excluded.origin,checked=excluded.checked",
            params![k, name, cover, origin, now_ms()],
        )?;
        Ok(())
    }

    /// Reads photo files for every artist, then (when asked) downloads the missing ones.
    /// `only` limits the work to these artist names (after an import).
    pub fn refresh(&self, catalog: &Catalog, metadata: &MetadataService, download: bool, only: Option<&[String]>) -> Result<()> {
        {
            let mut s = self.status.lock().map_err(|_| anyhow!("Zdjęcia wykonawców są zablokowane."))?;
            if s.running {
                bail!("Zdjęcia wykonawców są już sprawdzane.")
            }
            *s = Status { running: true, step: "Szukam zdjęć w folderach".into(), ..Default::default() };
        }
        self.stop.store(false, Ordering::Release);
        let result = self.work(catalog, metadata, download, only);
        let mut s = self.status.lock().unwrap();
        s.running = false;
        s.step.clear();
        if let Err(e) = &result {
            s.error = Some(format!("{e:#}"));
        }
        result
    }

    fn work(&self, catalog: &Catalog, metadata: &MetadataService, download: bool, only: Option<&[String]>) -> Result<()> {
        let folder = Self::folder(catalog)?.filter(|f| f.is_dir());
        let index = folder.as_deref().map(Self::folder_index).unwrap_or_default();
        let mut artists = Self::artists(catalog)?;
        if let Some(names) = only {
            let wanted: Vec<String> = names.iter().map(|n| key(n)).collect();
            artists.retain(|k, _| wanted.contains(k));
        }
        let known: HashMap<String, (Option<String>, String, i64)> = {
            let db = catalog.db()?;
            ensure(&db)?;
            let mut stmt = db.prepare("SELECT key,cover,origin,checked FROM artist_photos")?;
            let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, (r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?))))?;
            rows.collect::<rusqlite::Result<HashMap<_, _>>>()?
        };
        self.status.lock().unwrap().total = artists.len();
        // The music folder chosen for imports keeps its Plex/Jellyfin layout complete:
        // every artist folder in it gets artist.jpg.
        let music = crate::ingest::import_folder(catalog).and_then(|m| m.canonicalize().ok());
        let place = |jpeg: &[u8], dirs: &[PathBuf]| {
            let Some(m) = &music else { return };
            for d in dirs.iter().filter(|d| d.starts_with(m) && d.is_dir()) {
                if !NAMES.iter().any(|n| d.join(n).is_file()) {
                    write_new(&d.join("artist.jpg"), jpeg);
                }
            }
        };
        let mut missing = Vec::new();
        for (k, (name, dirs)) in &artists {
            if self.stop.load(Ordering::Acquire) {
                return Ok(());
            }
            if let Some(file) = Self::find_file(folder.as_deref(), &index, name, dirs) {
                let same = known.get(k).is_some_and(|(c, o, _)| c.is_some() && o == "folder");
                if !same {
                    if let Some(hash) = read_image(&file).and_then(|b| metadata.store_cover(&b).ok()) {
                        Self::save(catalog, k, name, Some(&hash), "folder")?;
                    }
                }
                if music.is_some() && file.extension().is_some_and(|e| e.eq_ignore_ascii_case("jpg") || e.eq_ignore_ascii_case("jpeg")) {
                    if let Some(bytes) = read_image(&file) {
                        place(&bytes, dirs);
                    }
                }
                self.status.lock().unwrap().found += 1;
            } else if let Some((Some(hash), _, _)) = known.get(k).filter(|(c, o, _)| c.is_some() && o != "folder") {
                // Downloaded earlier and kept by the app.
                if music.is_some() {
                    if let Some(bytes) = catalog.artwork_path(hash).ok().and_then(|p| std::fs::read(p).ok()) {
                        place(&bytes, dirs);
                    }
                }
                self.status.lock().unwrap().found += 1;
            } else {
                let recently = known.get(k).is_some_and(|(c, o, at)| c.is_none() && o == "none" && now_ms() - at < RETRY_MS);
                if !recently {
                    missing.push((k.clone(), name.clone(), dirs.clone()));
                }
                if let Some((Some(_), _, _)) = known.get(k) {
                    // The folder photo was removed: forget it.
                    Self::save(catalog, k, name, None, "none")?;
                }
            }
            self.status.lock().unwrap().done += 1;
        }
        if !download || missing.is_empty() {
            return Ok(());
        }
        {
            let mut s = self.status.lock().unwrap();
            s.done = 0;
            s.total = missing.len();
            s.step = "Pobieram brakujące zdjęcia".into();
        }
        let client = client()?;
        for (k, name, dirs) in missing {
            if self.stop.load(Ordering::Acquire) {
                break;
            }
            self.status.lock().unwrap().step = name.clone();
            let found = deezer(&client, &name)
                .map(|b| (b, "deezer"))
                .or_else(|| self.wikimedia(&client, &name).map(|b| (b, "wikimedia")));
            match found {
                Some((bytes, origin)) => {
                    let hash = metadata.store_cover(&bytes)?;
                    // Shared copy: photo folder first, else the artist's own folder.
                    let stored = catalog.artwork_path(&hash).ok().and_then(|p| std::fs::read(p).ok());
                    if let Some(jpeg) = stored {
                        let target = match &folder {
                            Some(f) => Some(f.join(format!("{}.jpg", file_name(&name)))),
                            None => dirs.first().map(|d| d.join("artist.jpg")),
                        };
                        if let Some(t) = target {
                            write_new(&t, &jpeg);
                        }
                        place(&jpeg, &dirs);
                    }
                    Self::save(catalog, &k, &name, Some(&hash), origin)?;
                    let mut s = self.status.lock().unwrap();
                    s.found += 1;
                    s.downloaded += 1;
                }
                None => Self::save(catalog, &k, &name, None, "none")?,
            }
            self.status.lock().unwrap().done += 1;
        }
        Ok(())
    }

    /// MusicBrainz asks for one request per second.
    fn mb_wait(&self) {
        let mut last = self.last_mb.lock().unwrap();
        if let Some(t) = *last {
            if let Some(wait) = Duration::from_millis(1100).checked_sub(t.elapsed()) {
                std::thread::sleep(wait);
            }
        }
        *last = Some(Instant::now());
    }

    /// Artist → MusicBrainz (exact name) → Wikidata image (P18) → Commons file at 1000 px.
    fn wikimedia(&self, client: &reqwest::blocking::Client, name: &str) -> Option<Vec<u8>> {
        let mut search = Url::parse("https://musicbrainz.org/ws/2/artist").ok()?;
        let quoted = format!("\"{}\"", name.replace('\\', "\\\\").replace('"', "\\\""));
        search.query_pairs_mut().append_pair("query", &format!("artist:{quoted}")).append_pair("limit", "5").append_pair("fmt", "json");
        self.mb_wait();
        let found: Value = serde_json::from_slice(&get(client, &search, 1024 * 1024)?).ok()?;
        let id = mb_artist(&found, name)?;
        let mut detail = Url::parse(&format!("https://musicbrainz.org/ws/2/artist/{id}")).ok()?;
        detail.query_pairs_mut().append_pair("inc", "url-rels").append_pair("fmt", "json");
        self.mb_wait();
        let artist: Value = serde_json::from_slice(&get(client, &detail, 1024 * 1024)?).ok()?;
        let q = wikidata_id(&artist)?;
        let entity = Url::parse(&format!("https://www.wikidata.org/wiki/Special:EntityData/{q}.json")).ok()?;
        let data: Value = serde_json::from_slice(&get(client, &entity, 4 * 1024 * 1024)?).ok()?;
        let file = commons_file(&data, &q)?;
        let mut thumb = Url::parse("https://commons.wikimedia.org/wiki/Special:FilePath/").ok()?;
        thumb.path_segments_mut().ok()?.pop().push(&file);
        thumb.query_pairs_mut().append_pair("width", "1000");
        get(client, &thumb, LIMIT)
    }
}

/// Every artist folder in the music folder gets artist.jpg from the photo the library
/// shows for that artist (downloaded, from the photo folder or found in a folder).
/// Never replaces a picture that is there. Returns how many it wrote.
pub fn place_in_music_folder(catalog: &Catalog) -> Result<usize> {
    let Some(music) = crate::ingest::import_folder(catalog).and_then(|m| m.canonicalize().ok()) else { return Ok(0) };
    let photos: HashMap<String, String> = {
        let db = catalog.db()?;
        ensure(&db)?;
        let mut stmt = db.prepare("SELECT key,cover FROM artist_photos WHERE cover IS NOT NULL")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    let mut written = 0;
    for (k, (_, dirs)) in ArtistPhotos::artists(catalog)? {
        let Some(hash) = photos.get(&k) else { continue };
        let targets: Vec<&PathBuf> = dirs.iter().filter(|d| d.starts_with(&music) && d.is_dir() && !NAMES.iter().any(|n| d.join(n).is_file())).collect();
        if targets.is_empty() {
            continue;
        }
        let Some(bytes) = catalog.artwork_path(hash).ok().and_then(|p| std::fs::read(p).ok()) else { continue };
        for d in targets {
            write_new(&d.join("artist.jpg"), &bytes);
            written += 1;
        }
    }
    Ok(written)
}

/// Writes a photo only where there is none: user files are never replaced.
fn write_new(t: &Path, bytes: &[u8]) {
    if t.exists() {
        return;
    }
    let partial = t.with_extension("jpg.partial");
    if std::fs::write(&partial, bytes).is_ok() && std::fs::rename(&partial, t).is_err() {
        let _ = std::fs::remove_file(&partial);
    }
}

fn read_image(path: &Path) -> Option<Vec<u8>> {
    let f = std::fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    f.take(LIMIT + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= LIMIT).then_some(bytes)
}

fn client() -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent("Mytify/0.25 (local music library; github.com/m6a6t6i-hue/Mytify)")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            // Commons answers with a redirect to its image server.
            let ok = attempt.previous().len() < 4 && attempt.url().scheme() == "https" && allowed(attempt.url());
            if ok { attempt.follow() } else { attempt.stop() }
        }))
        .build()?)
}

fn allowed(url: &Url) -> bool {
    let h = url.host_str().unwrap_or("");
    url.scheme() == "https"
        && (["api.deezer.com", "musicbrainz.org", "www.wikidata.org", "commons.wikimedia.org", "upload.wikimedia.org"].contains(&h)
            || h.ends_with(".dzcdn.net"))
}

fn get(client: &reqwest::blocking::Client, url: &Url, limit: u64) -> Option<Vec<u8>> {
    if !allowed(url) {
        return None;
    }
    let r = client.get(url.clone()).send().ok()?;
    if !r.status().is_success() || r.content_length().is_some_and(|n| n > limit) {
        return None;
    }
    let mut bytes = Vec::new();
    r.take(limit + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= limit).then_some(bytes)
}

/// Deezer artist picture (1000 px) for the artist with exactly this name. Deezer's
/// placeholder for artists without a picture is skipped.
fn deezer(client: &reqwest::blocking::Client, name: &str) -> Option<Vec<u8>> {
    let mut url = Url::parse("https://api.deezer.com/search/artist").ok()?;
    url.query_pairs_mut().append_pair("q", name).append_pair("limit", "10");
    let v: Value = serde_json::from_slice(&get(client, &url, 1024 * 1024)?).ok()?;
    let picture = deezer_pick(&v, name)?;
    get(client, &picture, LIMIT)
}

pub fn deezer_pick(v: &Value, name: &str) -> Option<Url> {
    let want = loose(name);
    let hit = v["data"].as_array()?.iter().find(|a| loose(a["name"].as_str().unwrap_or("")) == want)?;
    let raw = hit["picture_xl"].as_str().or(hit["picture_big"].as_str())?;
    if raw.contains("/artist//") {
        return None;
    }
    let url = Url::parse(raw).ok()?;
    allowed(&url).then_some(url)
}

/// MusicBrainz id of the artist with exactly this name (the best scored one).
pub fn mb_artist(v: &Value, name: &str) -> Option<String> {
    let want = loose(name);
    v["artists"]
        .as_array()?
        .iter()
        .filter(|a| a["score"].as_u64().unwrap_or(0) >= 90 && loose(a["name"].as_str().unwrap_or("")) == want)
        .find_map(|a| a["id"].as_str().map(str::to_string))
}

/// Wikidata item of a MusicBrainz artist (its "wikidata" link).
pub fn wikidata_id(v: &Value) -> Option<String> {
    v["relations"].as_array()?.iter().find_map(|r| {
        if r["type"].as_str()? != "wikidata" {
            return None;
        }
        let url = r["url"]["resource"].as_str()?;
        let q = url.rsplit('/').next()?;
        (q.starts_with('Q') && q.len() > 1 && q[1..].bytes().all(|b| b.is_ascii_digit())).then(|| q.to_string())
    })
}

/// Commons file name of the item's image (P18).
pub fn commons_file(v: &Value, q: &str) -> Option<String> {
    let file = v["entities"][q]["claims"]["P18"][0]["mainsnak"]["datavalue"]["value"].as_str()?;
    (!file.is_empty() && !file.contains('/')).then(|| file.to_string())
}

/// Map for the app: artist key → artwork address and origin.
pub fn photos_json(catalog: &Catalog, origin: &str, token: &str) -> Result<Value> {
    let mut out = Map::new();
    for (k, (hash, from)) in ArtistPhotos::photos(catalog)? {
        out.insert(k, json!({"uri": format!("{origin}/api/artwork/{hash}?token={token}"), "origin": from}));
    }
    Ok(Value::Object(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_keys() {
        assert_eq!(key("  Amorphis \u{a0}"), "amorphis");
        assert_eq!(file_name("AC/DC: Live?"), "AC_DC_ Live_");
        assert!(collaboration("Amorphis, Hellscore"));
        assert!(!collaboration("Amorphis"));
        assert!(collaboration("Various Artists"));
        assert!(collaboration("Różni wykonawcy"));
        assert_eq!(loose("Guns N' Roses"), loose("guns n roses"));
    }

    #[test]
    fn photo_folder_and_artist_folders() {
        let d = tempfile::tempdir().unwrap();
        let photos = d.path().join("photos");
        std::fs::create_dir_all(photos.join("Nocny Ekspres")).unwrap();
        std::fs::write(photos.join("Amorphis.jpg"), b"x").unwrap();
        std::fs::write(photos.join("Nocny Ekspres").join("folder.jpg"), b"x").unwrap();
        let index = ArtistPhotos::folder_index(&photos);
        assert!(index.contains_key(&loose("amorphis")));
        assert!(index.contains_key(&loose("Nocny Ekspres")));
        let music = d.path().join("Music").join("Opeth");
        std::fs::create_dir_all(&music).unwrap();
        std::fs::write(music.join("artist.png"), b"x").unwrap();
        let none = HashMap::new();
        assert_eq!(ArtistPhotos::find_file(None, &none, "Opeth", std::slice::from_ref(&music)).unwrap(), music.join("artist.png"));
        assert_eq!(ArtistPhotos::find_file(Some(&photos), &index, "AMORPHIS", &[]).unwrap(), photos.join("Amorphis.jpg"));
        assert!(ArtistPhotos::find_file(Some(&photos), &index, "Nobody", &[]).is_none());
    }

    #[test]
    fn online_answers_are_matched_exactly() {
        let deezer = json!({"data": [
            {"name": "Amorphis Tribute", "picture_xl": "https://e-cdns-images.dzcdn.net/images/artist/aaa/1000x1000.jpg"},
            {"name": "Amorphis", "picture_xl": "https://e-cdns-images.dzcdn.net/images/artist/bbb/1000x1000.jpg"}
        ]});
        assert!(deezer_pick(&deezer, "amorphis").unwrap().as_str().contains("/bbb/"));
        let blank = json!({"data": [{"name": "Nobody", "picture_xl": "https://e-cdns-images.dzcdn.net/images/artist//1000x1000.jpg"}]});
        assert!(deezer_pick(&blank, "Nobody").is_none());
        let evil = json!({"data": [{"name": "X", "picture_xl": "https://evil.example/x.jpg"}]});
        assert!(deezer_pick(&evil, "X").is_none());
        let mb = json!({"artists": [{"id": "a1", "name": "Amorphis", "score": 100}, {"id": "a2", "name": "Amorphis", "score": 40}]});
        assert_eq!(mb_artist(&mb, "Amorphis").as_deref(), Some("a1"));
        let rel = json!({"relations": [{"type": "official homepage", "url": {"resource": "https://amorphis.net"}}, {"type": "wikidata", "url": {"resource": "https://www.wikidata.org/wiki/Q309917"}}]});
        assert_eq!(wikidata_id(&rel).as_deref(), Some("Q309917"));
        let wd = json!({"entities": {"Q309917": {"claims": {"P18": [{"mainsnak": {"datavalue": {"value": "Amorphis 2018.jpg"}}}]}}}});
        assert_eq!(commons_file(&wd, "Q309917").as_deref(), Some("Amorphis 2018.jpg"));
        assert!(!allowed(&Url::parse("http://api.deezer.com/x").unwrap()));
        assert!(allowed(&Url::parse("https://upload.wikimedia.org/x.jpg").unwrap()));
    }
}
