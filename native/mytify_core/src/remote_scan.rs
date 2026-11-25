//! Catalog side of HTTP sources (WebDAV): scanning by listing, tags through ranged
//! reads, and opening tracks for playback. Remote tracks get a stable id from their
//! source and server path, because hashing every file over the internet is too costly.

use crate::{
    catalog::{hex, now_ms, riff_text, search_key, Catalog, Progress, Report, AUDIO_EXTENSIONS},
    webdav::{Dav, Entry, RemoteReader},
};
use anyhow::{anyhow, bail, Context, Result};
use lofty::{
    file::{AudioFile, FileType, TaggedFileExt},
    prelude::Accessor,
    probe::Probe,
    tag::ItemKey,
};
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::BufReader,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

/// Stable id of a track that only exists on a remote server.
pub fn remote_id(source: &str, href: &str) -> String {
    hex(Sha256::digest(format!("mytify-remote-v1\0{source}\0{href}").as_bytes()))
}

/// Something the player or a streaming endpoint can read from, local or remote.
pub struct AudioInput {
    pub reader: Box<dyn symphonia::core::io::MediaSource>,
    pub len: u64,
    /// File name, for the format hint and the MIME type.
    pub name: String,
}

fn audio_name(name: &str) -> bool {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| AUDIO_EXTENSIONS.contains(&e.to_lowercase().as_str()))
}

fn skipped_folder(name: &str) -> bool {
    name.starts_with('.') || name.starts_with('#') || name == "@eaDir"
}

impl Catalog {
    fn stream_cache(&self) -> PathBuf {
        self.root.join("stream-cache").join(format!(
            "{}.bin",
            hex(crate::catalog::getrandom_bytes().unwrap_or_default())
        ))
    }

    pub(crate) fn scan_webdav(
        &self,
        source: &crate::catalog::Source,
        generation: &str,
        force: bool,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(Progress),
        report: &mut Report,
    ) -> Result<()> {
        let config = self
            .network_settings(&source.id)?
            .ok_or_else(|| anyhow!("Brak ustawień źródła."))?;
        progress(Progress {
            done: 0,
            total: 0,
            name: format!("Łączenie z {}…", source.name),
        });
        let offline = |catalog: &Catalog, report: &mut Report, e: anyhow::Error| -> Result<()> {
            // Unreachable server: keep the collection, only the state changes.
            catalog
                .db()?
                .execute("UPDATE sources SET state='offline' WHERE id=?", [&source.id])?;
            report.offline_sources += 1;
            report.error(format!("{}: {e}", source.name));
            Ok(())
        };
        let dav = match crate::sources::dav(Some(&source.id), &config) {
            Ok(d) => d,
            Err(e) => return offline(self, report, e),
        };
        let mut files: Vec<Entry> = Vec::new();
        let mut todo = vec![dav.base().clone()];
        let mut complete = true;
        let mut folders = 0usize;
        while let Some(folder) = todo.pop() {
            if cancel.load(Ordering::Relaxed) {
                report.cancelled = true;
                complete = false;
                break;
            }
            folders += 1;
            if folders + files.len() > 200_000 {
                bail!("Wybierz mniejszy folder.");
            }
            match dav.list(&folder) {
                Ok(entries) => {
                    for e in entries {
                        if e.dir {
                            if !skipped_folder(&e.name) {
                                let href = if e.href.ends_with('/') { e.href.clone() } else { format!("{}/", e.href) };
                                todo.push(dav.url(&href)?);
                            }
                        } else if audio_name(&e.name) {
                            files.push(e);
                        } else {
                            report.ignored += 1;
                        }
                    }
                }
                Err(e) if folder == *dav.base() => return offline(self, report, e),
                Err(e) => {
                    complete = false;
                    report.error(format!("{}: {e}", crate::webdav::decoded_name(folder.path())));
                }
            }
            progress(Progress {
                done: 0,
                total: 0,
                name: format!("Przeglądam {}… ({} plików)", source.name, files.len()),
            });
        }
        files.sort_by(|a, b| a.href.cmp(&b.href));
        self.db()?
            .execute("UPDATE sources SET state='scanning' WHERE id=?", [&source.id])?;
        for (i, e) in files.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                complete = false;
                report.cancelled = true;
                break;
            }
            progress(Progress {
                done: i,
                total: files.len(),
                name: e.name.clone(),
            });
            if let Err(error) = self.ingest_remote(&source.id, &dav, e, generation, force, report) {
                complete = false;
                report.error(format!("{}: {error}", e.name));
            }
        }
        if complete && !report.cancelled {
            report.missing += self.db()?.execute(
                "UPDATE locations SET available=0 WHERE source_id=?1 AND seen<>?2 AND available=1",
                params![source.id, generation],
            )? as u32;
        }
        self.db()?.execute(
            "UPDATE sources SET state=?1,last_scan=?2 WHERE id=?3",
            params![if complete && !report.cancelled { "online" } else { "partial" }, now_ms(), source.id],
        )?;
        progress(Progress {
            done: files.len(),
            total: files.len(),
            name: source.name.clone(),
        });
        Ok(())
    }

    fn ingest_remote(
        &self,
        source: &str,
        dav: &Arc<Dav>,
        e: &Entry,
        generation: &str,
        force: bool,
        report: &mut Report,
    ) -> Result<()> {
        let key = e.href.clone();
        let id = remote_id(source, &e.href);
        let prior: Option<(String, i64, String)> = self
            .db()?
            .query_row(
                "SELECT track_id,size,modified FROM locations WHERE source_id=?1 AND path_key=?2",
                params![source, key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if !force {
            if let Some((_, size, version)) = &prior {
                // Same size and ETag (or date): the file is not read again.
                if *size == e.size as i64 && *version == e.version && !version.is_empty() {
                    self.db()?.execute(
                        "UPDATE locations SET available=1,seen=?1 WHERE source_id=?2 AND path_key=?3",
                        params![generation, source, key],
                    )?;
                    report.unchanged += 1;
                    return Ok(());
                }
            }
        }
        let ignored: Option<String> = self
            .db()?
            .query_row("SELECT hash FROM ignored_paths WHERE path_key=?", [&key], |r| r.get(0))
            .optional()?;
        if ignored.as_deref() == Some(id.as_str()) {
            report.ignored += 1;
            return Ok(());
        }
        let url = dav.url(&e.href)?;
        let reader = RemoteReader::new(dav.clone(), url, e.size, e.version.clone(), self.stream_cache());
        let file = Probe::new(BufReader::with_capacity(64 * 1024, reader))
            .guess_file_type()?
            .read()
            .context("Nie można odczytać danych audio")?;
        let properties = file.properties();
        let tag = file.primary_tag().or_else(|| file.first_tag());
        let wav = file.file_type() == FileType::Wav;
        let text = |v: Option<String>| riff_text(v.unwrap_or_default(), wav);
        let mut title = text(tag.and_then(|t| t.title()).map(|t| t.into_owned()));
        if title.is_empty() {
            title = Path::new(&e.name)
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
        }
        let artist = text(tag.and_then(|t| t.artist()).map(|t| t.into_owned()));
        let album = text(tag.and_then(|t| t.album()).map(|t| t.into_owned()));
        let album_artist = text(tag.and_then(|t| t.get_string(ItemKey::AlbumArtist)).map(str::to_owned));
        let cover = match tag.and_then(|t| t.pictures().iter().find(|p| p.data().len() <= 4 * 1024 * 1024)) {
            Some(picture) => {
                let cover = hex(Sha256::digest(picture.data()));
                let target = self.root.join("artwork").join(&cover);
                if !target.exists() {
                    let temporary = target.with_extension("partial");
                    fs::write(&temporary, picture.data())?;
                    fs::rename(temporary, &target)?;
                }
                Some(cover)
            }
            None => None,
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
        let duration = properties.duration().as_millis() as i64;
        let track_no = tag.and_then(|t| t.track()).unwrap_or(0);
        let disc_no = tag.and_then(|t| t.disk()).unwrap_or(0);
        let rate = properties.sample_rate().unwrap_or(0);
        // Lossy formats have no PCM bit depth; lofty reports none for them.
        let depth = properties.bit_depth().unwrap_or(0);
        let mut db = self.db()?;
        let tx = db.transaction()?;
        let exists: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM tracks WHERE id=?)", [&id], |r| r.get(0))?;
        if exists {
            tx.execute("UPDATE tracks SET title=?2,artist=?3,album=?4,album_artist=?5,file_name=?6,format=?7,size=?8,duration_ms=?9,track_number=?10,disc_number=?11,sample_rate=?12,bit_depth=?13,cover=?14 WHERE id=?1",
                params![id,title,artist,album,album_artist,e.name,format,e.size as i64,duration,track_no,disc_no,rate,depth,cover])?;
            crate::metadata::reindex(&tx, &id)?;
        } else {
            tx.execute("INSERT INTO tracks(id,title,artist,album,album_artist,file_name,format,size,duration_ms,track_number,disc_number,sample_rate,bit_depth,added_at,cover,liked) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,0)",
                params![id,title,artist,album,album_artist,e.name,format,e.size as i64,duration,track_no,disc_no,rate,depth,now_ms(),cover])?;
            tx.execute(
                "INSERT INTO tracks_search(track_id,text) VALUES(?1,?2)",
                params![id, search_key(&format!("{title} {artist} {album} {album_artist} {}", e.name))],
            )?;
        }
        tx.execute("INSERT INTO locations(source_id,path_key,path,track_id,size,modified,seen,available,display_name) VALUES(?1,?2,?3,?4,?5,?6,?7,1,?8) ON CONFLICT(source_id,path_key) DO UPDATE SET path=excluded.path,track_id=excluded.track_id,size=excluded.size,modified=excluded.modified,seen=excluded.seen,available=1,display_name=excluded.display_name",
            params![source,key,e.href,id,e.size as i64,e.version,generation,e.name])?;
        tx.commit()?;
        if prior.is_some() {
            report.updated += 1;
        } else {
            report.added += 1;
        }
        Ok(())
    }

    /// Opens a track for reading: a local or SMB file first, a WebDAV copy otherwise.
    pub fn open_audio(&self, id: &str) -> Result<AudioInput> {
        let local = self.audio_path(id);
        if let Ok(path) = &local {
            let file = fs::File::open(path).context("Nie można otworzyć pliku audio")?;
            let len = file.metadata()?.len();
            return Ok(AudioInput {
                reader: Box::new(file),
                len,
                name: path.file_name().unwrap_or_default().to_string_lossy().into_owned(),
            });
        }
        let remote: Vec<(String, String, i64, String, String)> = {
            let db = self.db()?;
            let mut stmt = db.prepare("SELECT l.source_id,l.path,l.size,l.modified,l.display_name FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1 AND s.kind='webdav' ORDER BY l.available DESC")?;
            let rows = stmt
                .query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        let mut last = None;
        for (source, href, size, version, name) in remote {
            let attempt = (|| -> Result<AudioInput> {
                let config = self
                    .network_settings(&source)?
                    .ok_or_else(|| anyhow!("Brak ustawień źródła."))?;
                let dav = crate::sources::dav(Some(&source), &config)?;
                let url = dav.url(&href)?;
                Ok(AudioInput {
                    reader: Box::new(RemoteReader::new(dav, url, size as u64, version, self.stream_cache())),
                    len: size as u64,
                    name,
                })
            })();
            match attempt {
                Ok(input) => return Ok(input),
                Err(e) => last = Some(e),
            }
        }
        match (last, local) {
            (Some(e), _) => bail!("Źródło niedostępne. {e}"),
            (None, Err(e)) => Err(e),
            (None, Ok(_)) => unreachable!(),
        }
    }

    /// Cheap check used when a queue is handed to another device.
    pub fn check_playable(&self, id: &str) -> Result<()> {
        if self.audio_path(id).is_ok() {
            return Ok(());
        }
        let remote: bool = self.db()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM locations l JOIN sources s ON s.id=l.source_id WHERE l.track_id=?1 AND s.kind='webdav')",
            [id],
            |r| r.get(0),
        )?;
        if remote {
            Ok(())
        } else {
            bail!("Plik jest niedostępny. Podłącz źródło i wykonaj ponowny skan.")
        }
    }
}
