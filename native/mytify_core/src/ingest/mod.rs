#[cfg(windows)]
mod capture;
pub mod cd;
pub mod wav;
use crate::catalog::{getrandom_bytes, hex, Catalog, ScanRequest};
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
    pub clips: u64,
    pub dropouts: u64,
    pub markers: Vec<u64>,
    pub done: u64,
    pub total: u64,
    pub files: Vec<String>,
    pub warnings: Vec<String>,
    pub error: Option<String>,
}
pub struct Signals {
    pub stop: AtomicBool,
    pub frames: AtomicU64,
    pub peak: AtomicU32,
    pub clips: AtomicU64,
    pub dropped: AtomicU64,
    pub failed: AtomicBool,
}
impl Default for Signals {
    fn default() -> Self {
        Self {
            stop: AtomicBool::new(false),
            frames: AtomicU64::new(0),
            peak: AtomicU32::new(0),
            clips: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            failed: AtomicBool::new(false),
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
        if s.stage == "recording" || s.stage == "monitor" {
            s.frames = self.signals.frames.load(Ordering::Acquire);
            s.peak = f32::from_bits(self.signals.peak.swap(0, Ordering::AcqRel));
            s.clips = self.signals.clips.load(Ordering::Acquire);
            s.dropouts = self.signals.dropped.load(Ordering::Acquire);
        }
        serde_json::to_value(s).unwrap()
    }
    fn begin(&self, stage: &str) -> Result<()> {
        if self.busy.swap(true, Ordering::AcqRel) {
            bail!("Zakończ bieżący import lub nagranie")
        };
        self.signals.stop.store(false, Ordering::Release);
        self.signals.failed.store(false, Ordering::Release);
        self.signals.frames.store(0, Ordering::Release);
        self.signals.peak.store(0, Ordering::Release);
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
                    Ok(json!(cd::device::drives()))
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
                    Ok(serde_json::to_value(d.toc(id)?)?)
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
                        out.push(json!({"id":id,"path":path,"partial":path.extension().is_some_and(|s|s=="partial"),"rate":info.as_ref().map(|w|w.rate),"channels":info.as_ref().map(|w|w.channels),"durationMs":info.as_ref().map(|w|w.frames()*1000/w.rate as u64),"label":meta["label"],"markers":meta["markers"]}));
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
    fn export(&self, v: &Value) -> Result<()> {
        let dir = self.session_path(v["id"].as_str().unwrap_or(""))?;
        let master = dir.join("master.wav");
        let w = wav::Wav::read(&master)?;
        let duration = w.frames();
        let rate = w.rate;
        drop(w);
        let marks: Vec<u64> = serde_json::from_value(v["markers"].clone())?;
        let bounds = boundaries(&marks, rate, duration)?;
        let titles: Vec<String> = serde_json::from_value(v["titles"].clone())?;
        if titles.len() != bounds.len() - 1 {
            bail!("Nadaj tytuł każdemu utworowi")
        };
        let dest = dir.join(format!("export-{}", hex(getrandom_bytes()?)));
        std::fs::create_dir(&dest)?;
        self.state.lock().unwrap().total = titles.len() as u64;
        for (i, b) in bounds.windows(2).enumerate() {
            if self.signals.stop.load(Ordering::Acquire) {
                break;
            }
            let out = dest.join(format!("{:02}-{}.flac", i + 1, safe_name(&titles[i])));
            let partial = out.with_extension("flac.partial");
            wav::flac_cancellable(&master, &partial, b[0], b[1], &self.signals.stop)?;
            tag(&partial, v, &titles[i], i + 1)?;
            std::fs::rename(&partial, &out)?;
            self.state
                .lock()
                .unwrap()
                .files
                .push(out.to_string_lossy().into_owned());
            self.state.lock().unwrap().done = (i + 1) as u64;
            self.catalog.scan(
                ScanRequest {
                    paths: vec![out.to_string_lossy().into_owned()],
                    ..Default::default()
                },
                &AtomicBool::new(false),
                |_| {},
            )?;
        }
        Ok(())
    }
    #[cfg(windows)]
    fn rip(&self, v: &Value) -> Result<()> {
        let drive = v["drive"].as_str().unwrap_or("");
        let reader = cd::device::Drive::open(drive)?;
        let toc = reader.toc(drive)?;
        if v["discId"] != toc.disc_id {
            bail!("Płyta zmieniła się. Odczytaj listę ścieżek ponownie.")
        };
        let titles: Vec<String> = serde_json::from_value(v["titles"].clone())?;
        if titles.len() != toc.tracks.len() {
            bail!("Nieprawidłowa liczba tytułów")
        };
        let dest = self
            .catalog
            .root
            .join("cd-imports")
            .join(hex(getrandom_bytes()?));
        std::fs::create_dir_all(&dest)?;
        self.state.lock().unwrap().total =
            toc.tracks.iter().map(|t| (t.end - t.start) as u64).sum();
        let mut done = 0;
        let mut reports = Vec::new();
        for (i, track) in toc.tracks.iter().enumerate() {
            if self.signals.stop.load(Ordering::Acquire) {
                break;
            }
            let temp = dest.join(format!("track-{:02}.wav.partial", track.number));
            let mut wav = wav::Wav::create(&temp, 44100, 2, 16)?;
            let mut lba = track.start;
            let mut uncertain = Vec::new();
            while lba < track.end {
                if self.signals.stop.load(Ordering::Acquire) {
                    break;
                }
                let n = (track.end - lba).min(16);
                let (bytes, retried) = cd::verified_chunk(|l, n| reader.read(l, n), lba, n)?;
                uncertain.extend(retried);
                wav.write(&bytes)?;
                lba += n;
                done += n as u64;
                let mut s = self.state.lock().unwrap();
                s.done = done;
            }
            wav.finish()?;
            drop(wav);
            if self.signals.stop.load(Ordering::Acquire) {
                break;
            }
            let final_file = dest.join(format!(
                "{:02}-{}.flac",
                track.number,
                safe_name(&titles[i])
            ));
            let partial = final_file.with_extension("flac.partial");
            let w = wav::Wav::read(&temp)?;
            let frames = w.frames();
            drop(w);
            wav::flac_cancellable(&temp, &partial, 0, frames, &self.signals.stop)?;
            tag(&partial, v, &titles[i], track.number as usize)?;
            std::fs::rename(partial, &final_file)?;
            std::fs::remove_file(&temp)?;
            self.state
                .lock()
                .unwrap()
                .files
                .push(final_file.to_string_lossy().into_owned());
            if !uncertain.is_empty() {
                self.state.lock().unwrap().warnings.push(format!(
                    "Ścieżka {}: {} sektorów wymagało dodatkowych odczytów. Odsłuchaj utwór.",
                    track.number,
                    uncertain.len()
                ));
            }
            reports.push(json!({"track":track.number,"retriedSectors":uncertain,"repeatedReadAgreement":true,"accurateRip":false}));
            self.catalog.scan(
                ScanRequest {
                    paths: vec![final_file.to_string_lossy().into_owned()],
                    ..Default::default()
                },
                &AtomicBool::new(false),
                |_| {},
            )?;
        }
        std::fs::write(
            dest.join("READ_REPORT.json"),
            serde_json::to_vec_pretty(
                &json!({"toc":toc,"tracks":reports,"note":"Powtarzane odczyty mogą korzystać z cache napędu. Brak AccurateRip, korekcji offsetu i pełnej walidacji jitter/C2."}),
            )?,
        )?;
        Ok(())
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
pub(crate) fn tag(path: &Path, v: &Value, title: &str, number: usize) -> Result<()> {
    use lofty::{
        config::WriteOptions,
        prelude::{Accessor, TagExt},
        tag::{ItemKey, Tag, TagType},
    };
    let mut t = Tag::new(TagType::VorbisComments);
    t.set_title(title.to_owned());
    t.set_artist(v["artist"].as_str().unwrap_or("").to_owned());
    t.set_album(v["album"].as_str().unwrap_or("").to_owned());
    t.insert_text(
        ItemKey::AlbumArtist,
        v["artist"].as_str().unwrap_or("").into(),
    );
    t.set_track(number as u32);
    t.save_to_path(path, WriteOptions::default())?;
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
            tag(
                &target,
                &json!({"album":"Album test","artist":"Wykonawca"}),
                "Utwór",
                1,
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
}
