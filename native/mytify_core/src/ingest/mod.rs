#[cfg(all(windows, feature = "desktop"))]
mod app_capture;
#[cfg(windows)]
mod capture;
pub mod cd;
pub mod encode;
pub mod loudness;
pub mod verify;
pub mod wav;
use crate::catalog::{getrandom_bytes, hex, Catalog};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
        Arc, Mutex,
    },
};
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub running: bool,
    pub recording: bool,
    pub stage: String,
    pub session: String,
    pub rate: u32,
    pub channels: u16,
    pub input_format: String,
    pub frames: u64,
    pub peak: f32,
    /// Peak per input channel since the last snapshot (one entry for mono inputs).
    pub peaks: Vec<f32>,
    pub clips: u64,
    pub dropouts: u64,
    pub markers: Vec<u64>,
    pub done: u64,
    pub total: u64,
    pub files: Vec<String>,
    pub warnings: Vec<String>,
    pub error: Option<String>,
    /// What the job is doing now, for people ("Sprawdzanie płyty w AccurateRip").
    pub step: String,
    pub paused: bool,
    /// Why a recording ended by itself ("silence"), empty otherwise.
    pub ended: String,
    /// CD: read offset used and where it came from.
    pub offset: Option<i32>,
    pub offset_source: String,
    pub verdicts: Vec<verify::TrackVerdict>,
    pub disc_check: Option<Value>,
    /// Folder with the result (CD import, export).
    pub folder: String,
    /// CD import: track being read, and where it starts and how long it is in `done` units.
    pub track: u32,
    pub track_from: u64,
    pub track_len: u64,
    /// Whole job, 0..1, live (start of the current part plus how far it got).
    pub progress: Option<f64>,
    /// Current part (track being saved, file being copied), 0..1.
    pub part: f64,
    /// Share of the whole job the current part takes.
    #[serde(skip)]
    pub span: f64,
}
pub struct Signals {
    pub stop: AtomicBool,
    pub frames: AtomicU64,
    pub peak: AtomicU32,
    pub peaks: [AtomicU32; 2],
    pub clips: AtomicU64,
    pub dropped: AtomicU64,
    pub failed: AtomicBool,
    pub paused: AtomicBool,
    /// Current part done, f32 bits (encoder, copy).
    pub part: AtomicU32,
}
impl Default for Signals {
    fn default() -> Self {
        Self {
            stop: AtomicBool::new(false),
            frames: AtomicU64::new(0),
            peak: AtomicU32::new(0),
            peaks: [AtomicU32::new(0), AtomicU32::new(0)],
            clips: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            failed: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            part: AtomicU32::new(0),
        }
    }
}
pub struct Ingest {
    pub state: Arc<Mutex<Status>>,
    pub signals: Arc<Signals>,
    pub catalog: Arc<Catalog>,
    busy: Arc<AtomicBool>,
}
impl Ingest {
    pub fn new(catalog: Arc<Catalog>) -> Self {
        Self {
            state: Default::default(),
            signals: Default::default(),
            catalog,
            busy: Default::default(),
        }
    }
    fn clone_handle(&self) -> Self {
        Self {
            state: self.state.clone(),
            signals: self.signals.clone(),
            catalog: self.catalog.clone(),
            busy: self.busy.clone(),
        }
    }
    pub fn snapshot(&self) -> Value {
        let mut s = self.state.lock().unwrap().clone();
        if let Some(base) = s.progress {
            s.part = (f32::from_bits(self.signals.part.load(Ordering::Acquire)) as f64).clamp(0.0, 1.0);
            s.progress = Some((base + s.span * s.part).clamp(0.0, 1.0));
        } else if s.stage == "ripping" && s.total > 0 {
            // Reading is most of a CD import; saving into the library is the rest.
            s.progress = Some(READING * s.done as f64 / s.total as f64);
        }
        if s.stage == "ripping" {
            // Levels of what is being read, for the import view.
            s.peaks = self.signals.peaks.iter().map(|p| f32::from_bits(p.swap(0, Ordering::AcqRel))).collect();
        }
        if s.stage == "recording" || s.stage == "monitor" {
            s.frames = self.signals.frames.load(Ordering::Acquire);
            s.peak = f32::from_bits(self.signals.peak.swap(0, Ordering::AcqRel));
            s.peaks = self.signals.peaks[..(s.channels as usize).min(2)]
                .iter()
                .map(|p| f32::from_bits(p.swap(0, Ordering::AcqRel)))
                .collect();
            s.clips = self.signals.clips.load(Ordering::Acquire);
            s.dropouts = self.signals.dropped.load(Ordering::Acquire);
            s.paused = self.signals.paused.load(Ordering::Acquire);
        }
        serde_json::to_value(s).unwrap()
    }
    fn begin(&self, stage: &str) -> Result<()> {
        if self.busy.swap(true, Ordering::AcqRel) {
            bail!("Zakończ bieżący import lub nagranie")
        };
        self.signals.stop.store(false, Ordering::Release);
        self.signals.failed.store(false, Ordering::Release);
        self.signals.paused.store(false, Ordering::Release);
        self.signals.part.store(0, Ordering::Release);
        self.signals.frames.store(0, Ordering::Release);
        self.signals.peak.store(0, Ordering::Release);
        for p in &self.signals.peaks {
            p.store(0, Ordering::Release);
        }
        self.signals.clips.store(0, Ordering::Release);
        self.signals.dropped.store(0, Ordering::Release);
        *self.state.lock().unwrap() = Status {
            running: true,
            stage: stage.into(),
            ..Default::default()
        };
        Ok(())
    }
    fn job(
        &self,
        stage: &str,
        run: impl FnOnce(&Self) -> Result<()> + Send + 'static,
    ) -> Result<Value> {
        self.begin(stage)?;
        let this = self.clone_handle();
        std::thread::spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&this)));
            let mut s = this.state.lock().unwrap();
            s.running = false;
            s.recording = false;
            if s.stage == "recording" || s.stage == "monitor" {
                s.peak = f32::from_bits(this.signals.peak.load(Ordering::Acquire));
                s.clips = this.signals.clips.load(Ordering::Acquire);
                s.dropouts = this.signals.dropped.load(Ordering::Acquire);
            }
            match result {
                Ok(Ok(())) => {
                    s.stage = if this.signals.stop.load(Ordering::Acquire) {
                        "cancelled"
                    } else {
                        "finished"
                    }
                    .into()
                }
                Ok(Err(e)) if e.to_string().starts_with("Anulowano eksport") => {
                    s.stage = "cancelled".into();
                }
                Ok(Err(e)) => {
                    s.stage = "error".into();
                    s.error = Some(e.to_string());
                }
                Err(_) => {
                    s.stage = "error".into();
                    s.error=Some("Operacja została przerwana. Zachowano ukończone pliki i nagrania do odzyskania.".into());
                }
            }
            let _ = std::fs::write(
                this.catalog.root.join("last-ingest-report.json"),
                serde_json::to_vec_pretty(&*s).unwrap_or_default(),
            );
            this.busy.store(false, Ordering::Release);
        });
        Ok(self.snapshot())
    }
    fn root(&self) -> PathBuf {
        self.catalog.root.join("recordings")
    }
    fn session_path(&self, id: &str) -> Result<PathBuf> {
        if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("Nieprawidłowa sesja nagrania")
        };
        Ok(self.root().join(id))
    }
    pub fn command(&self, v: Value) -> Result<Value> {
        match v["action"].as_str().unwrap_or("") {
            "state" => Ok(self.snapshot()),
            "stop" => {
                self.signals.stop.store(true, Ordering::Release);
                Ok(self.snapshot())
            }
            "pause" => {
                let s = self.state.lock().unwrap();
                if !s.recording {
                    bail!("Pauza działa podczas nagrania")
                };
                self.signals.paused.store(v["value"].as_bool().unwrap_or(true), Ordering::Release);
                drop(s);
                Ok(self.snapshot())
            }
            "media" => {
                #[cfg(windows)]
                {
                    Ok(json!(cd::device::drives()
                        .into_iter()
                        .map(|id| {
                            let media = cd::device::Drive::open(&id).map(|d| d.has_media()).unwrap_or(false);
                            json!({"id": id, "media": media})
                        })
                        .collect::<Vec<_>>()))
                }
                #[cfg(not(windows))]
                {
                    Ok(json!([]))
                }
            }
            "eject" => {
                #[cfg(windows)]
                {
                    if self.busy.load(Ordering::Acquire) {
                        bail!("Zakończ bieżący import")
                    };
                    cd::device::Drive::open(v["drive"].as_str().unwrap_or(""))?.eject()?;
                    Ok(json!({"ok": true}))
                }
                #[cfg(not(windows))]
                {
                    bail!("Wysuwanie płyty działa w wersji Windows")
                }
            }
            "offsets" => Ok(json!(self.saved_offsets())),
            "waveform" => {
                let path = self.session_path(v["id"].as_str().unwrap_or(""))?.join("master.wav");
                let points = v["points"].as_u64().unwrap_or(2000).clamp(100, 20000) as usize;
                Ok(json!(waveform(&path, points)?))
            }
            "preview" => {
                let path = self.session_path(v["id"].as_str().unwrap_or(""))?.join("master.wav");
                let at = v["positionMs"].as_u64().unwrap_or(0);
                preview(&path, &self.root().join("preview.wav"), at, v["seconds"].as_f64().unwrap_or(3.0))?;
                Ok(json!({"ok": true}))
            }
            "previewStop" => {
                stop_preview();
                Ok(json!({"ok": true}))
            }
            "openPath" => {
                #[cfg(windows)]
                {
                    let target = PathBuf::from(v["path"].as_str().unwrap_or(""));
                    let root = self.catalog.root.canonicalize()?;
                    let music = import_folder(&self.catalog).and_then(|m| m.canonicalize().ok());
                    let target = target.canonicalize()?;
                    if !(target.starts_with(&root) || music.is_some_and(|m| target.starts_with(m))) || !target.is_dir() {
                        bail!("Ten folder nie należy do Mytify")
                    }
                    std::process::Command::new("explorer.exe").arg(target).spawn()?;
                    Ok(json!({"ok": true}))
                }
                #[cfg(not(windows))]
                {
                    bail!("Folder otworzysz w wersji Windows")
                }
            }
            "mark" => {
                let mut s = self.state.lock().unwrap();
                if !s.recording {
                    bail!("Znaczniki dodajesz podczas nagrania")
                };
                let frame = self.signals.frames.load(Ordering::Acquire);
                let ms = frame * 1000 / s.rate.max(1) as u64;
                if s.markers.len() < 1000 && s.markers.last().is_none_or(|x| ms > *x + 500) {
                    s.markers.push(ms)
                };
                Ok(json!({"positionMs":ms}))
            }
            "folders" => Ok(json!({
                "recordings": self.root(),
                "cd": self.catalog.root.join("cd-imports"),
                "music": import_folder(&self.catalog),
            })),
            "importFolder" => {
                // Opening import also brings covers found since into the music folder.
                let catalog = self.catalog.clone();
                std::thread::spawn(move || write_folder_covers(&catalog));
                Ok(self.import_folder_info())
            }
            "setImportFolder" => {
                let path = v["path"].as_str().map(str::trim).filter(|p| !p.is_empty());
                if let Some(p) = path {
                    if !Path::new(p).is_dir() {
                        bail!("Nie ma takiego folderu albo nie jest dostępny: {p}")
                    }
                }
                crate::settings::set(&self.catalog, IMPORT_FOLDER, path)?;
                let catalog = self.catalog.clone();
                std::thread::spawn(move || write_folder_covers(&catalog));
                Ok(self.import_folder_info())
            }
            "relocate" => {
                if import_folder(&self.catalog).is_none() {
                    bail!("Najpierw wybierz folder na muzykę")
                }
                self.job("moving", move |s| s.relocate())
            }
            "openFolder" => {
                #[cfg(windows)]
                {
                    std::fs::create_dir_all(self.root())?;
                    std::process::Command::new("explorer.exe")
                        .arg(self.root())
                        .spawn()?;
                    Ok(json!({"ok":true}))
                }
                #[cfg(not(windows))]
                {
                    bail!("Folder nagrań otworzysz w wersji Windows")
                }
            }
            "apps" => {
                #[cfg(all(windows, feature = "desktop"))]
                {
                    app_capture::apps()
                }
                #[cfg(not(all(windows, feature = "desktop")))]
                {
                    Ok(json!([]))
                }
            }
            "inputs" => {
                #[cfg(windows)]
                {
                    capture::inputs()
                }
                #[cfg(not(windows))]
                {
                    Ok(json!([]))
                }
            }
            "drives" => {
                #[cfg(windows)]
                {
                    Ok(json!(cd::device::drives()
                        .into_iter()
                        .map(|id| json!({"id": id, "name": cd::device::name(&id)}))
                        .collect::<Vec<_>>()))
                }
                #[cfg(not(windows))]
                {
                    Ok(json!([]))
                }
            }
            "toc" => {
                #[cfg(windows)]
                {
                    let id = v["drive"].as_str().unwrap_or("");
                    let d = cd::device::Drive::open(id)?;
                    let toc = d.toc(id)?;
                    let mut out = serde_json::to_value(&toc)?;
                    out["cdText"] = json!(d.cd_text(toc.tracks.len()));
                    out["driveName"] = json!(cd::device::name(id));
                    out["offset"] = json!(cd::device::name(id).and_then(|n| self.saved_offsets().get(&n).copied()));
                    Ok(out)
                }
                #[cfg(not(windows))]
                {
                    bail!("Import Audio CD jest dostępny w wersji Windows")
                }
            }
            "monitor" | "record" => {
                #[cfg(windows)]
                {
                    let record = v["action"] == "record";
                    let args = v.clone();
                    self.job(if record { "recording" } else { "monitor" }, move |s| {
                        capture::run(s, &args, record)
                    })
                }
                #[cfg(not(windows))]
                {
                    bail!("Nagrywanie jest dostępne w wersji Windows")
                }
            }
            "rip" => {
                #[cfg(windows)]
                {
                    self.job("ripping", move |s| s.rip(&v))
                }
                #[cfg(not(windows))]
                {
                    bail!("Import Audio CD jest dostępny w wersji Windows")
                }
            }
            "sessions" => {
                std::fs::create_dir_all(self.root())?;
                let mut out = Vec::new();
                for d in std::fs::read_dir(self.root())?.flatten() {
                    let id = d.file_name().to_string_lossy().into_owned();
                    if id.len() != 32 {
                        continue;
                    }
                    let dir = d.path();
                    let master = dir.join("master.wav");
                    let partial = dir.join("master.wav.partial");
                    if master.is_file() || partial.is_file() {
                        let path = if master.is_file() { master } else { partial };
                        let info = wav::Wav::read(&path).ok();
                        let meta = std::fs::read(dir.join("session.json"))
                            .ok()
                            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                            .unwrap_or(json!({}));
                        out.push(json!({"id":id,"path":path,"partial":path.extension().is_some_and(|s|s=="partial"),"rate":info.as_ref().map(|w|w.rate),"channels":info.as_ref().map(|w|w.channels),"durationMs":info.as_ref().map(|w|w.frames()*1000/w.rate as u64),"label":meta["label"],"markers":meta["markers"],"app":meta["app"],"exported":meta["exported"]}));
                    }
                }
                out.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
                Ok(json!(out))
            }
            "recover" => {
                if self.busy.load(Ordering::Acquire) {
                    bail!("Zakończ bieżącą operację")
                };
                let dir = self.session_path(v["id"].as_str().unwrap_or(""))?;
                let partial = dir.join("master.wav.partial");
                let target = dir.join("master.wav");
                if target.exists() {
                    bail!("Nagranie zostało już odzyskane")
                };
                drop(wav::Wav::recover(&partial)?);
                std::fs::rename(partial, target)?;
                Ok(json!({"ok":true}))
            }
            "align" => {
                if self.busy.load(Ordering::Acquire) {
                    bail!("Zakończ bieżącą operację")
                };
                let path = self.session_path(v["id"].as_str().unwrap_or(""))?.join("master.wav");
                let durations: Vec<u64> = serde_json::from_value(v["durations"].clone())?;
                if durations.len() < 2 || durations.len() > 100 {
                    bail!("Wybierz co najmniej dwa utwory z listy")
                }
                Ok(json!(align(&path, &durations)?))
            }
            "analyze" => {
                if self.busy.load(Ordering::Acquire) {
                    bail!("Zakończ bieżącą operację")
                };
                let path = self
                    .session_path(v["id"].as_str().unwrap_or(""))?
                    .join("master.wav");
                Ok(json!(silences(&path)?))
            }
            "export" => {
                self.session_path(v["id"].as_str().unwrap_or(""))?;
                self.job("exporting", move |s| s.export(&v))
            }
            _ => bail!("Nieznana operacja importu"),
        }
    }
    fn step(&self, text: &str) {
        self.state.lock().unwrap().step = text.into();
    }
    /// The next part of the job starts at `base` of the whole and takes `span` of it.
    fn phase(&self, base: f64, span: f64) {
        self.signals.part.store(0, Ordering::Release);
        let mut s = self.state.lock().unwrap();
        s.progress = Some(base);
        s.span = span;
    }
    /// How far the current part got, 0..1.
    fn part(&self, value: f64) {
        self.signals.part.store((value as f32).to_bits(), Ordering::Release);
    }
    fn offsets_file(&self) -> PathBuf {
        self.catalog.root.join("drive-offsets.json")
    }
    /// Read offsets found or set per drive model.
    pub fn saved_offsets(&self) -> std::collections::BTreeMap<String, i32> {
        std::fs::read(self.offsets_file())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
#[cfg_attr(not(windows), allow(dead_code))]
    fn save_offset(&self, drive: &str, offset: i32) -> Result<()> {
        let mut all = self.saved_offsets();
        all.insert(drive.into(), offset);
        std::fs::write(self.offsets_file(), serde_json::to_vec_pretty(&all)?)?;
        Ok(())
    }
    fn export(&self, v: &Value) -> Result<()> {
        let dir = self.session_path(v["id"].as_str().unwrap_or(""))?;
        let master = dir.join("master.wav");
        let w = wav::Wav::read(&master)?;
        let duration = w.frames();
        let rate = w.rate;
        drop(w);
        let marks: Vec<u64> = serde_json::from_value(v["markers"].clone())?;
        let mut bounds = boundaries(&marks, rate, duration)?;
        // App recordings: the last track ends at its known length, not with what the
        // app played after the album.
        if let Some(end) = v["endMs"].as_u64().map(|ms| ms * rate as u64 / 1000) {
            let n = bounds.len();
            if n >= 2 && end > bounds[n - 2] + rate as u64 && end < bounds[n - 1] {
                bounds[n - 1] = end;
            }
        }
        let titles: Vec<String> = serde_json::from_value(v["titles"].clone())?;
        if titles.len() != bounds.len() - 1 {
            bail!("Nadaj tytuł każdemu utworowi")
        };
        let artists: Vec<String> = serde_json::from_value(v["artists"].clone()).unwrap_or_default();
        let restore = encode::Restore::from_json(&v["restore"])?;
        // A recording of a lossy stream (an app) is kept as MP3 only: FLAC would only
        // make it look lossless.
        let mp3_only = v["mp3Only"].as_bool().unwrap_or(false);
        let mp3 = mp3_only || v["mp3"].as_bool().unwrap_or(false);
        let kbps = if v["mp3Kbps"].as_u64() == Some(320) { 320 } else { 192 };
        // Side B continues the numbering of side A.
        let first = v["firstTrack"].as_u64().unwrap_or(1).clamp(1, 99) as usize;
        let dest = self.album_dest(v, dir.join(format!("export-{}", hex(getrandom_bytes()?))))?;
        if mp3 && !mp3_only {
            std::fs::create_dir_all(dest.join("MP3"))?;
        }
        let cover = self.cover_bytes(v);
        if let Some(c) = &cover {
            write_new(&dest.join("cover.jpg"), c)?;
        }
        {
            let mut s = self.state.lock().unwrap();
            s.total = titles.len() as u64;
            s.folder = dest.to_string_lossy().into_owned();
            s.step = if restore.active() { "Obróbka kopii i zapis".into() } else { "Zapis utworów".into() };
        }
        let mut made: Vec<(PathBuf, Option<PathBuf>, loudness::Loudness)> = Vec::new();
        let mut clicks = 0;
        let all = (bounds[bounds.len() - 1] - bounds[0]).max(1) as f64;
        for (i, b) in bounds.windows(2).enumerate() {
            if self.signals.stop.load(Ordering::Acquire) {
                break;
            }
            self.phase(ENCODING * (b[0] - bounds[0]) as f64 / all, ENCODING * (b[1] - b[0]) as f64 / all);
            let ext = if mp3_only { "mp3" } else { "flac" };
            let name = free_stem(&track_stem(v, i + first, &titles[i]), |n| vec![dest.join(format!("{n}.{ext}")), dest.join("MP3").join(format!("{n}.mp3"))]);
            let out = dest.join(format!("{name}.{ext}"));
            let partial = out.with_extension(if mp3_only { "mp3.partial" } else { "flac.partial" });
            let mp3_out = (mp3 && !mp3_only).then(|| dest.join("MP3").join(format!("{name}.mp3")));
            let e = encode::encode(
                &master,
                b[0],
                b[1],
                &encode::Outputs {
                    flac: (!mp3_only).then_some(partial.as_path()),
                    mp3: if mp3_only { Some(partial.as_path()) } else { mp3_out.as_deref() },
                    mp3_kbps: kbps,
                    restore: restore.clone(),
                    progress: Some(&self.signals.part),
                },
                &self.signals.stop,
            )?;
            clicks += e.clicks;
            std::fs::rename(&partial, &out)?;
            made.push((out.clone(), mp3_out, e.loudness));
            let mut s = self.state.lock().unwrap();
            s.files.push(out.to_string_lossy().into_owned());
            s.done = (i + 1) as u64;
        }
        if restore.declick && clicks > 0 {
            self.state.lock().unwrap().warnings.push(format!("Usunięto trzaski: {clicks}."));
        }
        self.step("Opis utworów i ReplayGain");
        let total = v["totalTracks"].as_u64().map(|t| t as u32).unwrap_or((first - 1 + titles.len()) as u32);
        let tags: Vec<TagInfo> = made
            .iter()
            .enumerate()
            .map(|(i, _)| TagInfo::from_request(v, &titles[i], artists.get(i).map(String::as_str), (i + first) as u32, total))
            .collect();
        self.finish_tracks(&made, tags, cover.as_deref(), ENCODING)?;
        // The recording remembers it is in the library, so the app does not offer it again as new.
        if !self.signals.stop.load(Ordering::Acquire) {
            let meta_path = dir.join("session.json");
            if let Some(mut meta) = std::fs::read(&meta_path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
                let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                meta["exported"] = json!({"at": at, "tracks": made.len(), "folder": dest.to_string_lossy()});
                let _ = std::fs::write(&meta_path, serde_json::to_vec_pretty(&meta)?);
            }
        }
        Ok(())
    }
    /// Folder for a new album: `Artist\Album (year)` in the music folder the user chose,
    /// else `fallback` in the app data.
    fn album_dest(&self, v: &Value, fallback: PathBuf) -> Result<PathBuf> {
        let Some(root) = import_folder(&self.catalog) else {
            std::fs::create_dir_all(&fallback)?;
            return Ok(fallback);
        };
        if !root.is_dir() {
            bail!("Folder na muzykę jest niedostępny: {}. Sprawdź połączenie z NAS albo wybierz inny folder.", root.display())
        }
        let artists: Vec<String> = serde_json::from_value(v["artists"].clone()).unwrap_or_default();
        let distinct = artists.iter().filter(|a| !a.trim().is_empty()).collect::<std::collections::BTreeSet<_>>().len();
        let artist = v["artist"].as_str().unwrap_or("").trim();
        let artist = if artist.is_empty() && distinct > 1 { "Różni wykonawcy" } else { artist };
        let dest = album_path(&root, artist, v["album"].as_str().unwrap_or(""), v["date"].as_str().unwrap_or(""));
        std::fs::create_dir_all(&dest)?;
        Ok(dest)
    }
    /// The music folder, whether it is reachable and in the library, and how many
    /// albums made earlier still sit in the app data.
    fn import_folder_info(&self) -> Value {
        let folder = import_folder(&self.catalog);
        let available = folder.as_ref().is_some_and(|f| f.is_dir());
        let source = folder
            .as_ref()
            .filter(|_| available)
            .and_then(|f| self.catalog.source_containing(f).ok().flatten());
        json!({
            "path": folder,
            "available": available,
            "inLibrary": source.is_some(),
            "stored": self.stored_albums().len(),
        })
    }
    /// Albums made before a music folder was chosen, still in the app data.
    fn stored_albums(&self) -> Vec<PathBuf> {
        let dirs = |d: &Path| -> Vec<PathBuf> {
            std::fs::read_dir(d).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()
        };
        let mut out = Vec::new();
        for session in dirs(&self.root()) {
            out.extend(dirs(&session).into_iter().filter(|e| e.file_name().is_some_and(|n| n.to_string_lossy().starts_with("export-"))));
        }
        out.extend(dirs(&self.catalog.root.join("cd-imports")));
        out.retain(|d| !audio_files(d).is_empty());
        out.sort();
        out
    }
    /// Moves albums from the app data into the music folder layout: copies and checks
    /// every file, points the library at the copies, then removes the app's own copy.
    fn relocate(&self) -> Result<()> {
        let root = import_folder(&self.catalog).ok_or_else(|| anyhow!("Najpierw wybierz folder na muzykę"))?;
        if !root.is_dir() {
            bail!("Folder na muzykę jest niedostępny: {}", root.display())
        }
        let albums = self.stored_albums();
        {
            let mut s = self.state.lock().unwrap();
            s.total = albums.len() as u64;
            s.step = "Przenoszenie albumów".into();
        }
        for (i, dir) in albums.iter().enumerate() {
            if self.signals.stop.load(Ordering::Acquire) {
                break;
            }
            let audio = audio_files(dir);
            let (artist, album, date) = album_tags(&audio[0]);
            self.step(&format!("{artist} / {album}"));
            let dest = album_path(&root, &artist, &album, &date);
            std::fs::create_dir_all(&dest)?;
            let mut old = Vec::new();
            let mut new = Vec::new();
            // Copying is the first half of an album, the library check the second.
            let share = 1.0 / albums.len() as f64;
            self.phase(i as f64 * share, share / 2.0);
            let files = files_below(dir);
            let bytes = files.iter().map(|(f, _)| std::fs::metadata(f).map(|m| m.len()).unwrap_or(0)).sum::<u64>().max(1);
            let mut copied = 0u64;
            for (from, rel) in files {
                let to = dest.join(rel.parent().unwrap_or(Path::new(""))).join(dashed(&rel.file_name().unwrap_or_default().to_string_lossy()));
                let name = to.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
                if name == "cover.jpg" && to.exists() {
                    continue;
                }
                let to = free_path(to);
                copy_checked(&from, &to, |n| self.part((copied + n) as f64 / bytes as f64))?;
                copied += std::fs::metadata(&to).map(|m| m.len()).unwrap_or(0);
                if is_audio(&from) && !crate::catalog::mp3_copy(&to) {
                    old.push(from);
                    new.push(to);
                }
            }
            self.phase(i as f64 * share + share / 2.0, share / 2.0);
            self.catalog.add_files(&new, |k, n| self.part(k as f64 / n.max(1) as f64))?;
            self.catalog.forget_paths(&old)?;
            // The recording notes where its album went.
            if let Some(session) = dir.parent().map(|p| p.join("session.json")).filter(|p| p.is_file()) {
                if let Some(mut meta) = std::fs::read(&session).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
                    if meta["exported"].is_object() {
                        meta["exported"]["folder"] = json!(dest.to_string_lossy());
                        let _ = std::fs::write(&session, serde_json::to_vec_pretty(&meta)?);
                    }
                }
            }
            // Only the app's own copy in its data folder is removed, after the check.
            std::fs::remove_dir_all(dir)?;
            self.phase((i + 1) as f64 * share, 0.0);
            let _ = write_folder_covers(&self.catalog);
            let mut s = self.state.lock().unwrap();
            s.done = (i + 1) as u64;
            s.files.push(dest.to_string_lossy().into_owned());
            s.folder = root.to_string_lossy().into_owned();
        }
        Ok(())
    }
    /// Cover chosen in the app (artwork hash), if any.
    fn cover_bytes(&self, v: &Value) -> Option<Vec<u8>> {
        let hash = v["cover"].as_str()?;
        let path = self.catalog.artwork_path(hash).ok()?;
        std::fs::read(path).ok()
    }
    /// ReplayGain for every track and the album, final tags, then the library scan.
    fn finish_tracks(
        &self,
        made: &[(PathBuf, Option<PathBuf>, loudness::Loudness)],
        mut tags: Vec<TagInfo>,
        cover: Option<&[u8]>,
        base: f64,
    ) -> Result<()> {
        // Tags (files rewritten, possibly on a NAS), then the library (files read again).
        let half = (1.0 - base) / 2.0;
        self.step("Opis utworów i ReplayGain");
        self.phase(base, half);
        let mut all = Vec::new();
        let mut album_peak: f64 = 0.0;
        for (_, _, l) in made {
            all.extend_from_slice(&l.blocks);
            album_peak = album_peak.max(l.peak);
        }
        let album = loudness::integrated(&all).map(loudness::gain);
        for (i, ((flac, mp3, l), t)) in made.iter().zip(tags.iter_mut()).enumerate() {
            self.part(i as f64 / made.len() as f64);
            t.gain = loudness::integrated(&l.blocks).map(|g| (loudness::gain(g), l.peak));
            t.album_gain = album.map(|g| (g, album_peak));
            write_tags(flac, t, cover)?;
            if let Some(m) = mp3 {
                write_tags(m, t, cover)?;
            }
        }
        self.step("Dodawanie do biblioteki");
        self.phase(base + half, half);
        self.catalog.add_files(&made.iter().map(|(f, _, _)| f.clone()).collect::<Vec<_>>(), |i, n| self.part(i as f64 / n.max(1) as f64))?;
        let _ = write_folder_covers(&self.catalog);
        self.phase(1.0, 0.0);
        Ok(())
    }
    /// Reads `count` stereo samples starting at sample `from` (may be negative or past
    /// the lead-out after offset correction; those parts are silence).
#[cfg_attr(not(windows), allow(dead_code))]
    fn read_samples(
        &self,
        reader: &impl cd::Reader,
        leadout: u32,
        from: i64,
        count: u64,
        retried: &mut Vec<u32>,
        mut sink: impl FnMut(&[u8]) -> Result<()>,
    ) -> Result<()> {
        let spsec = verify::SAMPLES_PER_SECTOR as i64;
        let end = from + count as i64;
        let mut s = from;
        while s < end {
            if self.signals.stop.load(Ordering::Acquire) {
                return Ok(());
            }
            let sector = s.div_euclid(spsec);
            let n = ((end - sector * spsec + spsec - 1) / spsec).clamp(1, 16);
            let mut bytes = vec![0u8; n as usize * 2352];
            let lo = sector.max(0);
            let hi = (sector + n).min(leadout as i64);
            if lo < hi {
                let (b, r) = cd::verified_chunk(|l, k| reader.read(l, k), lo as u32, (hi - lo) as u32)?;
                retried.extend(r);
                let at = (lo - sector) as usize * 2352;
                bytes[at..at + b.len()].copy_from_slice(&b);
            }
            let skip = (s - sector * spsec) as usize;
            let take = ((n * spsec) as usize - skip).min((end - s) as usize);
            let chunk = &bytes[skip * 4..(skip + take) * 4];
            let mut per = [0u16; 2];
            for (i, x) in chunk.chunks_exact(2).enumerate().step_by(7) {
                let v = i16::from_le_bytes([x[0], x[1]]).unsigned_abs();
                per[i % 2] = per[i % 2].max(v);
            }
            for (slot, v) in self.signals.peaks.iter().zip(per) {
                slot.fetch_max((v as f32 / 32768.0).to_bits(), Ordering::Relaxed);
            }
            sink(chunk)?;
            s += take as i64;
            self.state.lock().unwrap().done += n as u64;
        }
        Ok(())
    }
    #[cfg(windows)]
    fn rip(&self, v: &Value) -> Result<()> {
        let drive = v["drive"].as_str().unwrap_or("");
        let reader = cd::device::Drive::open(drive)?;
        let toc = reader.toc(drive)?;
        let drive_name = cd::device::name(drive).unwrap_or_else(|| drive.to_string());
        self.step("Sprawdzanie płyty w AccurateRip i CTDB");
        let db = verify::lookup(&toc);
        self.rip_with(&reader, toc, &drive_name, db, v)
    }
    /// The rip itself, independent of the drive API (tested with a simulated disc).
#[cfg_attr(not(windows), allow(dead_code))]
    fn rip_with(&self, reader: &impl cd::Reader, toc: cd::Toc, drive_name: &str, db: verify::Databases, v: &Value) -> Result<()> {
        if v["discId"] != toc.disc_id {
            bail!("Płyta zmieniła się. Odczytaj listę ścieżek ponownie.")
        };
        let titles: Vec<String> = serde_json::from_value(v["titles"].clone())?;
        if titles.len() != toc.tracks.len() {
            bail!("Nieprawidłowa liczba tytułów")
        };
        let artists: Vec<String> = serde_json::from_value(v["artists"].clone()).unwrap_or_default();
        // Optional list of track numbers to import; all tracks when absent.
        let chosen: Option<Vec<u8>> = serde_json::from_value(v["tracks"].clone()).ok();
        let wanted = |n: u8| chosen.as_ref().is_none_or(|c| c.contains(&n));
        if !toc.tracks.iter().any(|t| wanted(t.number)) {
            bail!("Zaznacz co najmniej jeden utwór")
        };
        let whole = toc.tracks.iter().all(|t| wanted(t.number));
        let mp3 = v["mp3"].as_bool().unwrap_or(false);
        let spsec = verify::SAMPLES_PER_SECTOR;
        let dest = self.album_dest(v, self.catalog.root.join("cd-imports").join(hex(getrandom_bytes()?)))?;
        if mp3 {
            std::fs::create_dir_all(dest.join("MP3"))?;
        }
        // Raw tracks are read into the app folder, never onto the NAS.
        let work = self.catalog.root.join("cd-work");
        std::fs::create_dir_all(&work)?;
        let cover = self.cover_bytes(v);
        if let Some(c) = &cover {
            write_new(&dest.join("cover.jpg"), c)?;
        }
        self.state.lock().unwrap().folder = dest.to_string_lossy().into_owned();
        for e in &db.errors {
            self.state.lock().unwrap().warnings.push(format!("Weryfikacja online: {e}"));
        }
        self.state.lock().unwrap().disc_check =
            Some(json!({"accuraterip": db.accuraterip_entries, "ctdb": db.ctdb_entries, "errors": db.errors}));

        // Read offset: chosen by the user, remembered for this drive, or found now.
        let mut log = Vec::<String>::new();
        let (offset, source) = if let Some(o) = verify::parse_offset(&v["offset"])? {
            (o, "ustawione ręcznie")
        } else if let Some(o) = self.saved_offsets().get(drive_name) {
            (*o, "zapamiętane dla napędu")
        } else if !db.accuraterip.is_empty() {
            self.step("Ustalanie przesunięcia odczytu napędu");
            let n = toc.tracks.len();
            let mut order: Vec<usize> = (0..n)
                .filter(|i| db.accuraterip.iter().any(|r| r.tracks.get(*i).is_some_and(|(c, _)| *c > 0)))
                .collect();
            // Short middle tracks first: quick to read and free of the disc edge rules.
            order.sort_by_key(|i| {
                let t = &toc.tracks[*i];
                let edge = *i == 0 || *i + 1 == n;
                (edge, (t.end - t.start).max(75 * 20))
            });
            let mut found = None;
            for i in order.into_iter().take(2) {
                let t = &toc.tracks[i];
                let margin = 4 * spsec;
                let samples = (t.end - t.start) as u64 * spsec;
                let mut padded = Vec::with_capacity(((samples + 2 * margin) * 4) as usize);
                let mut retried = Vec::new();
                self.read_samples(reader, toc.leadout, t.start as i64 * spsec as i64 - margin as i64, samples + 2 * margin, &mut retried, |b| {
                    padded.extend_from_slice(b);
                    Ok(())
                })?;
                if self.signals.stop.load(Ordering::Acquire) {
                    return Ok(());
                }
                found = verify::find_offset(&db, i, i == 0, i + 1 == n, samples, &padded, margin);
                if found.is_some() {
                    break;
                }
            }
            self.state.lock().unwrap().done = 0;
            match found {
                Some(o) => {
                    let _ = self.save_offset(drive_name, o);
                    (o, "wykryte z AccurateRip")
                }
                None => (0, "nieznane (płyta nie pozwoliła go ustalić)"),
            }
        } else {
            (0, "nieznane (płyty nie ma w AccurateRip)")
        };
        {
            let mut s = self.state.lock().unwrap();
            s.offset = Some(offset);
            s.offset_source = source.into();
            s.done = 0;
            s.total = toc
                .tracks
                .iter()
                .filter(|t| wanted(t.number))
                .map(|t| (t.end - t.start) as u64)
                .sum();
        }

        let n = toc.tracks.len();
        let (prefix, suffix) = verify::ctdb_edges(&toc);
        let first_sample = toc.tracks[0].start as u64 * spsec;
        let disc_end = toc.leadout as u64 * spsec;
        let mut disc_crc = verify::Crc32::default();
        let mut made: Vec<(PathBuf, Option<PathBuf>, loudness::Loudness)> = Vec::new();
        let mut tags = Vec::new();
        let mut verdicts = Vec::new();

        // Hidden track before track 1 (HTOA): kept only when it is not silence.
        if toc.tracks[0].start > 0 && whole && v["htoa"].as_bool().unwrap_or(true) {
            self.step("Sprawdzanie ukrytego utworu przed ścieżką 1");
            let samples = toc.tracks[0].start as u64 * spsec;
            let temp = work.join("track-00.wav.partial");
            let mut wav = wav::Wav::create(&temp, 44100, 2, 16)?;
            let mut loud = false;
            let mut retried = Vec::new();
            self.read_samples(reader, toc.leadout, offset as i64, samples, &mut retried, |b| {
                loud |= b.chunks_exact(2).any(|x| i16::from_le_bytes([x[0], x[1]]).unsigned_abs() > 64);
                wav.write(b)
            })?;
            wav.finish()?;
            drop(wav);
            if loud && !self.signals.stop.load(Ordering::Acquire) {
                let name = free_stem(&track_stem(v, 0, "Ukryty utwór"), |n| vec![dest.join(format!("{n}.flac")), dest.join("MP3").join(format!("{n}.mp3"))]);
                let out = dest.join(format!("{name}.flac"));
                let partial = out.with_extension("flac.partial");
                let mp3_out = mp3.then(|| dest.join("MP3").join(format!("{name}.mp3")));
                let e = encode::encode(&temp, 0, samples, &encode::Outputs { flac: Some(&partial), mp3: mp3_out.as_deref(), mp3_kbps: 192, restore: Default::default(), progress: None }, &self.signals.stop)?;
                std::fs::rename(&partial, &out)?;
                made.push((out.clone(), mp3_out, e.loudness));
                tags.push(TagInfo::from_request(v, "Ukryty utwór", None, 0, n as u32));
                self.state.lock().unwrap().files.push(out.to_string_lossy().into_owned());
                log.push(format!("Ukryty utwór przed ścieżką 1: {}, zapisany jako 00.", clock(samples / 44100)));
            }
            let _ = std::fs::remove_file(&temp);
            self.state.lock().unwrap().done = 0;
        }

        for (i, track) in toc.tracks.iter().enumerate() {
            if self.signals.stop.load(Ordering::Acquire) {
                break;
            }
            if !wanted(track.number) {
                continue;
            }
            self.step(&format!("Odczyt ścieżki {} z {}", track.number, n));
            {
                let mut s = self.state.lock().unwrap();
                s.track = track.number as u32;
                s.track_from = s.done;
                s.track_len = (track.end - track.start) as u64;
            }
            let samples = (track.end - track.start) as u64 * spsec;
            let track_from = track.start as u64 * spsec;
            let mut sums = verify::TrackSums::new(samples, i == 0, i + 1 == n, prefix, suffix);
            let temp = work.join(format!("track-{:02}.wav.partial", track.number));
            let mut wav = wav::Wav::create(&temp, 44100, 2, 16)?;
            let mut retried = Vec::new();
            let mut at = track_from;
            self.read_samples(reader, toc.leadout, track_from as i64 + offset as i64, samples, &mut retried, |b| {
                sums.feed(b);
                if whole {
                    // Whole-disc CTDB CRC over the same edges as the database.
                    let frames = (b.len() / 4) as u64;
                    let lo = (first_sample + prefix).max(at);
                    let hi = (disc_end - suffix).min(at + frames);
                    if lo < hi {
                        disc_crc.update(&b[((lo - at) * 4) as usize..((hi - at) * 4) as usize]);
                    }
                    at += frames;
                }
                wav.write(b)
            })?;
            wav.finish()?;
            drop(wav);
            if self.signals.stop.load(Ordering::Acquire) {
                let _ = std::fs::remove_file(&temp);
                break;
            }
            let verdict = verify::judge(&db, i, track.number, &sums, retried.len());
            self.state.lock().unwrap().verdicts.push(verdict.clone());
            verdicts.push(verdict);
            self.step(&format!("Zapis ścieżki {}", track.number));
            let name = free_stem(&track_stem(v, track.number as usize, &titles[i]), |n| vec![dest.join(format!("{n}.flac")), dest.join("MP3").join(format!("{n}.mp3"))]);
            let out = dest.join(format!("{name}.flac"));
            let partial = out.with_extension("flac.partial");
            let mp3_out = mp3.then(|| dest.join("MP3").join(format!("{name}.mp3")));
            let e = encode::encode(&temp, 0, samples, &encode::Outputs { flac: Some(&partial), mp3: mp3_out.as_deref(), mp3_kbps: 192, restore: Default::default(), progress: None }, &self.signals.stop)?;
            std::fs::rename(&partial, &out)?;
            std::fs::remove_file(&temp)?;
            made.push((out.clone(), mp3_out, e.loudness));
            tags.push(TagInfo::from_request(v, &titles[i], artists.get(i).map(String::as_str), track.number as u32, n as u32));
            self.state.lock().unwrap().files.push(out.to_string_lossy().into_owned());
            if !retried.is_empty() {
                self.state.lock().unwrap().warnings.push(format!(
                    "Ścieżka {}: {} sektorów wymagało dodatkowych odczytów.",
                    track.number,
                    retried.len()
                ));
            }
        }
        if made.is_empty() {
            return Ok(());
        }
        self.state.lock().unwrap().track = 0;
        self.step("Opis utworów i ReplayGain");
        self.finish_tracks(&made, tags, cover.as_deref(), READING)?;

        let complete = whole && verdicts.len() == n;
        let disc = complete.then(|| disc_crc.finish());
        let ctdb_disc: u32 = disc.map(|c| db.ctdb.iter().filter(|e| e.crc == c).map(|e| e.confidence).sum()).unwrap_or(0);
        if let Some(c) = disc {
            self.state.lock().unwrap().disc_check = Some(json!({
                "accuraterip": db.accuraterip_entries, "ctdb": db.ctdb_entries,
                "ctdbCrc": format!("{c:08x}"), "ctdbConfidence": ctdb_disc, "errors": db.errors,
            }));
        }
        self.write_cue_and_log(&dest, v, &toc, &titles, &artists, drive_name, offset, source, &verdicts, &made, &db, disc, ctdb_disc, &log)?;
        if v["eject"].as_bool().unwrap_or(false) && !self.signals.stop.load(Ordering::Acquire) {
            let _ = reader.eject();
        }
        Ok(())
    }
#[cfg_attr(not(windows), allow(dead_code))]
    #[allow(clippy::too_many_arguments)]
    fn write_cue_and_log(
        &self,
        dest: &Path,
        v: &Value,
        toc: &cd::Toc,
        titles: &[String],
        artists: &[String],
        drive: &str,
        offset: i32,
        source: &str,
        verdicts: &[verify::TrackVerdict],
        made: &[(PathBuf, Option<PathBuf>, loudness::Loudness)],
        db: &verify::Databases,
        disc: Option<u32>,
        ctdb_disc: u32,
        notes: &[String],
    ) -> Result<()> {
        let q = |s: &str| s.replace('"', "'");
        let album = v["album"].as_str().unwrap_or("");
        let artist = v["artist"].as_str().unwrap_or("");
        let mut cue = String::new();
        cue.push_str(&format!("REM DISCID {:08X}\r\n", verify::cddb_id(toc)));
        if let Some(d) = v["date"].as_str().filter(|d| !d.is_empty()) {
            cue.push_str(&format!("REM DATE {}\r\n", &d[..d.len().min(4)]));
        }
        cue.push_str("REM COMMENT \"Mytify\"\r\n");
        cue.push_str(&format!("PERFORMER \"{}\"\r\nTITLE \"{}\"\r\n", q(artist), q(album)));
        for (path, _, _) in made {
            let file = path.file_name().unwrap().to_string_lossy();
            let number: u8 = file[..2].parse().unwrap_or(0);
            cue.push_str(&format!("FILE \"{}\" WAVE\r\n", q(&file)));
            if number == 0 {
                // Hidden audio before track 1 is that track's index 00.
                cue.push_str("  TRACK 01 AUDIO\r\n    INDEX 00 00:00:00\r\n");
                continue;
            }
            let i = toc.tracks.iter().position(|t| t.number == number).unwrap_or(0);
            cue.push_str(&format!("  TRACK {number:02} AUDIO\r\n    TITLE \"{}\"\r\n", q(&titles[i])));
            let a = artists.get(i).map(String::as_str).filter(|a| !a.is_empty()).unwrap_or(artist);
            cue.push_str(&format!("    PERFORMER \"{}\"\r\n    INDEX 01 00:00:00\r\n", q(a)));
        }
        std::fs::write(free_path(dest.join(format!("{}.cue", safe_name(if album.is_empty() { "Album" } else { album })))), cue)?;

        let mut log = String::new();
        let ar = |x: &verify::TrackVerdict| {
            if db.accuraterip.is_empty() {
                "brak płyty w bazie".to_string()
            } else if x.accuraterip > 0 {
                format!("zgodny (pewność {})", x.accuraterip)
            } else if x.accuraterip_best > 0 {
                "NIEZGODNY".to_string()
            } else {
                "brak utworu w bazie".to_string()
            }
        };
        log.push_str("Mytify, raport importu Audio CD\r\n\r\n");
        log.push_str(&format!("Album: {artist} / {album}\r\nNapęd: {drive}\r\n"));
        log.push_str(&format!("Przesunięcie odczytu: {offset:+} próbek ({source})\r\n"));
        log.push_str("Odczyt: każdy fragment dwa razy z porównaniem, przy różnicy do 4 odczytów pojedynczego sektora.\r\n");
        log.push_str("Przerwy między utworami: dołączone do poprzedniego utworu (indeksy 00 nie są odczytywane).\r\n");
        log.push_str(&format!("Disc ID MusicBrainz: {}\r\nAccurateRip: {}\r\n\r\n", toc.disc_id, verify::accuraterip_path(toc)));
        for n in notes {
            log.push_str(n);
            log.push_str("\r\n");
        }
        for x in verdicts {
            log.push_str(&format!(
                "Ścieżka {:02}  CRC32 {}  AR v1 {}  AR v2 {}  AccurateRip: {}  CTDB: {}  Powtórzone sektory: {}\r\n",
                x.track, x.crc, x.v1, x.v2, ar(x),
                if db.ctdb.is_empty() { "brak płyty w bazie".into() } else if x.ctdb > 0 { format!("zgodny (pewność {})", x.ctdb) } else { "brak zgodności".into() },
                x.retried_sectors
            ));
        }
        if let Some(c) = disc {
            log.push_str(&format!("\r\nCTDB cała płyta: CRC {c:08x}, {}\r\n", if ctdb_disc > 0 { format!("zgodna (pewność {ctdb_disc})") } else { "brak zgodnego wpisu".into() }));
        }
        for e in &db.errors {
            log.push_str(&format!("Uwaga: {e}\r\n"));
        }
        let ok = verdicts.iter().filter(|x| x.accuraterip > 0 || x.ctdb > 0).count();
        log.push_str(&format!("\r\nZweryfikowane w bazach: {ok} z {} ścieżek.\r\n", verdicts.len()));
        std::fs::write(free_path(dest.join("Raport importu.log")), log)?;
        std::fs::write(
            free_path(dest.join("READ_REPORT.json")),
            serde_json::to_vec_pretty(&json!({"toc": toc, "drive": drive, "offset": offset, "offsetSource": source, "tracks": verdicts, "ctdbDisc": disc.map(|c| format!("{c:08x}")), "ctdbDiscConfidence": ctdb_disc}))?,
        )?;
        Ok(())
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
fn clock(seconds: u64) -> String {
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

/// Peak envelope of a recording: `points` pairs of (min, max) per channel mix, -1..1.
fn waveform(path: &Path, points: usize) -> Result<Value> {
    let mut w = wav::Wav::read(path)?;
    let frames = w.frames();
    let block = w.channels as usize * w.bits as usize / 8;
    let per = frames.div_ceil(points as u64).max(1);
    let mut out = Vec::with_capacity(points * 2);
    w.file.seek(SeekFrom::Start(44))?;
    let mut buf = vec![0u8; (per as usize).min(1 << 20) * block];
    let mut left = frames;
    let full = if w.bits == 16 { 32768.0 } else { 8388608.0 };
    while left > 0 {
        let n = left.min(per) as usize;
        let mut lo = 0f32;
        let mut hi = 0f32;
        let mut remaining = n;
        while remaining > 0 {
            let k = remaining.min(buf.len() / block);
            w.file.read_exact(&mut buf[..k * block])?;
            for s in buf[..k * block].chunks_exact(w.bits as usize / 8) {
                let x = if w.bits == 16 {
                    i16::from_le_bytes([s[0], s[1]]) as f32
                } else {
                    (i32::from_le_bytes([0, s[0], s[1], s[2]]) >> 8) as f32
                } / full;
                lo = lo.min(x);
                hi = hi.max(x);
            }
            remaining -= k;
        }
        out.push((lo * 1000.0).round() / 1000.0);
        out.push((hi * 1000.0).round() / 1000.0);
        left -= n as u64;
    }
    Ok(json!({"rate": w.rate, "frames": frames, "perPoint": per, "peaks": out}))
}

/// Plays a few seconds around a position through the default output (Windows),
/// converted to 16 bit so every driver accepts it.
fn preview(path: &Path, temp: &Path, at_ms: u64, seconds: f64) -> Result<()> {
    let mut w = wav::Wav::read(path)?;
    let rate = w.rate as u64;
    let frames = w.frames();
    let half = (seconds.clamp(0.5, 10.0) * rate as f64 / 2.0) as u64;
    let center = (at_ms * rate / 1000).min(frames);
    let start = center.saturating_sub(half);
    let end = (center + half).min(frames);
    let block = w.channels as usize * w.bits as usize / 8;
    w.file.seek(SeekFrom::Start(44 + start * block as u64))?;
    let mut raw = vec![0u8; (end - start) as usize * block];
    w.file.read_exact(&mut raw)?;
    stop_preview();
    let _ = std::fs::remove_file(temp);
    let mut out = wav::Wav::create(temp, w.rate, w.channels, 16)?;
    let mut pcm = Vec::with_capacity(raw.len());
    for s in raw.chunks_exact(w.bits as usize / 8) {
        let v = if w.bits == 16 { i16::from_le_bytes([s[0], s[1]]) } else { i16::from_le_bytes([s[1], s[2]]) };
        pcm.extend_from_slice(&v.to_le_bytes());
    }
    out.write(&pcm)?;
    out.finish()?;
    drop(out);
    #[cfg(windows)]
    {
        use windows_sys::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_FILENAME, SND_NODEFAULT};
        let name: Vec<u16> = temp.as_os_str().to_string_lossy().encode_utf16().chain(Some(0)).collect();
        unsafe {
            PlaySoundW(name.as_ptr(), std::ptr::null_mut(), SND_FILENAME | SND_ASYNC | SND_NODEFAULT);
        }
    }
    Ok(())
}

fn stop_preview() {
    #[cfg(windows)]
    unsafe {
        windows_sys::Win32::Media::Audio::PlaySoundW(std::ptr::null(), std::ptr::null_mut(), 0);
    }
}

fn safe_name(s: &str) -> String {
    let s = s
        .chars()
        .map(|c| {
            if c.is_control() || "<>:\"/\\|?*".contains(c) {
                '_'
            } else {
                c
            }
        })
        .take(100)
        .collect::<String>()
        .trim_matches(['.', ' '])
        .to_owned();
    if s.is_empty() {
        "Utwór".into()
    } else {
        s
    }
}
pub const IMPORT_FOLDER: &str = "importFolder";
/// Share of a CD import spent reading the disc (the rest is tags and the library).
const READING: f64 = 0.95;
/// Share of an export spent encoding (the rest is tags and the library).
const ENCODING: f64 = 0.9;

fn is_audio(p: &Path) -> bool {
    p.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("flac") || e.eq_ignore_ascii_case("mp3"))
}

/// Audio files directly in a folder, sorted.
fn audio_files(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.is_file() && is_audio(p)).collect();
    out.sort();
    out
}

/// Files of an album folder (and its MP3 subfolder) with their relative paths.
fn files_below(dir: &Path) -> Vec<(PathBuf, PathBuf)> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_file() {
            if !p.to_string_lossy().ends_with(".partial") {
                out.push((p.clone(), PathBuf::from(e.file_name())));
            }
        } else if p.is_dir() {
            for f in std::fs::read_dir(&p).into_iter().flatten().flatten() {
                if f.path().is_file() {
                    out.push((f.path(), PathBuf::from(e.file_name()).join(f.file_name())));
                }
            }
        }
    }
    out.sort();
    out
}

/// "01-Title.flac" (older imports) becomes "01 - Title.flac".
fn dashed(name: &str) -> String {
    let b = name.as_bytes();
    if b.len() > 3 && b[0].is_ascii_digit() && b[1].is_ascii_digit() && b[2] == b'-' && b[3] != b' ' {
        format!("{} - {}", &name[..2], &name[3..])
    } else {
        name.to_string()
    }
}

/// Album artist (or artist), album and date from a file's tags.
fn album_tags(path: &Path) -> (String, String, String) {
    use lofty::{
        file::TaggedFileExt,
        prelude::Accessor,
        tag::ItemKey,
    };
    let Ok(f) = lofty::read_from_path(path) else { return Default::default() };
    let Some(t) = f.primary_tag().or_else(|| f.first_tag()) else { return Default::default() };
    let artist = t
        .get_string(ItemKey::AlbumArtist)
        .filter(|a| !a.trim().is_empty())
        .map(str::to_string)
        .or_else(|| t.artist().map(|a| a.into_owned()))
        .unwrap_or_default();
    let date = t.get_string(ItemKey::RecordingDate).or_else(|| t.get_string(ItemKey::Year)).unwrap_or("").to_string();
    (artist, t.album().map(|a| a.into_owned()).unwrap_or_default(), date)
}

/// Copies through a temporary name and checks the size before the file counts as copied.
/// `progress` gets the bytes copied so far.
fn copy_checked(from: &Path, to: &Path, mut progress: impl FnMut(u64)) -> Result<()> {
    use std::io::{Read, Write};
    if let Some(dir) = to.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let partial = to.with_extension("partial");
    let n = {
        let mut src = std::fs::File::open(from)?;
        let mut dst = std::fs::File::create(&partial)?;
        let mut buf = vec![0u8; 1 << 20];
        let mut n = 0u64;
        loop {
            let k = src.read(&mut buf)?;
            if k == 0 {
                break;
            }
            dst.write_all(&buf[..k])?;
            n += k as u64;
            progress(n);
        }
        dst.sync_all()?;
        n
    };
    if n != std::fs::metadata(from)?.len() || std::fs::metadata(&partial)?.len() != n {
        let _ = std::fs::remove_file(&partial);
        bail!("Kopia pliku {} jest niepełna", from.display())
    }
    std::fs::rename(&partial, to)?;
    Ok(())
}

/// The music folder chosen for imports, if any.
pub fn import_folder(catalog: &Catalog) -> Option<PathBuf> {
    crate::settings::get(catalog, IMPORT_FOLDER).ok().flatten().map(PathBuf::from)
}

static COVERS_RUNNING: AtomicBool = AtomicBool::new(false);

/// Album folders in the music folder get `cover.jpg` from the cover the library shows
/// (chosen in the app, found online or embedded), so the phone and other players see
/// it too. Never replaces a picture that is already there. Returns how many it wrote.
pub fn write_folder_covers(catalog: &Catalog) -> Result<usize> {
    let Some(root) = import_folder(catalog).and_then(|r| r.canonicalize().ok()) else { return Ok(0) };
    if COVERS_RUNNING.swap(true, Ordering::AcqRel) {
        return Ok(0);
    }
    let result = (|| -> Result<usize> {
        let covers: std::collections::HashMap<String, String> =
            catalog.tracks()?.into_iter().filter_map(|t| t.cover.map(|c| (t.id, c))).collect();
        let rows: Vec<(String, String)> = {
            let db = catalog.db()?;
            let mut stmt = db.prepare("SELECT track_id,path FROM locations WHERE available=1")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        let mut dirs: std::collections::BTreeMap<PathBuf, String> = Default::default();
        for (id, path) in rows {
            let Some(cover) = covers.get(&id) else { continue };
            let path = PathBuf::from(path);
            if !path.starts_with(&root) {
                continue;
            }
            if let Some(dir) = path.parent() {
                dirs.entry(dir.to_path_buf()).or_insert_with(|| cover.clone());
            }
        }
        let mut written = 0;
        for (dir, cover) in dirs {
            const PICTURES: [&str; 6] = ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.jpeg", "folder.png"];
            if !dir.is_dir() || PICTURES.iter().any(|n| dir.join(n).is_file()) {
                continue;
            }
            if let Some(bytes) = catalog.artwork_path(&cover).ok().and_then(|p| std::fs::read(p).ok()) {
                if write_new(&dir.join("cover.jpg"), &bytes).is_ok() {
                    written += 1;
                }
            }
        }
        Ok(written)
    })();
    // Artist folders get artist.jpg from the photo the library shows.
    let _ = crate::artist_photos::place_in_music_folder(catalog);
    COVERS_RUNNING.store(false, Ordering::Release);
    result
}

/// Album folder in the music folder: `Artist\Album (year)`, the layout of Plex,
/// Jellyfin and most taggers.
pub fn album_path(root: &Path, artist: &str, album: &str, date: &str) -> PathBuf {
    let artist = if artist.trim().is_empty() { "Nieznany wykonawca" } else { artist };
    let album = if album.trim().is_empty() { "Bez tytułu" } else { album.trim() };
    let year: String = date.trim().chars().take(4).collect();
    let album = if year.len() == 4 && year.chars().all(|c| c.is_ascii_digit()) && !album.contains(&year) {
        format!("{album} ({year})")
    } else {
        album.to_string()
    };
    root.join(safe_name(artist)).join(safe_name(&album))
}

/// File name without extension: `01 - Title`, `2-01 - Title` on a multi-disc album.
fn track_stem(v: &Value, number: usize, title: &str) -> String {
    match v["disc"].as_u64().filter(|_| v["discs"].as_u64().unwrap_or(1) > 1) {
        Some(d) => format!("{d}-{number:02} - {}", safe_name(title)),
        None => format!("{number:02} - {}", safe_name(title)),
    }
}

/// A stem none of whose files exist yet: "01 - Title", then "01 - Title (2)"...
/// Files already in the folder are never overwritten.
fn free_stem(stem: &str, files: impl Fn(&str) -> Vec<PathBuf>) -> String {
    (1..1000)
        .map(|n| if n == 1 { stem.to_string() } else { format!("{stem} ({n})") })
        .find(|s| files(s).iter().all(|p| !p.exists()))
        .unwrap_or_else(|| format!("{stem} {}", hex(getrandom_bytes().unwrap_or_default())))
}

/// `path` or, when it exists, `name (2).ext`...
fn free_path(path: PathBuf) -> PathBuf {
    let dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let s = free_stem(&stem, |s| vec![dir.join(format!("{s}{ext}"))]);
    dir.join(format!("{s}{ext}"))
}

/// Writes a file only when there is none: the user's files are never replaced.
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    if path.exists() {
        return Ok(());
    }
    let partial = path.with_extension("partial");
    std::fs::write(&partial, bytes)?;
    if std::fs::rename(&partial, path).is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    Ok(())
}

/// Everything written into a FLAC or MP3 file made by import.
#[derive(Clone, Debug, Default)]
pub struct TagInfo {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track: u32,
    pub tracks: u32,
    pub disc: Option<u32>,
    pub discs: Option<u32>,
    pub date: String,
    pub release_id: String,
    /// (gain dB, peak 0..1)
    pub gain: Option<(f64, f64)>,
    pub album_gain: Option<(f64, f64)>,
}
impl TagInfo {
    pub fn from_request(v: &Value, title: &str, artist: Option<&str>, track: u32, tracks: u32) -> Self {
        let album_artist = v["artist"].as_str().unwrap_or("").to_string();
        Self {
            title: title.into(),
            artist: artist.filter(|a| !a.is_empty()).map(str::to_string).unwrap_or_else(|| album_artist.clone()),
            album: v["album"].as_str().unwrap_or("").into(),
            album_artist,
            track,
            tracks,
            disc: v["disc"].as_u64().map(|d| d as u32),
            discs: v["discs"].as_u64().map(|d| d as u32),
            date: v["date"].as_str().unwrap_or("").into(),
            release_id: v["releaseId"].as_str().unwrap_or("").into(),
            gain: None,
            album_gain: None,
        }
    }
}

pub(crate) fn write_tags(path: &Path, t: &TagInfo, cover: Option<&[u8]>) -> Result<()> {
    use lofty::{
        config::WriteOptions,
        picture::{MimeType, Picture, PictureType},
        prelude::{Accessor, TagExt},
        tag::{ItemKey, Tag, TagType},
    };
    let mp3 = path.extension().is_some_and(|e| e == "mp3");
    let mut tag = Tag::new(if mp3 { TagType::Id3v2 } else { TagType::VorbisComments });
    tag.set_title(t.title.clone());
    tag.set_artist(t.artist.clone());
    tag.set_album(t.album.clone());
    tag.insert_text(ItemKey::AlbumArtist, t.album_artist.clone());
    tag.set_track(t.track);
    if t.tracks > 0 {
        tag.set_track_total(t.tracks);
    }
    if let Some(d) = t.disc {
        tag.set_disk(d);
    }
    if let Some(d) = t.discs {
        tag.set_disk_total(d);
    }
    if !t.date.is_empty() {
        tag.insert_text(ItemKey::RecordingDate, t.date.clone());
    }
    if !t.release_id.is_empty() {
        tag.insert_text(ItemKey::MusicBrainzReleaseId, t.release_id.clone());
    }
    if let Some((g, p)) = t.gain {
        tag.insert_text(ItemKey::ReplayGainTrackGain, format!("{g:.2} dB"));
        tag.insert_text(ItemKey::ReplayGainTrackPeak, format!("{p:.6}"));
    }
    if let Some((g, p)) = t.album_gain {
        tag.insert_text(ItemKey::ReplayGainAlbumGain, format!("{g:.2} dB"));
        tag.insert_text(ItemKey::ReplayGainAlbumPeak, format!("{p:.6}"));
    }
    if let Some(c) = cover {
        tag.push_picture(Picture::unchecked(c.to_vec()).pic_type(PictureType::CoverFront).mime_type(MimeType::Jpeg).build());
    }
    tag.save_to_path(path, WriteOptions::default())?;
    Ok(())
}
pub fn boundaries(marks: &[u64], rate: u32, frames: u64) -> Result<Vec<u64>> {
    if rate == 0 || frames < 16 || marks.len() > 1000 {
        bail!("Nieprawidłowe granice nagrania")
    };
    let mut out = vec![0];
    for ms in marks {
        if *ms == 0 {
            continue;
        }
        let frame = ms
            .checked_mul(rate as u64)
            .ok_or_else(|| anyhow!("Zbyt duża pozycja"))?
            / 1000;
        if frame >= frames || frame < out.last().unwrap() + 16 {
            bail!("Znaczniki muszą rosnąć, mieścić się w nagraniu i nie tworzyć pustych utworów")
        };
        out.push(frame);
    }
    if frames < out.last().unwrap() + 16 {
        bail!("Ostatni utwór jest za krótki")
    };
    out.push(frames);
    Ok(out)
}
/// Places track starts from a tracklist: expected positions from the durations,
/// scaled to the recorded length, each moved to the quietest point within ±8 s.
fn align(path: &Path, durations: &[u64]) -> Result<Vec<u64>> {
    let mut w = wav::Wav::read(path)?;
    let rate = w.rate as u64;
    let block = w.channels as usize * w.bits as usize / 8;
    let win = (rate / 10) as usize;
    let mut env = Vec::new();
    w.file.seek(SeekFrom::Start(44))?;
    let mut buf = vec![0u8; win * block];
    let total = w.frames();
    let mut pos = 0;
    while pos + win as u64 <= total {
        w.file.read_exact(&mut buf)?;
        let mut sum = 0f64;
        for s in buf.chunks_exact(w.bits as usize / 8) {
            let x = if w.bits == 16 {
                i16::from_le_bytes([s[0], s[1]]) as f64 / 32768.0
            } else {
                (i32::from_le_bytes([0, s[0], s[1], s[2]]) >> 8) as f64 / 8388608.0
            };
            sum += x * x;
        }
        env.push(10.0 * (sum / (win * w.channels as usize) as f64 + 1e-12).log10());
        pos += win as u64;
    }
    if env.len() < 50 {
        bail!("Nagranie jest za krótkie")
    }
    let loud = env.iter().cloned().fold(f64::MIN, f64::max);
    let start = env.iter().position(|e| *e > loud - 35.0).unwrap_or(0);
    let end = env.iter().rposition(|e| *e > loud - 35.0).unwrap_or(env.len() - 1) + 1;
    let planned: u64 = durations.iter().sum::<u64>() / 100; // in 100 ms windows
    let measured = (end - start) as f64;
    let scale = if planned > 0 && (measured / planned as f64 - 1.0).abs() < 0.12 {
        measured / planned as f64
    } else {
        1.0
    };
    let mut out = Vec::new();
    let mut acc = 0u64;
    let mut last = start;
    for d in &durations[..durations.len() - 1] {
        acc += d / 100;
        let expected = start + (acc as f64 * scale).round() as usize;
        let lo = expected.saturating_sub(80).max(last + 50);
        let hi = (expected + 80).min(env.len().saturating_sub(1));
        if lo >= hi {
            continue;
        }
        // Quietest 1 s stretch around the expected position.
        let mut best = lo;
        let mut best_level = f64::MAX;
        for c in lo..hi {
            let a = c.saturating_sub(5);
            let b = (c + 5).min(env.len());
            let level = env[a..b].iter().sum::<f64>() / (b - a) as f64;
            if level < best_level {
                best_level = level;
                best = c;
            }
        }
        out.push(best as u64 * 100 + 50);
        last = best;
    }
    Ok(out)
}
fn silences(path: &Path) -> Result<Vec<u64>> {
    let mut w = wav::Wav::read(path)?;
    let block = w.channels as usize * w.bits as usize / 8;
    let chunk = (w.rate / 20) as usize;
    let mut bytes = vec![0u8; chunk * block];
    w.file.seek(SeekFrom::Start(44))?;
    let total = w.frames();
    let mut position = 0;
    let mut quiet = None;
    let mut out = Vec::new();
    while position < total {
        let n = (total - position).min(chunk as u64) as usize;
        w.file.read_exact(&mut bytes[..n * block])?;
        let mut peak = 0i32;
        for b in bytes[..n * block].chunks_exact(w.bits as usize / 8) {
            let x = if w.bits == 16 {
                i16::from_le_bytes([b[0], b[1]]) as i32 * 256
            } else {
                i32::from_le_bytes([0, b[0], b[1], b[2]]) >> 8
            };
            peak = peak.max(x.abs());
        }
        if peak < 47172 {
            quiet.get_or_insert(position);
        } else if let Some(start) = quiet.take() {
            if position - start >= w.rate as u64 * 3 / 2
                && start > w.rate as u64 * 5
                && total - position > w.rate as u64 * 5
                && out.len() < 1000
            {
                out.push((start + position) / 2 * 1000 / w.rate as u64);
            }
        }
        position += n as u64;
    }
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::decoder::NativeSource;
    use std::io::Read;
    #[test]
    fn streaming_flac_exports_exact_pcm_and_preserves_master() {
        for bits in [16u16, 24] {
            let dir = tempfile::tempdir().unwrap();
            let master = dir.path().join("master.wav");
            let mut w = wav::Wav::create(&master, 44100, 2, bits).unwrap();
            let mut raw = Vec::new();
            let mut expected = Vec::new();
            for i in 0..10001 {
                let values = [
                    ((i * 4321) % 65536 - 32768) as i32,
                    ((i * 9187) % 65536 - 32768) as i32,
                ];
                for v in values {
                    let sample = if bits == 24 { v * 256 + (i % 256) } else { v };
                    expected.push(sample as f32 / (if bits == 24 { 8388608. } else { 32768. }));
                    raw.extend_from_slice(&sample.to_le_bytes()[..bits as usize / 8]);
                }
            }
            w.write(&raw).unwrap();
            w.finish().unwrap();
            drop(w);
            let original = std::fs::read(&master).unwrap();
            let target = dir.path().join("export.flac.partial");
            wav::flac(&master, &target, 0, 10001).unwrap();
            write_tags(
                &target,
                &TagInfo::from_request(&json!({"album":"Album test","artist":"Wykonawca"}), "Utwór", None, 1, 1),
                None,
            )
            .unwrap();
            let mut decoder = NativeSource::open(&target, 0).unwrap();
            let mut decoded = Vec::new();
            while let Some(s) = decoder.next().unwrap() {
                decoded.extend(s)
            }
            assert_eq!(decoded.len(), expected.len());
            if let Some(i) = decoded.iter().zip(&expected).position(|(a, b)| a != b) {
                panic!(
                    "PCM {bits} differs at sample {i}: {} != {}",
                    decoded[i], expected[i]
                );
            }
            assert_eq!(std::fs::read(&master).unwrap(), original);
            let short = dir.path().join("one-tail.flac");
            wav::flac(&master, &short, 0, 4097).unwrap();
            let mut decoder = NativeSource::open(&short, 0).unwrap();
            let mut count = 0;
            while decoder.next().unwrap().is_some() {
                count += 1;
            }
            assert_eq!(count, 4097);
        }
    }
    /// Simulated disc: 3 tracks of noise, a drive that reads 6 samples early.
    struct FakeDrive {
        audio: Vec<u8>,
        offset: i64,
    }
    impl cd::Reader for FakeDrive {
        fn read(&self, lba: u32, sectors: u32) -> Result<Vec<u8>> {
            let mut out = vec![0u8; sectors as usize * 2352];
            for (k, b) in out.chunks_exact_mut(4).enumerate() {
                // Drive sample d holds true sample d - offset.
                let t = (lba as i64 * 588 + k as i64) - self.offset;
                if t >= 0 && ((t as usize + 1) * 4) <= self.audio.len() {
                    b.copy_from_slice(&self.audio[t as usize * 4..t as usize * 4 + 4]);
                }
            }
            Ok(out)
        }
        fn eject(&self) -> Result<()> {
            Ok(())
        }
    }

    #[test]
    fn simulated_rip_finds_offset_verifies_and_writes_cue_log_tags() {
        let d = tempfile::tempdir().unwrap();
        let catalog = Arc::new(Catalog::open(d.path().to_path_buf()).unwrap());
        let ingest = Ingest::new(catalog);
        let starts = [0u32, 750, 1700];
        let leadout = 2600u32;
        let mut x: u32 = 7;
        let mut audio = Vec::new();
        for _ in 0..leadout as usize * 588 {
            x = x.wrapping_mul(1103515245).wrapping_add(12345);
            audio.extend_from_slice(&((x >> 1) & 0x0fff0fff).to_le_bytes());
        }
        let tracks: Vec<cd::CdTrack> = starts
            .iter()
            .enumerate()
            .map(|(i, s)| cd::CdTrack { number: i as u8 + 1, start: *s, end: starts.get(i + 1).copied().unwrap_or(leadout), data: false })
            .collect();
        let toc = cd::Toc { drive: "X:".into(), disc_id: "fake".into(), tracks: tracks.clone(), leadout };
        // Database built from the true audio.
        let sums: Vec<(u32, u32)> = tracks
            .iter()
            .enumerate()
            .map(|(i, t)| verify::accuraterip_sums(&audio[t.start as usize * 2352..t.end as usize * 2352], i == 0, i == 2))
            .collect();
        let db = verify::Databases {
            accuraterip: vec![verify::ArResponse { tracks: sums.iter().map(|(v1, _)| (17, *v1)).collect() }],
            accuraterip_entries: 1,
            ..Default::default()
        };
        let v = json!({"discId":"fake","album":"Płyta","artist":"Zespół","titles":["Jeden","Dwa","Trzy"],"artists":["","Gość",""],"mp3":true,"date":"1999"});
        ingest.begin("ripping").unwrap();
        ingest.rip_with(&FakeDrive { audio: audio.clone(), offset: 6 }, toc.clone(), "FAKE DRIVE", db.clone(), &v).unwrap();
        let s = ingest.state.lock().unwrap().clone();
        assert_eq!(s.offset, Some(6), "{:?}", s.offset_source);
        assert_eq!(ingest.snapshot()["progress"], 1.0);
        assert_eq!(s.verdicts.len(), 3);
        assert!(s.verdicts.iter().all(|x| x.accuraterip == 17), "{:?}", s.verdicts);
        assert_eq!(ingest.saved_offsets().get("FAKE DRIVE"), Some(&6));
        let folder = PathBuf::from(&s.folder);
        let names: Vec<String> = std::fs::read_dir(&folder).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert!(names.iter().any(|n| n == "Płyta.cue"), "{names:?}");
        assert!(names.iter().any(|n| n == "Raport importu.log"));
        assert_eq!(std::fs::read_dir(folder.join("MP3")).unwrap().count(), 3);
        let log = std::fs::read_to_string(folder.join("Raport importu.log")).unwrap();
        assert!(log.contains("+6 próbek (wykryte z AccurateRip)"), "{log}");
        assert!(log.contains("Zweryfikowane w bazach: 3 z 3"), "{log}");
        // Decoded FLAC equals the true audio of track 2.
        let mut dec = crate::audio::decoder::NativeSource::open(&folder.join("02 - Dwa.flac"), 0).unwrap();
        let mut n = 0usize;
        let t = &tracks[1];
        while let Some(f) = dec.next().unwrap() {
            let at = (t.start as usize * 588 + n) * 4;
            let l = i16::from_le_bytes([audio[at], audio[at + 1]]) as f32 / 32768.0;
            assert_eq!(f[0], l, "sample {n}");
            n += 1;
        }
        assert_eq!(n, (t.end - t.start) as usize * 588);
        // Tags: guest artist on track 2, album artist kept, ReplayGain present.
        use lofty::prelude::{Accessor, TaggedFileExt};
        let tagged = lofty::read_from_path(folder.join("02 - Dwa.flac")).unwrap();
        let tag = tagged.primary_tag().unwrap();
        assert_eq!(tag.artist().as_deref(), Some("Gość"));
        assert_eq!(tag.get_string(lofty::tag::ItemKey::AlbumArtist), Some("Zespół"));
        assert!(tag.get_string(lofty::tag::ItemKey::ReplayGainTrackGain).is_some());
        assert!(tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumGain).is_some());
        // A music folder: the album made earlier moves into Artist/Album (year).
        let music = d.path().join("Muzyka");
        std::fs::create_dir_all(&music).unwrap();
        ingest.command(json!({"action": "setImportFolder", "path": music.to_string_lossy()})).unwrap();
        let info = ingest.command(json!({"action": "importFolder"})).unwrap();
        assert_eq!(info["stored"], 1, "{info}");
        assert_eq!(info["inLibrary"], false);
        ingest.relocate().unwrap();
        let album = music.join("Zespół").join("Płyta (1999)");
        assert!(album.join("02 - Dwa.flac").is_file());
        assert!(album.join("MP3").join("02 - Dwa.mp3").is_file());
        assert!(album.join("Raport importu.log").is_file());
        assert!(!folder.exists(), "the app's own copy is removed after the check");
        assert_eq!(ingest.command(json!({"action": "importFolder"})).unwrap()["stored"], 0);
        let paths: Vec<String> = {
            let db = ingest.catalog.db().unwrap();
            let mut st = db.prepare("SELECT path FROM locations").unwrap();
            st.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|r| r.unwrap()).collect()
        };
        assert_eq!(paths.len(), 3, "{paths:?}");
        assert!(paths.iter().all(|p| p.contains("Muzyka")), "{paths:?}");
        // A cover the library knows (found online, chosen in the app) goes next to the album.
        let hash = "ab".repeat(32);
        std::fs::create_dir_all(d.path().join("artwork")).unwrap();
        std::fs::write(d.path().join("artwork").join(&hash), b"jpeg").unwrap();
        ingest.catalog.db().unwrap().execute("UPDATE tracks SET cover=?1", [&hash]).unwrap();
        // Opening the music folder settings started a pass in the background: let it end.
        while COVERS_RUNNING.load(Ordering::Acquire) {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(write_folder_covers(&ingest.catalog).unwrap(), 1);
        assert_eq!(std::fs::read(album.join("cover.jpg")).unwrap(), b"jpeg");
        assert_eq!(write_folder_covers(&ingest.catalog).unwrap(), 0, "never replaced");
        // The artist's photo goes into the artist folder of the same layout.
        crate::artist_photos::place_in_music_folder(&ingest.catalog).unwrap();
        ingest.catalog.db().unwrap().execute("INSERT INTO artist_photos(key,name,cover,origin,checked) VALUES('zespół','Zespół',?1,'deezer',0)", [&hash]).unwrap();
        assert_eq!(crate::artist_photos::place_in_music_folder(&ingest.catalog).unwrap(), 1);
        assert!(music.join("Zespół").join("artist.jpg").is_file());
        assert_eq!(crate::artist_photos::place_in_music_folder(&ingest.catalog).unwrap(), 0, "never replaced");
        // Second rip of the same drive reuses the remembered offset and goes straight to
        // the music folder without replacing anything there.
        let mut s = ingest.state.lock().unwrap();
        s.verdicts.clear();
        drop(s);
        ingest.rip_with(&FakeDrive { audio, offset: 6 }, toc, "FAKE DRIVE", db, &v).unwrap();
        assert_eq!(ingest.state.lock().unwrap().offset_source, "zapamiętane dla napędu");
        assert_eq!(PathBuf::from(&ingest.state.lock().unwrap().folder), album);
        assert!(album.join("02 - Dwa (2).flac").is_file());
        assert!(album.join("Raport importu (2).log").is_file());
    }

    #[test]
    fn crash_recovery_truncates_only_incomplete_frame_and_keeps_pcm() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("master.wav.partial");
        let mut w = wav::Wav::create(&p, 48000, 2, 24).unwrap();
        w.write(&[1, 2, 3, 4, 5, 6, 7]).unwrap();
        drop(w);
        let mut recovered = wav::Wav::recover(&p).unwrap();
        assert_eq!(recovered.frames(), 1);
        assert_eq!(recovered.file.metadata().unwrap().len(), 50);
        recovered.file.seek(SeekFrom::Start(44)).unwrap();
        let mut b = Vec::new();
        recovered.file.read_to_end(&mut b).unwrap();
        assert_eq!(b, [1, 2, 3, 4, 5, 6]);
    }
    #[test]
    fn export_boundaries_reject_overlaps_and_cover_every_sample() {
        assert_eq!(
            boundaries(&[1000, 2000], 44100, 132300).unwrap(),
            [0, 44100, 88200, 132300]
        );
        assert!(boundaries(&[2000, 1000], 44100, 132300).is_err());
        assert!(boundaries(&[3000], 44100, 132300).is_err());
    }
    #[test]
    fn tracklist_alignment_finds_the_gaps() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("master.wav");
        let rate = 8000usize;
        let mut w = wav::Wav::create(&p, rate as u32, 1, 16).unwrap();
        // 3 s lead-in, tracks of 40, 50, 30 s with 2 s gaps, recorded 3% slow.
        let mut data = Vec::new();
        let mut t = 0usize;
        let mut push = |secs: f64, loud: bool, data: &mut Vec<u8>| {
            for _ in 0..(secs * 1.03 * rate as f64) as usize {
                let v: i16 = if loud { (((t * 37) % 200) as i16 - 100) * 60 } else { ((t % 7) as i16) - 3 };
                data.extend(v.to_le_bytes());
                t += 1;
            }
        };
        push(3.0, false, &mut data);
        push(40.0, true, &mut data);
        push(2.0, false, &mut data);
        push(50.0, true, &mut data);
        push(2.0, false, &mut data);
        push(30.0, true, &mut data);
        w.write(&data).unwrap();
        w.finish().unwrap();
        drop(w);
        let marks = align(&p, &[42_000, 52_000, 30_000]).unwrap();
        assert_eq!(marks.len(), 2);
        // True gap centres: (3+40+1)*1.03 s and (3+40+2+50+1)*1.03 s.
        for (m, truth) in marks.iter().zip([44.0 * 1.03, 96.0 * 1.03]) {
            assert!((*m as f64 / 1000.0 - truth).abs() < 1.2, "{m} vs {truth}");
        }
    }
    #[test]
    fn silence_suggestions_do_not_cut_short_breaks() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("master.wav");
        let mut w = wav::Wav::create(&p, 8000, 1, 16).unwrap();
        let mut data = Vec::new();
        for i in 0..8000 * 24 {
            let sample = if (8000 * 7..8000 * 9).contains(&i)
                || (8000 * 15..8000 * 15 + 4000).contains(&i)
            {
                0i16
            } else {
                1000
            };
            data.extend(sample.to_le_bytes());
        }
        w.write(&data).unwrap();
        w.finish().unwrap();
        drop(w);
        assert_eq!(silences(&p).unwrap(), [8000]);
    }

    #[test]
    fn music_folder_names() {
        let root = Path::new("M");
        assert_eq!(album_path(root, "AC/DC", "Back in Black", "1980-07-25"), root.join("AC_DC").join("Back in Black (1980)"));
        assert_eq!(album_path(root, "", "", ""), root.join("Nieznany wykonawca").join("Bez tytułu"));
        assert_eq!(album_path(root, "Queen", "Live 1986", "1986"), root.join("Queen").join("Live 1986"));
        assert_eq!(track_stem(&json!({}), 3, "Ja?"), "03 - Ja_");
        assert_eq!(track_stem(&json!({"disc": 2, "discs": 2}), 1, "A"), "2-01 - A");
        assert_eq!(dashed("01-Jeden.flac"), "01 - Jeden.flac");
        assert_eq!(dashed("01 - Jeden.flac"), "01 - Jeden.flac");
        assert_eq!(dashed("cover.jpg"), "cover.jpg");
    }
}
