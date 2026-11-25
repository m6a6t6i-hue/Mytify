use anyhow::{anyhow, bail, Context, Result};
use lofty::{
    file::{AudioFile, FileType, TaggedFileExt},
    prelude::Accessor,
    probe::Probe,
    tag::ItemKey,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{BufReader, Read},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, MutexGuard,
    },
    time::{SystemTime, UNIX_EPOCH},
};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};
use walkdir::WalkDir;

pub const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "m4a", "mp4", "aac", "wav", "ogg", "opus", "aif", "aiff", "ape", "wv",
];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub file_name: String,
    pub format: String,
    pub size: i64,
    pub duration_ms: i64,
    pub track_number: u32,
    pub disc_number: u32,
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub added_at: i64,
    pub cover: Option<String>,
    pub liked: bool,
    pub available: bool,
    pub location_count: u32,
    pub managed: bool,
    #[serde(default)]
    pub edited: bool,
    #[serde(default)]
    pub metadata_source: String,
    #[serde(default)]
    pub release_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub id: String,
    pub name: String,
    pub path: String,
    pub kind: String,
    pub state: String,
    pub files: u32,
    pub available_files: u32,
    pub last_scan: i64,
    /// "local", "smb" ... Network sources describe themselves, local ones do not need to.
    #[serde(default)]
    pub protocol: String,
    /// Address shown to the user. Never contains credentials.
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

#[derive(Default, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub added: u32,
    pub updated: u32,
    pub unchanged: u32,
    pub duplicates: u32,
    pub ignored: u32,
    pub missing: u32,
    pub offline_sources: u32,
    pub errors: Vec<String>,
    pub cancelled: bool,
}
impl Report {
    pub(crate) fn error(&mut self, message: String) {
        if self.errors.len() < 100 {
            self.errors.push(message);
        }
    }
}

#[derive(Default, Clone, Debug, Serialize, Deserialize)]
pub struct Progress {
    pub done: usize,
    pub total: usize,
    pub name: String,
}

#[derive(Default, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanRequest {
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub folder: bool,
    pub source_id: Option<String>,
    #[serde(default)]
    pub force: bool,
}

pub struct Catalog {
    pub root: PathBuf,
    db: Mutex<Connection>,
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
pub fn hex(bytes: impl AsRef<[u8]>) -> String {
    bytes.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}
pub fn hash_file(path: &Path) -> Result<String> {
    let mut input = BufReader::new(File::open(path)?);
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hex(hash.finalize()))
}
pub fn search_key(value: &str) -> String {
    value
        .to_lowercase()
        .replace('ł', "l")
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect()
}
fn path_key(path: &Path) -> String {
    let text = path.to_string_lossy().into_owned();
    if cfg!(windows) {
        text.to_lowercase()
    } else {
        text
    }
}
fn display_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    if let Some(unc) = text.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{unc}");
    }
    text.trim_start_matches(r"\\?\").to_owned()
}
fn supported(path: &Path) -> bool {
    path.extension()
        .and_then(|s| s.to_str())
        .is_some_and(|e| AUDIO_EXTENSIONS.contains(&e.to_lowercase().as_str()))
}
fn signature(path: &Path) -> Result<(i64, String)> {
    let m = fs::metadata(path)?;
    let stamp = m
        .modified()?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .to_string();
    Ok((i64::try_from(m.len())?, stamp))
}
pub(crate) fn riff_text(value: String, wav: bool) -> String {
    if wav && value.chars().all(|c| c as u32 <= 255) {
        if let Ok(decoded) = String::from_utf8(value.chars().map(|c| c as u8).collect()) {
            return decoded.trim_matches('\0').trim().to_string();
        }
    }
    value.trim_matches('\0').trim().to_string()
}

impl Catalog {
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join("artwork"))?;
        fs::create_dir_all(root.join("imported-v01"))?;
        let db = Connection::open(root.join("catalog.sqlite3"))?;
        db.busy_timeout(std::time::Duration::from_secs(8))?;
        let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 4 {
            bail!("Katalog pochodzi z nowszej wersji Mytify. Nie został zmieniony.");
        }
        let backup = root.join("catalog-before-0.3.sqlite3");
        if version == 2 && !backup.exists() {
            let temporary = backup.with_extension(format!("partial-{}", hex(getrandom_bytes()?)));
            db.backup("main", &temporary, None::<fn(rusqlite::backup::Progress)>)?;
            fs::rename(temporary, backup)?;
        }
        // 0.15 adds network sources. Keep an untouched copy of the previous catalog.
        let backup = root.join("catalog-before-0.15.sqlite3");
        if version == 3 && !backup.exists() {
            let temporary = backup.with_extension(format!("partial-{}", hex(getrandom_bytes()?)));
            db.backup("main", &temporary, None::<fn(rusqlite::backup::Progress)>)?;
            fs::rename(temporary, backup)?;
        }
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;
          CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,name TEXT NOT NULL,path TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'online',last_scan INTEGER NOT NULL DEFAULT 0);
          CREATE UNIQUE INDEX IF NOT EXISTS source_root ON sources(kind,path);
          CREATE TABLE IF NOT EXISTS tracks(id TEXT PRIMARY KEY,title TEXT NOT NULL,artist TEXT NOT NULL,album TEXT NOT NULL,album_artist TEXT NOT NULL,file_name TEXT NOT NULL,format TEXT NOT NULL,size INTEGER NOT NULL,duration_ms INTEGER NOT NULL,track_number INTEGER NOT NULL,disc_number INTEGER NOT NULL,sample_rate INTEGER NOT NULL,bit_depth INTEGER NOT NULL,added_at INTEGER NOT NULL,cover TEXT,liked INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS locations(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,path_key TEXT NOT NULL,path TEXT NOT NULL,track_id TEXT NOT NULL REFERENCES tracks(id),size INTEGER NOT NULL,modified TEXT NOT NULL,seen TEXT NOT NULL,available INTEGER NOT NULL DEFAULT 1,display_name TEXT NOT NULL,PRIMARY KEY(source_id,path_key));
          CREATE INDEX IF NOT EXISTS locations_track ON locations(track_id);
          CREATE TABLE IF NOT EXISTS ignored_paths(path_key TEXT PRIMARY KEY,hash TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS migrated_v01(hash TEXT PRIMARY KEY);
          CREATE VIRTUAL TABLE IF NOT EXISTS tracks_search USING fts5(track_id UNINDEXED,text,tokenize='unicode61 remove_diacritics 2');
          CREATE TABLE IF NOT EXISTS metadata_overrides(track_id TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,patch TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS source_settings(source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,protocol TEXT NOT NULL,settings TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS remote_art(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,art_id TEXT NOT NULL,cover TEXT,PRIMARY KEY(source_id,art_id));
          CREATE TABLE IF NOT EXISTS pending_sync(id INTEGER PRIMARY KEY AUTOINCREMENT,source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,kind TEXT NOT NULL,item TEXT NOT NULL,value TEXT NOT NULL,created INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS remote_playlists(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,remote_id TEXT NOT NULL,local_id TEXT NOT NULL,server_hash TEXT NOT NULL,local_hash TEXT NOT NULL,PRIMARY KEY(source_id,remote_id));
          PRAGMA user_version=4;
          UPDATE sources SET state='partial' WHERE state='scanning';")?;
        Ok(Self {
            root,
            db: Mutex::new(db),
        })
    }
    pub(crate) fn db(&self) -> Result<MutexGuard<'_, Connection>> {
        self.db
            .lock()
            .map_err(|_| anyhow!("Katalog jest zablokowany po błędzie."))
    }
    pub fn sources(&self) -> Result<Vec<Source>> {
        let db = self.db()?;
        let mut stmt = db.prepare("SELECT s.id,s.name,s.path,s.kind,s.state,s.last_scan,COUNT(l.path_key),COALESCE(SUM(CASE WHEN l.available=1 AND s.state IN ('online','partial','scanning') THEN 1 ELSE 0 END),0),(SELECT settings FROM source_settings WHERE source_id=s.id) FROM sources s LEFT JOIN locations l ON s.id=l.source_id GROUP BY s.id ORDER BY s.name")?;
        let rows = stmt.query_map([], |r| {
            let kind: String = r.get(3)?;
            let path: String = r.get(2)?;
            let settings: Option<String> = r.get(8)?;
            let network = settings
                .and_then(|s| serde_json::from_str::<crate::sources::NetworkConfig>(&s).ok());
            let (protocol, address) = match &network {
                Some(c) if c.protocol == "smb" => ("smb".to_string(), crate::sources::smb_address(c)),
                Some(c) => (c.protocol.clone(), c.url.clone()),
                None => ("local".to_string(), display_path(Path::new(&path))),
            };
            Ok(Source {
                id: r.get(0)?,
                name: r.get(1)?,
                path,
                capabilities: crate::sources::capabilities(&kind)
                    .into_iter()
                    .map(String::from)
                    .collect(),
                kind,
                state: r.get(4)?,
                last_scan: r.get(5)?,
                files: r.get(6)?,
                available_files: r.get(7)?,
                protocol,
                address,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
    pub fn refresh_sources(&self) -> Result<()> {
        for source in self.sources()? {
            // Network shares are probed in the background, never while listing the library:
            // an unreachable NAS must not freeze the UI.
            if matches!(source.kind.as_str(), "files" | "smb" | "webdav" | "subsonic") {
                continue;
            }
            let path = Path::new(&source.path);
            if !path.is_dir() {
                self.db()?.execute(
                    "UPDATE sources SET state='offline' WHERE id=?",
                    [&source.id],
                )?;
            } else if source.state == "offline" {
                self.db()?.execute(
                    "UPDATE sources SET state='partial' WHERE id=?",
                    [&source.id],
                )?;
            }
        }
        Ok(())
    }
    fn ensure_source(&self, path: &Path, kind: &str) -> Result<Source> {
        let canonical = if kind == "files" {
            PathBuf::new()
        } else {
            fs::canonicalize(path)?
        };
        let existing: Option<String> = self
            .db()?
            .query_row(
                "SELECT id FROM sources WHERE path=?1 AND kind=?2",
                params![canonical.to_string_lossy(), kind],
                |r| r.get(0),
            )
            .optional()?;
        let id = existing.unwrap_or_else(|| {
            if kind == "files" {
                "manual-files".into()
            } else {
                hex(Sha256::digest(
                    format!("{kind}\0{}", path_key(&canonical)).as_bytes(),
                ))
            }
        });
        let name = match kind {
            "files" => "Wybrane pliki".into(),
            "managed" => "Przeniesione z wersji 0.1".into(),
            _ => canonical
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| display_path(&canonical)),
        };
        let stored_path = canonical.to_string_lossy().into_owned();
        self.db()?.execute("INSERT INTO sources(id,name,path,kind,state) VALUES(?1,?2,?3,?4,'online') ON CONFLICT(id) DO UPDATE SET name=excluded.name",params![id,name,stored_path,kind])?;
        Ok(Source {
            id,
            name,
            path: stored_path.clone(),
            kind: kind.into(),
            state: "online".into(),
            files: 0,
            available_files: 0,
            last_scan: 0,
            protocol: "local".into(),
            address: display_path(Path::new(&stored_path)),
            capabilities: crate::sources::capabilities(kind)
                .into_iter()
                .map(String::from)
                .collect(),
        })
    }
    /// Saved settings of a network source, without the password.
    pub fn network_settings(&self, id: &str) -> Result<Option<crate::sources::NetworkConfig>> {
        let text: Option<String> = self
            .db()?
            .query_row(
                "SELECT settings FROM source_settings WHERE source_id=?",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        Ok(match text {
            Some(t) => Some(serde_json::from_str(&t)?),
            None => None,
        })
    }
    /// Adds a new SMB source or updates one. The password goes to the system store.
    pub fn save_network_source(
        &self,
        id: Option<&str>,
        config: &crate::sources::NetworkConfig,
    ) -> Result<String> {
        let config = crate::sources::clean(config)?;
        let kind = config.protocol.clone();
        // Where the source lives and the key that makes two equal sources one.
        let (stored, key) = match kind.as_str() {
            "smb" => {
                let root = crate::sources::smb_scan_root(&config);
                (root.to_string_lossy().into_owned(), path_key(&root))
            }
            "subsonic" => (config.url.clone(), format!("{}|{}", config.url.to_lowercase(), config.user)),
            _ => {
                let root = crate::sources::webdav_root(&config, "")?;
                (root.to_string(), root.to_string().to_lowercase())
            }
        };
        let new_id = hex(Sha256::digest(format!("{kind}\0{key}").as_bytes()));
        let adding = id.is_none();
        let id = id.map(str::to_owned).unwrap_or(new_id);
        let previous: Option<(String, String)> = self
            .db()?
            .query_row(
                "SELECT path,kind FROM sources WHERE id=?",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        match &previous {
            Some((_, k)) if *k != kind => bail!("To źródło jest innego rodzaju."),
            Some(_) if adding => bail!("Ten folder sieciowy jest już dodany."),
            None if !adding => bail!("Nie znaleziono źródła."),
            _ => {}
        }
        if let Some(password) = &config.password {
            crate::secrets::store(&id, &crate::sources::login_name(&config), password)?;
        }
        crate::sources::forget_clients(&id);
        let settings = serde_json::to_string(&config)?;
        let mut db = self.db()?;
        let tx = db.transaction()?;
        tx.execute("INSERT INTO sources(id,name,path,kind,state) VALUES(?1,?2,?3,?4,'partial') ON CONFLICT(id) DO UPDATE SET name=excluded.name,path=excluded.path",params![id,config.name,stored,kind])?;
        if let Some((old_path, _)) = &previous {
            if old_path.to_lowercase() != stored.to_lowercase() {
                // Another folder: old locations would only look like missing files.
                // Tracks (content hash), likes and playlists stay; a rescan re-links them.
                tx.execute("DELETE FROM locations WHERE source_id=?", [&id])?;
                tx.execute("UPDATE sources SET state='partial',last_scan=0 WHERE id=?", [&id])?;
            }
        }
        tx.execute("INSERT INTO source_settings(source_id,protocol,settings) VALUES(?1,?2,?3) ON CONFLICT(source_id) DO UPDATE SET settings=excluded.settings",params![id,kind,settings])?;
        tx.commit()?;
        Ok(id)
    }
    /// Re-opens the session of a network source. Used before scans and after read errors.
    pub fn reconnect(&self, id: &str) -> Result<()> {
        match self.network_settings(id)? {
            Some(config) => crate::sources::connect(Some(id), &config),
            None => Ok(()),
        }
    }
    /// Background reachability check, so the library shows the real state of a NAS.
    pub fn probe_network_sources(&self) -> Result<()> {
        for source in self.sources()?.into_iter().filter(|s| matches!(s.kind.as_str(), "smb" | "webdav" | "subsonic")) {
            let reachable = self.reconnect(&source.id).is_ok()
                && (source.kind != "smb" || self
                    .db()?
                    .query_row("SELECT path FROM sources WHERE id=?", [&source.id], |r| {
                        r.get::<_, String>(0)
                    })
                    .map(|p| Path::new(&p).is_dir())
                    .unwrap_or(false));
            let state = match (reachable, source.state.as_str()) {
                (_, "scanning") => continue,
                (false, _) => "offline",
                (true, "offline") => "partial",
                (true, s) => s,
            };
            self.db()?.execute(
                "UPDATE sources SET state=?1 WHERE id=?2 AND state<>'scanning'",
                params![state, source.id],
            )?;
            if reachable && source.kind == "subsonic" {
                let _ = self.flush_pending(&source.id);
            }
        }
        Ok(())
    }
    pub fn tracks(&self) -> Result<Vec<Track>> {
        self.refresh_sources()?;
        let db = self.db()?;
        let mut stmt = db.prepare("SELECT t.id,t.title,t.artist,t.album,t.album_artist,t.file_name,t.format,t.size,t.duration_ms,t.track_number,t.disc_number,t.sample_rate,t.bit_depth,t.added_at,t.cover,t.liked,MAX(CASE WHEN l.available=1 AND s.state IN ('online','partial','scanning') THEN 1 ELSE 0 END),COUNT(l.path_key),MIN(CASE WHEN s.kind='managed' THEN 1 ELSE 0 END) FROM tracks t JOIN locations l ON l.track_id=t.id JOIN sources s ON s.id=l.source_id GROUP BY t.id ORDER BY t.added_at DESC,t.id")?;
        let rows = stmt.query_map([], |r| {
            Ok(Track {
                id: r.get(0)?,
                title: r.get(1)?,
                artist: r.get(2)?,
                album: r.get(3)?,
                album_artist: r.get(4)?,
                file_name: r.get(5)?,
                format: r.get(6)?,
                size: r.get(7)?,
                duration_ms: r.get(8)?,
                track_number: r.get(9)?,
                disc_number: r.get(10)?,
                sample_rate: r.get(11)?,
                bit_depth: r.get(12)?,
                added_at: r.get(13)?,
                cover: r.get(14)?,
                liked: r.get(15)?,
                available: r.get(16)?,
                location_count: r.get(17)?,
                managed: r.get(18)?,
                edited: false,
                metadata_source: String::new(),
                release_id: None,
            })
        })?;
        let mut values = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut overrides = db.prepare("SELECT track_id,patch FROM metadata_overrides")?;
        let patches = overrides
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<rusqlite::Result<std::collections::HashMap<_, _>>>()?;
        for track in &mut values {
            if let Some(patch) = patches.get(&track.id) {
                crate::metadata::overlay(track, &serde_json::from_str(patch)?)?;
            }
        }
        Ok(values)
    }
    pub fn search_ids(&self, query: &str) -> Result<Vec<String>> {
        let terms: Vec<String> = search_key(query)
            .split_whitespace()
            .take(32)
            .map(|s| format!("\"{}\"*", s.replace('"', "\"\"")))
            .collect();
        if terms.is_empty() {
            return Ok(self.tracks()?.into_iter().map(|t| t.id).collect());
        }
        let db = self.db()?;
        let mut stmt=db.prepare("SELECT t.id FROM tracks_search f JOIN tracks t ON t.id=f.track_id WHERE f.text MATCH ?1 AND EXISTS(SELECT 1 FROM locations l WHERE l.track_id=t.id) ORDER BY t.title")?;
        let rows = stmt.query_map([terms.join(" AND ")], |r| r.get(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
    pub fn like(&self, id: &str, liked: bool) -> Result<()> {
        let mut db = self.db()?;
        let tx = db.transaction()?;
        tx.execute("UPDATE tracks SET liked=?1 WHERE id=?2", params![liked, id])?;
        // A music server keeps its own favourites: remember the change and send it when
        // the server is reachable. The newest local choice replaces an unsent older one.
        let remote: Vec<(String, String)> = {
            let mut stmt = tx.prepare("SELECT l.source_id,l.path FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1 AND s.kind='subsonic'")?;
            let rows = stmt.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        for (source, song) in &remote {
            tx.execute("DELETE FROM pending_sync WHERE source_id=?1 AND kind='star' AND item=?2", params![source, song])?;
            tx.execute("INSERT INTO pending_sync(source_id,kind,item,value,created) VALUES(?1,'star',?2,?3,?4)", params![source, song, if liked { "1" } else { "0" }, now_ms()])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn forget_track(&self, id: &str) -> Result<()> {
        let mut db = self.db()?;
        let tx = db.transaction()?;
        tx.execute("INSERT INTO ignored_paths(path_key,hash) SELECT path_key,track_id FROM locations WHERE track_id=?1 ON CONFLICT(path_key) DO UPDATE SET hash=excluded.hash",[id])?;
        tx.execute("DELETE FROM locations WHERE track_id=?1", [id])?;
        tx.commit()?;
        Ok(())
    }
    pub fn forget_source(&self, id: &str) -> Result<()> {
        let network = self.network_settings(id)?;
        self.db()?.execute("DELETE FROM sources WHERE id=?", [id])?;
        if let Some(config) = network {
            crate::secrets::delete(id);
            crate::sources::forget_clients(id);
            if config.protocol == "smb" {
                crate::smb::disconnect(&crate::sources::share_root(&config));
            }
        }
        Ok(())
    }
    pub fn relink_source(&self, id: &str, new_path: &Path) -> Result<()> {
        let source = self
            .sources()?
            .into_iter()
            .find(|s| s.id == id)
            .ok_or_else(|| anyhow!("Nie znaleziono źródła."))?;
        if source.kind != "folder" {
            bail!("To źródło nie jest podłączonym folderem.");
        }
        let canonical = fs::canonicalize(new_path)?;
        if !canonical.is_dir() {
            bail!("Wskaż folder z muzyką.");
        }
        if self.sources()?.iter().any(|s| {
            s.id != id && s.kind == "folder" && path_key(Path::new(&s.path)) == path_key(&canonical)
        }) {
            bail!("Ten folder jest już dodany do biblioteki.");
        }
        let old_root = PathBuf::from(path_key(Path::new(&source.path)));
        let mut db = self.db()?;
        let ignored: Vec<(String, String)> = {
            let mut stmt = db.prepare("SELECT path_key,hash FROM ignored_paths")?;
            let values = stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?;
            values
        };
        let locations: Vec<String> = {
            let mut stmt = db.prepare("SELECT path_key FROM locations WHERE source_id=?1")?;
            let values = stmt
                .query_map([id], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            values
        };
        let tx = db.transaction()?;
        for old in locations {
            if let Ok(relative) = Path::new(&old).strip_prefix(&old_root) {
                let target = canonical.join(relative);
                tx.execute("UPDATE locations SET path_key=?1,path=?2,available=0,seen='' WHERE source_id=?3 AND path_key=?4",
                    params![path_key(&target),target.to_string_lossy(),id,old])?;
            }
        }
        for (old, hash) in ignored {
            if let Ok(relative) = Path::new(&old).strip_prefix(&old_root) {
                tx.execute(
                    "INSERT OR REPLACE INTO ignored_paths(path_key,hash) VALUES(?1,?2)",
                    params![path_key(&canonical.join(relative)), hash],
                )?;
            }
        }
        tx.execute(
            "UPDATE sources SET path=?1,name=?2,state='partial' WHERE id=?3",
            params![
                canonical.to_string_lossy(),
                canonical.file_name().unwrap_or_default().to_string_lossy(),
                id
            ],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn audio_path(&self, id: &str) -> Result<PathBuf> {
        // Local copies first, network shares last; available locations before stale ones.
        let paths: Vec<(String, String, String)> = {
            let db = self.db()?;
            let mut stmt = db.prepare("SELECT l.path,s.id,s.kind FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1 AND s.kind NOT IN ('webdav','subsonic') ORDER BY CASE WHEN s.kind='smb' THEN 1 ELSE 0 END,l.available DESC")?;
            let values = stmt
                .query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            values
        };
        let usable = |value: &str| -> Option<PathBuf> {
            let path = PathBuf::from(value);
            let canonical = fs::canonicalize(&path).ok()?;
            // Reject replacement symlinks that now point somewhere else.
            (canonical.is_file() && path_key(&canonical) == path_key(&path)).then_some(canonical)
        };
        let mut network_error = None;
        for (value, source, kind) in &paths {
            if let Some(found) = usable(value) {
                return Ok(found);
            }
            if kind == "smb" {
                // A dropped session after sleep or a network change: log in again once.
                match self.reconnect(source) {
                    Ok(()) => {
                        if let Some(found) = usable(value) {
                            return Ok(found);
                        }
                    }
                    Err(e) => network_error = Some(e),
                }
            }
        }
        if let Some(e) = network_error {
            bail!("Źródło niedostępne. {e}");
        }
        bail!("Plik jest niedostępny. Podłącz źródło i wykonaj ponowny skan.")
    }
    pub fn artwork_path(&self, id: &str) -> Result<PathBuf> {
        if id.len() != 64 || !id.chars().all(|c| c.is_ascii_hexdigit()) {
            bail!("Nieprawidłowa okładka.");
        }
        let path = self.root.join("artwork").join(id);
        if !path.is_file() {
            bail!("Brak okładki.");
        }
        Ok(path)
    }
    pub fn scan(
        &self,
        request: ScanRequest,
        cancel: &AtomicBool,
        mut progress: impl FnMut(Progress),
    ) -> Result<Report> {
        let mut report = Report::default();
        let mut tasks = Vec::new();
        if let Some(id) = request.source_id.as_deref() {
            tasks = self
                .sources()?
                .into_iter()
                .filter(|s| id == "all" || s.id == id)
                .collect();
            if tasks.is_empty() {
                bail!("Nie znaleziono źródła.");
            }
        } else if request.folder {
            for path in &request.paths {
                let path = Path::new(path);
                if !path.is_dir() {
                    report.error(format!("{}: folder jest niedostępny", display_path(path)));
                    continue;
                }
                tasks.push(self.ensure_source(path, "folder")?);
            }
        } else if !request.paths.is_empty() {
            tasks.push(self.ensure_source(Path::new(""), "files")?);
        }
        for source in tasks {
            if cancel.load(Ordering::Relaxed) {
                report.cancelled = true;
                break;
            }
            let generation = format!("{}-{}", now_ms(), hex(getrandom_bytes()?));
            if source.kind == "subsonic" {
                self.scan_subsonic(&source, &generation, cancel, &mut progress, &mut report)?;
                continue;
            }
            if source.kind == "webdav" {
                self.scan_webdav(&source, &generation, request.force, cancel, &mut progress, &mut report)?;
                continue;
            }
            let mut files = Vec::new();
            let mut complete = true;
            if source.kind == "files" {
                if request.source_id.is_none() {
                    files = request.paths.iter().map(PathBuf::from).collect();
                } else {
                    let db = self.db()?;
                    let mut stmt = db.prepare("SELECT path FROM locations WHERE source_id=?1")?;
                    files = stmt
                        .query_map([&source.id], |r| r.get::<_, String>(0))?
                        .collect::<rusqlite::Result<Vec<_>>>()?
                        .into_iter()
                        .map(PathBuf::from)
                        .collect();
                }
            } else {
                let root = Path::new(&source.path);
                if source.kind == "smb" {
                    if let Err(e) = self.reconnect(&source.id) {
                        // Unreachable NAS: keep the collection, just mark it offline.
                        self.db()?.execute(
                            "UPDATE sources SET state='offline' WHERE id=?",
                            [&source.id],
                        )?;
                        report.offline_sources += 1;
                        report.error(format!("{}: {e}", source.name));
                        continue;
                    }
                }
                if !root.is_dir() {
                    self.db()?.execute(
                        "UPDATE sources SET state='offline' WHERE id=?",
                        [&source.id],
                    )?;
                    report.offline_sources += 1;
                    continue;
                }
                for entry in WalkDir::new(root).follow_links(false) {
                    if cancel.load(Ordering::Relaxed) {
                        complete = false;
                        report.cancelled = true;
                        break;
                    }
                    match entry {
                        Ok(entry) if entry.file_type().is_file() => {
                            if supported(entry.path()) {
                                files.push(entry.into_path());
                            } else {
                                report.ignored += 1;
                            }
                        }
                        Ok(_) => {}
                        Err(error) => {
                            complete = false;
                            report.error(error.to_string());
                        }
                    }
                }
            }
            files.sort();
            files.dedup();
            self.db()?.execute(
                "UPDATE sources SET state='scanning' WHERE id=?",
                [&source.id],
            )?;
            for (i, path) in files.iter().enumerate() {
                if cancel.load(Ordering::Relaxed) {
                    complete = false;
                    report.cancelled = true;
                    break;
                }
                progress(Progress {
                    done: i,
                    total: files.len(),
                    name: display_path(path),
                });
                if !supported(path) {
                    report.ignored += 1;
                    continue;
                }
                if request.source_id.is_none() && !request.folder {
                    if let Ok(canonical) = fs::canonicalize(path) {
                        self.db()?.execute(
                            "DELETE FROM ignored_paths WHERE path_key=?",
                            [path_key(&canonical)],
                        )?;
                    }
                }
                if !path.is_file() {
                    report.missing+=self.db()?.execute("UPDATE locations SET available=0 WHERE source_id=?1 AND path_key=?2 AND available=1",params![source.id,path_key(path)])? as u32;
                    continue;
                }
                if let Err(error) =
                    self.ingest(&source, path, &generation, request.force, None, &mut report)
                {
                    complete = false;
                    report.error(format!("{}: {error}", display_path(path)));
                }
            }
            if complete && !report.cancelled && source.kind != "files" {
                report.missing+=self.db()?.execute("UPDATE locations SET available=0 WHERE source_id=?1 AND seen<>?2 AND available=1",params![source.id,generation])? as u32;
            }
            self.db()?.execute(
                "UPDATE sources SET state=?1,last_scan=?2 WHERE id=?3",
                params![
                    if complete && !report.cancelled {
                        "online"
                    } else {
                        "partial"
                    },
                    now_ms(),
                    source.id
                ],
            )?;
            progress(Progress {
                done: files.len(),
                total: files.len(),
                name: source.name,
            });
        }
        Ok(report)
    }
    fn ingest(
        &self,
        source: &Source,
        path: &Path,
        generation: &str,
        force: bool,
        original_name: Option<&str>,
        report: &mut Report,
    ) -> Result<String> {
        let canonical = fs::canonicalize(path)?;
        let key = path_key(&canonical);
        let (size, modified) = signature(&canonical)?;
        if size == 0 {
            bail!("Plik jest pusty.");
        }
        let prior:Option<(String,i64,String,String)>=self.db()?.query_row("SELECT track_id,size,modified,display_name FROM locations WHERE source_id=?1 AND path_key=?2",params![source.id,key],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        if !force {
            if let Some((id, old_size, stamp, _)) = &prior {
                if *old_size == size && *stamp == modified {
                    self.db()?.execute("UPDATE locations SET available=1,seen=?1 WHERE source_id=?2 AND path_key=?3",params![generation,source.id,key])?;
                    report.unchanged += 1;
                    return Ok(id.clone());
                }
            }
        }
        let hash = hash_file(&canonical)?;
        let ignored: Option<String> = self
            .db()?
            .query_row(
                "SELECT hash FROM ignored_paths WHERE path_key=?",
                [&key],
                |r| r.get(0),
            )
            .optional()?;
        if ignored.as_deref() == Some(&hash) {
            report.ignored += 1;
            return Ok(hash);
        }
        let file = Probe::open(&canonical)?
            .guess_file_type()?
            .read()
            .context("Nie można odczytać danych audio")?;
        let properties = file.properties();
        let tag = file.primary_tag().or_else(|| file.first_tag());
        let wav = file.file_type() == FileType::Wav;
        let name = original_name
            .map(str::to_owned)
            .or_else(|| prior.as_ref().map(|p| p.3.clone()))
            .unwrap_or_else(|| {
                canonical
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned()
            });
        let title = riff_text(
            tag.and_then(|t| t.title())
                .map(|t| t.into_owned())
                .unwrap_or_default(),
            wav,
        );
        let title = if title.is_empty() {
            Path::new(&name)
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        } else {
            title
        };
        let artist = riff_text(
            tag.and_then(|t| t.artist())
                .map(|t| t.into_owned())
                .unwrap_or_default(),
            wav,
        );
        let album = riff_text(
            tag.and_then(|t| t.album())
                .map(|t| t.into_owned())
                .unwrap_or_default(),
            wav,
        );
        let album_artist = riff_text(
            tag.and_then(|t| t.get_string(ItemKey::AlbumArtist))
                .unwrap_or_default()
                .to_string(),
            wav,
        );
        let picture = tag.and_then(|t| {
            t.pictures()
                .iter()
                .find(|p| p.data().len() <= 4 * 1024 * 1024)
        });
        let cover = if let Some(picture) = picture {
            let id = hex(Sha256::digest(picture.data()));
            let target = self.root.join("artwork").join(&id);
            if !target.exists() {
                let temporary = target.with_extension("partial");
                fs::write(&temporary, picture.data())?;
                fs::rename(temporary, &target)?;
            }
            Some(id)
        } else {
            None
        };
        if signature(&canonical)? != (size, modified.clone()) {
            bail!("Plik zmienił się podczas skanowania. Spróbuj ponownie.");
        }
        let mut db = self.db()?;
        let tx = db.transaction()?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM tracks WHERE id=?)",
            [&hash],
            |r| r.get(0),
        )?;
        let visible: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM locations WHERE track_id=?)",
            [&hash],
            |r| r.get(0),
        )?;
        let old_liked: bool = if let Some((id, _, _, _)) = &prior {
            tx.query_row("SELECT liked FROM tracks WHERE id=?", [id], |r| r.get(0))
                .optional()?
                .unwrap_or(false)
        } else {
            false
        };
        let format = match file.file_type() {
            FileType::Flac => "FLAC",
            FileType::Mpeg => "MP3",
            FileType::Mp4 => "M4A",
            FileType::Wav => "WAV",
            FileType::Aac => "AAC",
            FileType::Aiff => "AIFF",
            FileType::Opus => "OPUS",
            FileType::Vorbis => "OGG",
            _ => "AUDIO",
        };
        tx.execute("INSERT OR IGNORE INTO tracks(id,title,artist,album,album_artist,file_name,format,size,duration_ms,track_number,disc_number,sample_rate,bit_depth,added_at,cover,liked) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",params![hash,title,artist,album,album_artist,name,format,size,properties.duration().as_millis() as i64,tag.and_then(|t|t.track()).unwrap_or(0),tag.and_then(|t|t.disk()).unwrap_or(0),properties.sample_rate().unwrap_or(0),properties.bit_depth().unwrap_or(0),now_ms(),cover,old_liked])?;
        if old_liked {
            tx.execute("UPDATE tracks SET liked=1 WHERE id=?", [&hash])?;
        }
        if !exists {
            tx.execute(
                "INSERT INTO tracks_search(track_id,text) VALUES(?1,?2)",
                params![
                    hash,
                    search_key(&format!("{title} {artist} {album} {album_artist} {name}"))
                ],
            )?;
        }
        if let Some((old_id, _, _, _)) = &prior {
            if old_id != &hash {
                tx.execute("INSERT OR IGNORE INTO metadata_overrides(track_id,patch) SELECT ?1,patch FROM metadata_overrides WHERE track_id=?2",params![hash,old_id])?;
                crate::metadata::reindex(&tx, &hash)?;
            }
        }
        tx.execute("INSERT INTO locations(source_id,path_key,path,track_id,size,modified,seen,available,display_name) VALUES(?1,?2,?3,?4,?5,?6,?7,1,?8) ON CONFLICT(source_id,path_key) DO UPDATE SET path=excluded.path,track_id=excluded.track_id,size=excluded.size,modified=excluded.modified,seen=excluded.seen,available=1,display_name=excluded.display_name",params![source.id,key,canonical.to_string_lossy(),hash,size,modified,generation,name])?;
        tx.commit()?;
        match prior {
            Some((id, _, _, _)) if id != hash => report.updated += 1,
            Some(_) => report.unchanged += 1,
            None if visible => report.duplicates += 1,
            None => report.added += 1,
        };
        Ok(hash)
    }
    pub fn migrate_file(
        &self,
        path: &Path,
        original_name: &str,
        expected_hash: &str,
        liked: bool,
    ) -> Result<Report> {
        if hash_file(path)? != expected_hash {
            bail!("Suma kontrolna przenoszonego pliku nie zgadza się.");
        }
        let root = self.root.join("imported-v01");
        let source = self.ensure_source(&root, "managed")?;
        let already: bool = self.db()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM migrated_v01 WHERE hash=?)",
            [expected_hash],
            |r| r.get(0),
        )?;
        let mut report = Report::default();
        self.ingest(
            &source,
            path,
            "migration",
            true,
            Some(original_name),
            &mut report,
        )?;
        let mut db = self.db()?;
        let tx = db.transaction()?;
        if !already && liked {
            tx.execute("UPDATE tracks SET liked=1 WHERE id=?", [expected_hash])?;
        }
        tx.execute(
            "INSERT OR IGNORE INTO migrated_v01(hash) VALUES(?)",
            [expected_hash],
        )?;
        tx.commit()?;
        Ok(report)
    }
}

pub fn getrandom_bytes() -> Result<[u8; 16]> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|e| anyhow!("Losowanie identyfikatora: {e}"))?;
    Ok(b)
}
