//! Offline copies of network tracks ("Pobierz offline"). A download is another location of
//! the same track: never a second track or album. Partial files are never playable, a file
//! that changed on the server is started again, and only verified copies are kept.

use crate::catalog::{hash_file, now_ms, path_key, Catalog};
use anyhow::{anyhow, bail, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex,
    },
    time::Duration,
};

pub const SOURCE: &str = "downloads";
/// Kept free on the disk on top of the file being written.
const MARGIN: u64 = 200 * 1024 * 1024;
const MAX_ATTEMPTS: i64 = 5;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub state: String,
    pub done: i64,
    pub total: i64,
    pub error: String,
    pub reason: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub items: Vec<Item>,
    pub paused: bool,
    /// Bytes of finished downloads on this device.
    pub used: u64,
    pub free: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Estimate {
    pub count: usize,
    pub bytes: u64,
    /// Tracks whose size the source does not report (estimate is then incomplete).
    pub unknown: usize,
    pub free: Option<u64>,
}

pub struct Downloads {
    catalog: Arc<Catalog>,
    dir: PathBuf,
    paused: AtomicBool,
    wake: (Mutex<bool>, Condvar),
}

#[cfg(windows)]
pub fn free_space(path: &Path) -> Option<u64> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut free = 0u64;
    let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free, std::ptr::null_mut(), std::ptr::null_mut()) };
    (ok != 0).then_some(free)
}

#[cfg(not(windows))]
pub fn free_space(_path: &Path) -> Option<u64> {
    None
}

impl Downloads {
    pub fn new(catalog: Arc<Catalog>) -> Result<Arc<Self>> {
        // Next to the catalog, never in a temporary folder the system may clean.
        let dir = catalog.root.join("Pobrane");
        fs::create_dir_all(&dir)?;
        {
            let db = catalog.db()?;
            db.execute(
                "INSERT INTO sources(id,name,path,kind,state) VALUES(?1,'Pobrane',?2,'downloads','online') ON CONFLICT(id) DO UPDATE SET path=excluded.path",
                params![SOURCE, dir.to_string_lossy()],
            )?;
            // A download interrupted by closing the app continues on the next start.
            db.execute("UPDATE downloads SET state='queued' WHERE state='running'", [])?;
        }
        Ok(Arc::new(Self {
            catalog,
            dir,
            paused: AtomicBool::new(false),
            wake: (Mutex::new(false), Condvar::new()),
        }))
    }

    pub fn start(self: &Arc<Self>) {
        let this = self.clone();
        std::thread::spawn(move || loop {
            match this.next() {
                Ok(Some(id)) => this.run(&id),
                _ => {
                    let (lock, cv) = &this.wake;
                    let mut woken = lock.lock().unwrap();
                    if !*woken {
                        woken = cv.wait_timeout(woken, Duration::from_secs(30)).unwrap().0;
                    }
                    *woken = false;
                }
            }
        });
    }

    fn poke(&self) {
        let (lock, cv) = &self.wake;
        *lock.lock().unwrap() = true;
        cv.notify_all();
    }

    fn next(&self) -> Result<Option<String>> {
        if self.paused.load(Ordering::Relaxed) {
            return Ok(None);
        }
        Ok(self
            .catalog
            .db()?
            .query_row("SELECT track_id FROM downloads WHERE state='queued' ORDER BY added,track_id LIMIT 1", [], |r| r.get(0))
            .optional()?)
    }

    /// Size of what would be downloaded, before anything starts.
    pub fn estimate(&self, ids: &[String]) -> Result<Estimate> {
        let db = self.catalog.db()?;
        let mut out = Estimate { count: 0, bytes: 0, unknown: 0, free: free_space(&self.dir) };
        for id in ids {
            let row: Option<(bool, bool, i64)> = db
                .query_row(
                    "SELECT MAX(CASE WHEN s.kind='downloads' AND l.available=1 THEN 1 ELSE 0 END),MAX(CASE WHEN s.kind IN ('smb','webdav','subsonic') THEN 1 ELSE 0 END),MAX(l.size) FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1",
                    [id],
                    |r| Ok((r.get::<_, Option<bool>>(0)?.unwrap_or(false), r.get::<_, Option<bool>>(1)?.unwrap_or(false), r.get::<_, Option<i64>>(2)?.unwrap_or(0))),
                )
                .optional()?;
            if let Some((offline, remote, size)) = row {
                if remote && !offline {
                    out.count += 1;
                    if size > 0 {
                        out.bytes += size as u64;
                    } else {
                        out.unknown += 1;
                    }
                }
            }
        }
        Ok(out)
    }

    /// Queues tracks. Already downloaded or purely local tracks are skipped.
    pub fn add(&self, ids: &[String], reason: &str) -> Result<usize> {
        let mut added = 0;
        {
            let db = self.catalog.db()?;
            for id in ids {
                let remote: bool = db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1 AND s.kind IN ('smb','webdav','subsonic'))",
                    [id],
                    |r| r.get(0),
                )?;
                if !remote {
                    continue;
                }
                // A user choice outranks a playlist kept offline.
                added += db.execute(
                    "INSERT INTO downloads(track_id,state,reason,added) VALUES(?1,'queued',?2,?3) ON CONFLICT(track_id) DO UPDATE SET reason=CASE WHEN excluded.reason='user' THEN 'user' ELSE reason END,state=CASE WHEN state IN ('failed') THEN 'queued' ELSE state END,attempts=CASE WHEN state='failed' THEN 0 ELSE attempts END",
                    params![id, reason, now_ms()],
                )?;
            }
        }
        self.poke();
        Ok(added)
    }

    pub fn pause(&self, paused: bool) {
        self.paused.store(paused, Ordering::Relaxed);
        self.poke();
    }

    pub fn status(&self) -> Result<Status> {
        let db = self.catalog.db()?;
        let mut stmt = db.prepare("SELECT d.track_id,COALESCE(t.title,''),COALESCE(t.artist,''),d.state,d.done,d.total,d.error,d.reason FROM downloads d LEFT JOIN tracks t ON t.id=d.track_id WHERE d.state<>'done' ORDER BY d.added,d.track_id")?;
        let items = stmt
            .query_map([], |r| {
                Ok(Item {
                    id: r.get(0)?,
                    title: r.get(1)?,
                    artist: r.get(2)?,
                    state: r.get(3)?,
                    done: r.get(4)?,
                    total: r.get(5)?,
                    error: r.get(6)?,
                    reason: r.get(7)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let used: i64 = db.query_row(
            "SELECT COALESCE(SUM(size),0) FROM locations WHERE source_id=?1 AND available=1",
            [SOURCE],
            |r| r.get(0),
        )?;
        Ok(Status { items, paused: self.paused.load(Ordering::Relaxed), used: used as u64, free: free_space(&self.dir) })
    }

    /// Stops waiting or running downloads of these tracks and drops their partial files.
    pub fn cancel(&self, ids: &[String]) -> Result<()> {
        let db = self.catalog.db()?;
        for id in ids {
            db.execute("DELETE FROM downloads WHERE track_id=?1 AND state<>'done'", [id])?;
            for f in self.partials(id) {
                let _ = fs::remove_file(f);
            }
        }
        Ok(())
    }

    /// "Usuń pobranie": only the local copy goes. The NAS file, likes and playlists stay.
    pub fn remove(&self, ids: &[String]) -> Result<()> {
        self.cancel(ids)?;
        let mut db = self.catalog.db()?;
        let tx = db.transaction()?;
        for id in ids {
            let paths: Vec<String> = {
                let mut stmt = tx.prepare("SELECT path FROM locations WHERE source_id=?1 AND track_id=?2")?;
                let rows = stmt.query_map(params![SOURCE, id], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
                rows
            };
            for p in paths {
                let path = PathBuf::from(&p);
                // Only files inside our own folder are ever deleted.
                if path.starts_with(&self.dir) {
                    let _ = fs::remove_file(&path);
                }
            }
            tx.execute("DELETE FROM locations WHERE source_id=?1 AND track_id=?2", params![SOURCE, id])?;
            tx.execute("DELETE FROM downloads WHERE track_id=?1", [id])?;
        }
        tx.commit()?;
        Ok(())
    }

    fn partials(&self, id: &str) -> Vec<PathBuf> {
        fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                name.starts_with(id) && (name.ends_with(".part") || name.ends_with(".part.json"))
            })
            .collect()
    }

    fn set(&self, id: &str, state: &str, error: &str) -> Result<()> {
        self.catalog.db()?.execute(
            "UPDATE downloads SET state=?1,error=?2 WHERE track_id=?3",
            params![state, error, id],
        )?;
        Ok(())
    }

    fn run(&self, id: &str) {
        let _ = self.set(id, "running", "");
        match self.fetch(id) {
            Ok(()) => {}
            Err(e) => {
                let message = e.to_string();
                if message == "Pobieranie wstrzymane." {
                    let _ = self.set(id, "queued", "");
                    return;
                }
                if message == "Anulowano." {
                    return;
                }
                let attempts: i64 = self
                    .catalog
                    .db()
                    .and_then(|db| {
                        Ok(db.query_row(
                            "UPDATE downloads SET attempts=attempts+1 WHERE track_id=?1 RETURNING attempts",
                            [id],
                            |r| r.get(0),
                        )?)
                    })
                    .unwrap_or(MAX_ATTEMPTS);
                // Lost connections are retried (the partial file is resumed when possible).
                let final_error = message.starts_with("Brak miejsca") || attempts >= MAX_ATTEMPTS;
                let _ = self.set(id, if final_error { "failed" } else { "queued" }, &message);
                if !final_error {
                    std::thread::sleep(Duration::from_secs(5));
                }
            }
        }
    }

    fn fetch(&self, id: &str) -> Result<()> {
        // Still wanted? (cancelled while queued)
        let wanted: bool = self.catalog.db()?.query_row("SELECT EXISTS(SELECT 1 FROM downloads WHERE track_id=?1)", [id], |r| r.get(0))?;
        if !wanted {
            return Ok(());
        }
        let location: Option<(String, String, String, i64, String, String)> = self
            .catalog
            .db()?
            .query_row(
                "SELECT s.id,s.kind,l.path,l.size,l.modified,l.display_name FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1 AND s.kind IN ('smb','webdav','subsonic') ORDER BY l.available DESC,CASE s.kind WHEN 'smb' THEN 0 WHEN 'subsonic' THEN 1 ELSE 2 END LIMIT 1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
            )
            .optional()?;
        let Some((source, kind, path, size, version, name)) = location else {
            bail!("Utwór nie ma już źródła sieciowego.");
        };
        let ext = Path::new(&name)
            .extension()
            .and_then(|e| e.to_str())
            .filter(|e| e.len() <= 8 && e.chars().all(|c| c.is_ascii_alphanumeric()))
            .map(|e| format!(".{}", e.to_lowercase()))
            .unwrap_or_default();
        let target = self.dir.join(format!("{id}{ext}"));
        let partial = self.dir.join(format!("{id}{ext}.part"));
        let marker = self.dir.join(format!("{id}{ext}.part.json"));
        // A partial file of another version of the source file is never continued.
        let resumable = fs::read_to_string(&marker).ok().is_some_and(|v| v == version) && partial.is_file();
        if !resumable {
            let _ = fs::remove_file(&partial);
            fs::write(&marker, &version)?;
        }
        let start = if resumable { fs::metadata(&partial)?.len() } else { 0 };
        if let Some(free) = free_space(&self.dir) {
            if size > 0 && free < (size as u64).saturating_sub(start) + MARGIN {
                bail!("Brak miejsca na dysku.");
            }
        }
        self.catalog.db()?.execute("UPDATE downloads SET total=?1,done=?2,version=?3 WHERE track_id=?4", params![size, start as i64, version, id])?;
        let mut out = OpenOptions::new().create(true).append(true).open(&partial)?;
        match kind.as_str() {
            "smb" => {
                let _ = self.catalog.reconnect(&source);
                let mut input = File::open(&path).map_err(|e| anyhow!(crate::smb::io_message(&e)))?;
                input.seek(SeekFrom::Start(start))?;
                self.copy(id, &mut input, &mut out, start)?
            }
            "webdav" => {
                let config = self.catalog.network_settings(&source)?.ok_or_else(|| anyhow!("Brak ustawień źródła."))?;
                let dav = crate::sources::dav(Some(&source), &config)?;
                let url = dav.url(&path)?;
                if start > 0 {
                    let (mut response, ranged) = dav.read(&url, start, (size as u64).saturating_sub(start).max(1), &version)?;
                    if !ranged {
                        // Server ignores Range: start over instead of appending wrong bytes.
                        drop(out);
                        fs::remove_file(&partial)?;
                        out = OpenOptions::new().create(true).append(true).open(&partial)?;
                        self.copy(id, &mut response, &mut out, 0)?
                    } else {
                        self.copy(id, &mut response, &mut out, start)?
                    }
                } else {
                    let mut response = dav.get(&url, &version)?;
                    self.copy(id, &mut response, &mut out, 0)?
                }
            }
            _ => {
                let client = self.catalog.subsonic_client(&source)?;
                // The download API gives the original file, never a conversion.
                let mut response = client.download(&path)?;
                if start > 0 {
                    drop(out);
                    fs::remove_file(&partial)?;
                    out = OpenOptions::new().create(true).append(true).open(&partial)?;
                }
                self.copy(id, &mut response, &mut out, 0)?
            }
        };
        out.flush()?;
        out.sync_all()?;
        drop(out);
        if !self.catalog.db()?.query_row("SELECT EXISTS(SELECT 1 FROM downloads WHERE track_id=?1)", [id], |r| r.get::<_, bool>(0))? {
            let _ = fs::remove_file(&partial);
            let _ = fs::remove_file(&marker);
            return Ok(());
        }
        // Completeness: content-hash tracks must match their id; others their reported size.
        let length = fs::metadata(&partial)?.len();
        let ok = if kind == "smb" {
            hash_file(&partial)? == id
        } else {
            size <= 0 || length == size as u64
        };
        if !ok {
            let _ = fs::remove_file(&partial);
            let _ = fs::remove_file(&marker);
            bail!("Pobrany plik jest niekompletny albo zmienił się na serwerze. Pobieranie zacznie się od nowa.");
        }
        fs::rename(&partial, &target).context("Nie można zapisać pobranego pliku")?;
        let _ = fs::remove_file(&marker);
        let mut db = self.catalog.db()?;
        let tx = db.transaction()?;
        tx.execute("INSERT INTO locations(source_id,path_key,path,track_id,size,modified,seen,available,display_name) VALUES(?1,?2,?3,?4,?5,?6,'download',1,?7) ON CONFLICT(source_id,path_key) DO UPDATE SET track_id=excluded.track_id,size=excluded.size,modified=excluded.modified,available=1",
            params![SOURCE, path_key(&target), target.to_string_lossy(), id, length as i64, version, name])?;
        tx.execute("UPDATE downloads SET state='done',done=?1,total=?1,error='' WHERE track_id=?2", params![length as i64, id])?;
        tx.commit()?;
        Ok(())
    }

    fn copy(&self, id: &str, input: &mut dyn Read, out: &mut File, start: u64) -> Result<u64> {
        let mut buffer = vec![0u8; 256 * 1024];
        let mut done = start;
        let mut last = std::time::Instant::now();
        loop {
            if self.paused.load(Ordering::Relaxed) {
                bail!("Pobieranie wstrzymane.");
            }
            let n = input.read(&mut buffer).map_err(|e| anyhow!("Połączenie przerwane: {e}"))?;
            if n == 0 {
                break;
            }
            if let Err(e) = out.write_all(&buffer[..n]) {
                if e.raw_os_error() == Some(112) || e.raw_os_error() == Some(28) {
                    bail!("Brak miejsca na dysku.");
                }
                return Err(e.into());
            }
            done += n as u64;
            if last.elapsed() > Duration::from_millis(500) {
                last = std::time::Instant::now();
                let state: Option<String> = self.catalog.db()?.query_row("SELECT state FROM downloads WHERE track_id=?1", [id], |r| r.get(0)).optional()?;
                if state.is_none() {
                    bail!("Anulowano.");
                }
                self.catalog.db()?.execute("UPDATE downloads SET done=?1 WHERE track_id=?2", params![done as i64, id])?;
            }
        }
        Ok(done)
    }

    /// Keeps a playlist offline: its tracks download now and new ones later.
    pub fn keep_playlist(&self, playlist: &str, keep: bool, ids: &[String]) -> Result<()> {
        if keep {
            self.catalog.db()?.execute("INSERT OR IGNORE INTO kept_playlists(playlist_id) VALUES(?1)", [playlist])?;
            self.add(ids, &format!("playlist:{playlist}"))?;
        } else {
            self.catalog.db()?.execute("DELETE FROM kept_playlists WHERE playlist_id=?1", [playlist])?;
            // Copies that only this playlist wanted go; user downloads stay.
            let only: Vec<String> = {
                let db = self.catalog.db()?;
                let mut stmt = db.prepare("SELECT track_id FROM downloads WHERE reason=?1")?;
                let rows = stmt.query_map([format!("playlist:{playlist}")], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
                rows
            };
            self.remove(&only)?;
        }
        Ok(())
    }

    pub fn kept_playlists(&self) -> Result<Vec<String>> {
        let db = self.catalog.db()?;
        let mut stmt = db.prepare("SELECT playlist_id FROM kept_playlists")?;
        let rows = stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// New entries of kept playlists are queued (called after edits, syncs and reconnects).
    pub fn refresh_kept(&self, playlists: &[(String, String, Vec<String>)]) -> Result<()> {
        for kept in self.kept_playlists()? {
            if let Some((_, _, ids)) = playlists.iter().find(|p| p.0 == kept) {
                self.add(ids, &format!("playlist:{kept}"))?;
            }
        }
        Ok(())
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}
