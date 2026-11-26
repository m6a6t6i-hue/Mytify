pub mod decoder;
pub mod eq;
mod output;
pub mod render;
mod sequence;
pub mod spectrum;
use crate::catalog::{getrandom_bytes, Catalog};
use anyhow::{anyhow, bail, Result};
use decoder::SourceInfo;
use output::{OutputHandle, OutputInfo};
use render::{Feeder, Signals, BLOCK};
use sequence::{SequenceSource, TaggedFrame};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{atomic::Ordering, mpsc, Arc, Mutex},
    time::{Duration, Instant},
};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    device_id: String,
    volume: f32,
    #[serde(default)]
    equalizer: eq::Equalizer,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            device_id: "auto".into(),
            volume: 80.0,
            equalizer: eq::Equalizer::default(),
        }
    }
}
#[derive(Default)]
struct Data {
    ids: Vec<String>,
    order: Vec<usize>,
    infos: Vec<SourceInfo>,
    output: Option<OutputInfo>,
    selected_device: String,
    repeat: bool,
    shuffled: bool,
    error: Option<String>,
    error_serial: u64,
    revision: u64,
    equalizer: eq::Equalizer,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub available: bool,
    pub playing: bool,
    pub completed: bool,
    pub buffering: bool,
    pub queue_ids: Vec<String>,
    pub index: usize,
    pub current_id: Option<String>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
    pub repeat: bool,
    pub shuffled: bool,
    pub source: Option<SourceInfo>,
    pub output: Option<OutputInfo>,
    pub selected_device: String,
    pub error: Option<String>,
    pub error_serial: u64,
    pub underrun_frames: u64,
    pub rendered_frames: u64,
    pub revision: u64,
    pub equalizer: eq::Equalizer,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum Action {
    Restore {
        ids: Vec<String>,
        index: usize,
        #[serde(rename = "positionMs")]
        position_ms: u64,
        playing: bool,
    },
    Load {
        ids: Vec<String>,
        index: usize,
    },
    Play,
    Pause,
    Stop,
    Next,
    Previous,
    Seek {
        #[serde(rename = "positionMs")]
        position_ms: u64,
    },
    Volume {
        value: f32,
    },
    Repeat {
        value: bool,
    },
    Shuffle {
        value: bool,
    },
    Device {
        id: String,
    },
    Jump {
        id: String,
    },
    Equalizer {
        enabled: bool,
        gains: Vec<f32>,
    },
}
fn persist_settings(root: &std::path::Path, io: &Mutex<()>, settings: &Settings) -> Result<()> {
    let _guard = io
        .lock()
        .map_err(|_| anyhow!("Ustawienia dźwięku są zablokowane."))?;
    let target = root.join("audio-settings.json");
    let temporary = target.with_extension("partial");
    std::fs::write(&temporary, serde_json::to_vec_pretty(settings)?)?;
    if target.exists() {
        std::fs::remove_file(&target)?;
    }
    std::fs::rename(temporary, target)?;
    Ok(())
}
struct Request {
    action: Action,
    reply: mpsc::Sender<Result<(), String>>,
}
pub struct Player {
    tx: mpsc::Sender<Request>,
    signals: Arc<Signals>,
    data: Arc<Mutex<Data>>,
    test: bool,
    root: PathBuf,
    settings_io: Arc<Mutex<()>>,
    scope_seen: Mutex<(u64, std::time::Instant)>,
}
impl Player {
    pub fn new(catalog: Arc<Catalog>, test: bool, capture: Option<PathBuf>) -> Self {
        let test = cfg!(debug_assertions) && test;
        let settings = std::fs::read(catalog.root.join("audio-settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Settings>(&b).ok())
            .filter(|s| {
                s.volume.is_finite() && (0.0..=100.0).contains(&s.volume) && !s.device_id.is_empty()
            })
            .unwrap_or_default();
        let signals = Arc::new(Signals::new(settings.volume));
        let equalizer = settings.equalizer.clone().clean();
        signals.eq.set(&equalizer);
        let data = Arc::new(Mutex::new(Data {
            selected_device: settings.device_id.clone(),
            equalizer,
            ..Default::default()
        }));
        let settings_io = Arc::new(Mutex::new(()));
        let worker_io = settings_io.clone();
        let root = catalog.root.clone();
        let (tx, rx) = mpsc::channel();
        let state = data.clone();
        let sig = signals.clone();
        std::thread::spawn(move || {
            Worker::new(catalog, settings, sig, state, test, capture, worker_io).run(rx)
        });
        Self {
            tx,
            signals,
            data,
            test,
            root,
            settings_io,
            scope_seen: Mutex::new((0, std::time::Instant::now())),
        }
    }
    /// Band levels of the sound leaving this computer now, for the seek bar display.
    /// `None` when nothing real is available: paused, buffering, a network receiver
    /// (DLNA decodes itself, AirPlay plays with seconds of delay) or a stalled device.
    pub fn levels(&self) -> Option<Vec<f32>> {
        if self.signals.paused.load(Ordering::Acquire) || !self.signals.ready.load(Ordering::Acquire) {
            return None;
        }
        let (rate, device) = {
            let data = self.data.lock().unwrap();
            (data.output.as_ref().map(|o| o.sample_rate)?, data.selected_device.clone())
        };
        if device.starts_with("airplay:") || device.starts_with("dlna:") {
            return None;
        }
        let head = self.signals.scope_head.load(Ordering::Acquire);
        {
            let mut seen = self.scope_seen.lock().unwrap();
            if head != seen.0 {
                *seen = (head, std::time::Instant::now());
            } else if seen.1.elapsed() > Duration::from_millis(300) {
                return None;
            }
        }
        spectrum::bands(&self.signals, rate)
    }
    pub fn flush_settings(&self) -> Result<()> {
        self.signals.paused.store(true, Ordering::Release);
        let (device_id, equalizer) = {
            let data = self.data.lock().unwrap();
            (data.selected_device.clone(), data.equalizer.clone())
        };
        let settings = Settings {
            device_id,
            volume: f32::from_bits(self.signals.gain.load(Ordering::Relaxed)) * 100.0,
            equalizer,
        };
        persist_settings(&self.root, &self.settings_io, &settings)
    }
    pub fn state(&self) -> State {
        let data = self.data.lock().unwrap();
        let active = self.signals.active.load(Ordering::Acquire);
        let current_id = data.ids.get(active).cloned();
        let index = data.order.iter().position(|i| *i == active).unwrap_or(0);
        let source = data.infos.get(active).cloned();
        let rate = data.output.as_ref().map(|o| o.sample_rate).unwrap_or(48000) as u64;
        State {
            available: cfg!(windows) || self.test,
            playing: current_id.is_some() && !self.signals.paused.load(Ordering::Acquire),
            completed: self.signals.completed.load(Ordering::Acquire),
            buffering: current_id.is_some()
                && !self.signals.ready.load(Ordering::Acquire)
                && !self.signals.paused.load(Ordering::Acquire),
            queue_ids: data
                .order
                .iter()
                .filter_map(|&i| data.ids.get(i).cloned())
                .collect(),
            index,
            current_id,
            position_ms: self.signals.position.load(Ordering::Acquire) * 1000 / rate,
            duration_ms: source.as_ref().map(|s| s.duration_ms).unwrap_or(0),
            volume: (f32::from_bits(self.signals.gain.load(Ordering::Relaxed)) * 100.0)
                .clamp(0.0, 100.0),
            repeat: data.repeat,
            shuffled: data.shuffled,
            source,
            output: data.output.clone(),
            selected_device: data.selected_device.clone(),
            error: data.error.clone(),
            error_serial: data.error_serial,
            underrun_frames: self.signals.underrun_frames.load(Ordering::Relaxed),
            rendered_frames: self.signals.rendered_frames.load(Ordering::Relaxed),
            revision: data.revision,
            equalizer: data.equalizer.clone(),
        }
    }
    pub fn devices(&self) -> Result<Vec<output::Device>> {
        output::devices(self.test)
    }
    pub fn command(&self, action: Action) -> Result<()> {
        match &action {
            Action::Load { ids, index } | Action::Restore { ids, index, .. } => {
                if ids.is_empty() || ids.len() > 10000 || *index >= ids.len() {
                    bail!("Nieprawidłowa kolejka.");
                }
                let mut unique = std::collections::HashSet::new();
                if ids.iter().any(|id| {
                    id.len() != 64
                        || !id.bytes().all(|b| b.is_ascii_hexdigit())
                        || !unique.insert(id)
                }) {
                    bail!("Kolejka zawiera nieprawidłowe lub powtórzone utwory.");
                }
            }
            Action::Volume { value } if !value.is_finite() || !(0.0..=100.0).contains(value) => {
                bail!("Głośność musi być od 0 do 100%.")
            }
            Action::Seek { position_ms } if *position_ms > 7 * 24 * 3600 * 1000 => {
                bail!("Nieprawidłowa pozycja.")
            }
            Action::Device { id } if id.is_empty() || id.len() > 4096 => {
                bail!("Nieprawidłowe urządzenie.")
            }
            _ => {}
        }
        let (reply, rx) = mpsc::channel();
        self.tx
            .send(Request { action, reply })
            .map_err(|_| anyhow!("Odtwarzacz jest zatrzymany."))?;
        rx.recv_timeout(Duration::from_secs(15))
            .map_err(|_| anyhow!("Odtwarzacz nie odpowiedział. Spróbuj ponownie."))?
            .map_err(anyhow::Error::msg)
    }
}
struct Worker {
    catalog: Arc<Catalog>,
    settings: Settings,
    signals: Arc<Signals>,
    data: Arc<Mutex<Data>>,
    test: bool,
    capture: Option<PathBuf>,
    output: Option<OutputHandle>,
    feeder: Option<Feeder>,
    rate: u32,
    source: Option<SequenceSource>,
    pending_frame: Option<TaggedFrame>,
    ended: bool,
    cursor: usize,
    seek_ms: u64,
    terminal_sent: bool,
    dirty: bool,
    last_save: Instant,
    settings_io: Arc<Mutex<()>>,
}
impl Worker {
    fn new(
        catalog: Arc<Catalog>,
        settings: Settings,
        signals: Arc<Signals>,
        data: Arc<Mutex<Data>>,
        test: bool,
        capture: Option<PathBuf>,
        settings_io: Arc<Mutex<()>>,
    ) -> Self {
        Self {
            catalog,
            settings,
            signals,
            data,
            test,
            capture,
            output: None,
            feeder: None,
            rate: 48000,
            source: None,
            pending_frame: None,
            ended: true,
            cursor: 0,
            seek_ms: 0,
            terminal_sent: true,
            dirty: false,
            last_save: Instant::now(),
            settings_io,
        }
    }
    fn error(&self, error: impl ToString) {
        let mut data = self.data.lock().unwrap();
        data.error = Some(error.to_string());
        data.error_serial += 1;
    }
    fn current_position(&self) -> u64 {
        self.signals.position.load(Ordering::Acquire) * 1000 / self.rate as u64
    }
    fn reset(&mut self, index: usize, ms: u64) {
        self.signals.ready.store(false, Ordering::Release);
        self.signals.completed.store(false, Ordering::Release);
        self.signals.epoch.fetch_add(1, Ordering::AcqRel);
        self.signals.active.store(index, Ordering::Release);
        self.signals
            .position
            .store(ms * self.rate as u64 / 1000, Ordering::Release);
        self.source = None;
        self.seek_ms = ms;
        self.terminal_sent = false;
        self.pending_frame = None;
        self.ended = false;
        if let Some(feeder) = &mut self.feeder {
            feeder.pushed = 0;
        }
    }
    fn ensure_output(&mut self) -> Result<()> {
        if self.output.is_none() {
            self.open_output(&self.settings.device_id.clone())?;
        }
        Ok(())
    }
    fn open_output(&mut self, id: &str) -> Result<()> {
        let was_paused = self.signals.paused.swap(true, Ordering::AcqRel);
        let result = (|| {
            let spec = output::select(id, self.test)?;
            let info = spec.info.clone();
            let (feeder, renderer) = render::pipe(info.sample_rate, self.signals.clone());
            let handle = output::open(spec, renderer, self.signals.clone(), self.capture.clone())?;
            self.output = Some(handle);
            self.feeder = Some(feeder);
            self.rate = info.sample_rate;
            self.data.lock().unwrap().output = Some(info);
            Ok(())
        })();
        // On failure the previous output is kept paused; never silently route to a different device.
        if result.is_ok() {
            self.signals.ready.store(false, Ordering::Release);
            self.signals.device_failed.store(false, Ordering::Release);
            self.signals.paused.store(was_paused, Ordering::Release);
        }
        result
    }
    fn restart_current(&mut self, ms: u64) {
        let current = self.signals.active.load(Ordering::Acquire);
        let cursor = self
            .data
            .lock()
            .unwrap()
            .order
            .iter()
            .position(|i| *i == current);
        if let Some(cursor) = cursor {
            self.cursor = cursor;
            self.reset(current, ms);
        }
    }
    fn apply(&mut self, action: Action) -> Result<()> {
        match action {
            Action::Restore {
                ids,
                index,
                position_ms,
                playing,
            } => {
                self.apply(Action::Load { ids, index })?;
                self.apply(Action::Seek { position_ms })?;
                if !playing {
                    self.apply(Action::Pause)?;
                }
            }
            Action::Load { ids, index } => {
                let tracks = self.catalog.tracks()?;
                let by_id: std::collections::HashMap<_, _> =
                    tracks.into_iter().map(|t| (t.id.clone(), t)).collect();
                if ids.iter().any(|id| !by_id.contains_key(id)) {
                    bail!("W kolejce jest utwór spoza biblioteki. Odśwież listę.");
                }
                self.ensure_output()?;
                {
                    let mut data = self.data.lock().unwrap();
                    data.infos = ids
                        .iter()
                        .map(|id| SourceInfo {
                            duration_ms: by_id[id].duration_ms.max(0) as u64,
                            ..Default::default()
                        })
                        .collect();
                    data.order = (0..ids.len()).collect();
                    data.ids = ids;
                    data.shuffled = false;
                    data.error = None;
                    data.revision += 1;
                }
                self.cursor = index;
                self.reset(index, 0);
                self.signals.paused.store(false, Ordering::Release);
            }
            Action::Play => {
                let previous_position = self.current_position();
                self.ensure_output()?;
                if self.data.lock().unwrap().ids.is_empty() {
                    bail!("Najpierw wybierz utwór.");
                }
                if self.signals.completed.load(Ordering::Acquire) {
                    self.restart_current(0);
                } else if self.source.is_none()
                    && self.terminal_sent
                    && !self.signals.ready.load(Ordering::Acquire)
                {
                    self.restart_current(previous_position);
                }
                self.signals.paused.store(false, Ordering::Release);
            }
            Action::Pause => {
                self.signals.paused.store(true, Ordering::Release);
            }
            Action::Stop => {
                self.signals.paused.store(true, Ordering::Release);
                self.signals.ready.store(false, Ordering::Release);
                self.signals.epoch.fetch_add(1, Ordering::AcqRel);
                self.signals.completed.store(false, Ordering::Release);
                self.signals.active.store(usize::MAX, Ordering::Release);
                self.signals.position.store(0, Ordering::Release);
                self.source = None;
                self.pending_frame = None;
                self.ended = true;
                self.terminal_sent = true;
                let mut data = self.data.lock().unwrap();
                data.ids.clear();
                data.order.clear();
                data.infos.clear();
                data.shuffled = false;
                data.revision += 1;
            }
            Action::Seek { position_ms } => {
                let active = self.signals.active.load(Ordering::Acquire);
                let duration = self
                    .data
                    .lock()
                    .unwrap()
                    .infos
                    .get(active)
                    .map(|s| s.duration_ms)
                    .unwrap_or(0);
                let position = if duration > 0 {
                    position_ms.min(duration.saturating_sub(1))
                } else {
                    position_ms
                };
                self.restart_current(position);
            }
            Action::Next | Action::Previous => {
                let data = self.data.lock().unwrap();
                let active = self.signals.active.load(Ordering::Acquire);
                let current = data
                    .order
                    .iter()
                    .position(|i| *i == active)
                    .ok_or_else(|| anyhow!("Kolejka jest pusta."))?;
                let previous = matches!(action, Action::Previous);
                let next = if previous {
                    if self.current_position() > 3000 {
                        current
                    } else if current > 0 {
                        current - 1
                    } else if data.repeat {
                        data.order.len() - 1
                    } else {
                        0
                    }
                } else if current + 1 < data.order.len() {
                    current + 1
                } else if data.repeat {
                    0
                } else {
                    drop(data);
                    self.signals.paused.store(true, Ordering::Release);
                    self.signals.completed.store(true, Ordering::Release);
                    self.signals.epoch.fetch_add(1, Ordering::AcqRel);
                    self.source = None;
                    self.terminal_sent = true;
                    return Ok(());
                };
                let index = data.order[next];
                drop(data);
                self.cursor = next;
                self.reset(index, 0);
                self.signals.paused.store(false, Ordering::Release);
            }
            Action::Jump { id } => {
                let data = self.data.lock().unwrap();
                let base = data
                    .ids
                    .iter()
                    .position(|i| i == &id)
                    .ok_or_else(|| anyhow!("Utworu nie ma w kolejce."))?;
                let cursor = data.order.iter().position(|i| *i == base).unwrap();
                drop(data);
                self.cursor = cursor;
                self.reset(base, 0);
                self.signals.paused.store(false, Ordering::Release);
            }
            Action::Equalizer { enabled, gains } => {
                let eq = eq::Equalizer { enabled, gains }.clean();
                self.signals.eq.set(&eq);
                self.data.lock().unwrap().equalizer = eq.clone();
                self.settings.equalizer = eq;
                self.dirty = true;
            }
            Action::Volume { value } => {
                self.settings.volume = value;
                self.signals
                    .gain
                    .store((value / 100.0).to_bits(), Ordering::Release);
                self.dirty = true;
            }
            Action::Repeat { value } => {
                self.data.lock().unwrap().repeat = value;
                if !self.signals.completed.load(Ordering::Acquire) {
                    self.restart_current(self.current_position());
                }
            }
            Action::Shuffle { value } => {
                let position = self.current_position();
                let active = self.signals.active.load(Ordering::Acquire);
                let mut data = self.data.lock().unwrap();
                data.shuffled = value;
                data.order = (0..data.ids.len()).collect();
                if value {
                    let bytes = getrandom_bytes()?;
                    let mut rng = u64::from_le_bytes(bytes[..8].try_into().unwrap()).max(1);
                    let mut remaining: Vec<_> = data
                        .order
                        .iter()
                        .copied()
                        .filter(|i| *i != active)
                        .collect();
                    for i in (1..remaining.len()).rev() {
                        rng ^= rng << 13;
                        rng ^= rng >> 7;
                        rng ^= rng << 17;
                        remaining.swap(i, rng as usize % (i + 1));
                    }
                    if active < data.ids.len() {
                        remaining.insert(0, active);
                    }
                    data.order = remaining;
                }
                data.revision += 1;
                drop(data);
                self.restart_current(position);
            }
            Action::Device { id } => {
                let position = self.current_position();
                let paused = self.signals.paused.load(Ordering::Acquire);
                self.open_output(&id)?;
                self.settings.device_id = id.clone();
                {
                    let mut data = self.data.lock().unwrap();
                    data.selected_device = id;
                    data.error = None;
                    data.revision += 1;
                }
                self.restart_current(position);
                self.signals.paused.store(paused, Ordering::Release);
                self.dirty = true;
            }
        }
        Ok(())
    }
    fn produce(&mut self) -> Result<bool> {
        if self.terminal_sent || self.feeder.is_none() {
            return Ok(false);
        }
        let Some(mut block) = self.feeder.as_mut().unwrap().take() else {
            return Ok(false);
        };
        block.len = 0;
        block.terminal = false;
        block.epoch = self.signals.epoch.load(Ordering::Acquire);
        if self.source.is_none() && !self.ended {
            self.source = SequenceSource::open(
                self.catalog.clone(),
                self.data.clone(),
                self.cursor,
                self.seek_ms,
                self.rate,
            )?;
            self.ended = self.source.is_none();
        }
        while block.len < BLOCK {
            let next = if let Some(frame) = self.pending_frame.take() {
                Some(frame)
            } else if !self.ended {
                match self.source.as_mut().unwrap().next() {
                    Ok(v) => {
                        if v.is_none() {
                            self.ended = true;
                        }
                        v
                    }
                    Err(e) => {
                        self.error(format!("Błąd odtwarzania: {e:#}"));
                        self.ended = true;
                        None
                    }
                }
            } else {
                None
            };
            let Some(frame) = next else {
                break;
            };
            if block.len == 0 {
                block.track = frame.index;
                block.start = frame.position;
            } else if frame.index != block.track || frame.position != block.start + block.len as u64
            {
                self.pending_frame = Some(frame);
                break;
            }
            block.samples[block.len] = frame.sample;
            block.len += 1;
        }
        if block.len == 0 && self.ended {
            block.terminal = true;
            self.terminal_sent = true;
        }
        self.feeder.as_mut().unwrap().send(block);
        if self.feeder.as_ref().unwrap().pushed >= 4 || self.terminal_sent {
            self.signals.ready.store(true, Ordering::Release);
        }
        Ok(true)
    }
    fn save_settings(&mut self) {
        if !self.dirty {
            return;
        }
        let result = persist_settings(&self.catalog.root, &self.settings_io, &self.settings);
        if let Err(e) = result {
            self.error(format!("Nie zapisano ustawień audio: {e}"));
        }
        self.dirty = false;
        self.last_save = Instant::now();
    }
    fn run(mut self, rx: mpsc::Receiver<Request>) {
        loop {
            loop {
                match rx.try_recv() {
                    Ok(request) => {
                        let result = self.apply(request.action);
                        if let Err(e) = &result {
                            self.error(e);
                            self.signals.paused.store(true, Ordering::Release);
                        }
                        let _ = request.reply.send(result.map_err(|e| format!("{e:#}")));
                    }
                    Err(mpsc::TryRecvError::Disconnected) => {
                        self.save_settings();
                        return;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                }
            }
            if self.signals.device_failed.swap(false, Ordering::AcqRel) {
                self.signals.paused.store(true, Ordering::Release);
                self.error(
                    "Utracono wyjście audio. Wybierz urządzenie ponownie w ustawieniach dźwięku.",
                );
                self.output = None;
                self.feeder = None;
                self.source = None;
                self.pending_frame = None;
                self.ended = true;
                self.terminal_sent = true;
                self.data.lock().unwrap().output = None;
            }
            if self.dirty && self.last_save.elapsed() > Duration::from_millis(400) {
                self.save_settings();
            }
            match self.produce() {
                Ok(true) => {}
                Ok(false) => std::thread::sleep(Duration::from_millis(2)),
                Err(e) => {
                    self.error(e);
                    self.signals.paused.store(true, Ordering::Release);
                    self.source = None;
                    self.terminal_sent = true;
                }
            }
        }
    }
}

pub fn device(id: &str, name: &str) -> output::Device {
    output::Device {
        id: id.into(),
        name: name.into(),
    }
}
