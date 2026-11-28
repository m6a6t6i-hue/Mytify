use super::*;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::Sample;
use rtrb::{Producer, RingBuffer};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
struct Packet {
    samples: [f32; 1024],
    len: usize,
}
fn device(id: &str) -> Result<cpal::Device> {
    let h = cpal::default_host();
    if id == "auto" {
        h.default_input_device()
    } else {
        h.device_by_id(&id.parse::<cpal::DeviceId>()?)
    }
    .ok_or_else(|| anyhow!("Wejście audio jest niedostępne"))
}
pub fn inputs() -> Result<Value> {
    let h = cpal::default_host();
    let mut list = Vec::new();
    for d in h.input_devices()? {
        let configs = d
            .supported_input_configs()?
            .filter(|c| {
                c.channels() <= 2
                    && matches!(
                        c.sample_format(),
                        cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::I32
                    )
            })
            .collect::<Vec<_>>();
        if configs.is_empty() {
            continue;
        }
        let rates = [44100, 48000, 96000, 192000]
            .into_iter()
            .filter(|r| {
                configs
                    .iter()
                    .any(|c| c.min_sample_rate() <= *r && c.max_sample_rate() >= *r)
            })
            .collect::<Vec<_>>();
        let channels = configs.iter().map(|c| c.channels()).max().unwrap_or(2);
        list.push(json!({"id":d.id()?.to_string(),"name":d.description()?.name(),"rates":rates,"channels":channels}));
    }
    Ok(json!(list))
}
fn push<T: cpal::Sample>(data: &[T], channels: usize, tx: &mut Producer<Packet>, s: &Signals)
where
    f32: cpal::FromSample<T>,
{
    let mut peak = 0f32;
    let mut per = [0f32; 2];
    let mut clips = 0;
    for (i, &v) in data.iter().enumerate() {
        let f = f32::from_sample(v);
        let p = if f.is_finite() { f.abs() } else { 1. };
        peak = peak.max(p.min(8.));
        let c = (i % channels.max(1)).min(1);
        per[c] = per[c].max(p.min(8.));
        if p >= 0.99997 {
            clips += 1;
        }
    }
    s.peak.fetch_max(peak.to_bits(), Ordering::Relaxed);
    for (slot, value) in s.peaks.iter().zip(per) {
        slot.fetch_max(value.to_bits(), Ordering::Relaxed);
    }
    s.clips.fetch_add(clips, Ordering::Relaxed);
    // Paused: the meter keeps working, nothing is recorded or counted.
    if s.failed.load(Ordering::Relaxed) || s.stop.load(Ordering::Relaxed) || s.paused.load(Ordering::Relaxed) {
        return;
    }
    let size = 1024 / channels * channels;
    for (index, chunk) in data.chunks(size).enumerate() {
        let mut p = Packet {
            samples: [0.; 1024],
            len: chunk.len() / channels * channels,
        };
        for (dest, &src) in p.samples.iter_mut().zip(chunk) {
            *dest = f32::from_sample(src);
        }
        let n = p.len / channels;
        if tx.push(p).is_err() {
            s.dropped.fetch_add(
                ((data.len() - index * size) / channels) as u64,
                Ordering::Relaxed,
            );
            s.failed.store(true, Ordering::Release);
            break;
        } else {
            s.frames.fetch_add(n as u64, Ordering::Release);
        }
    }
}
/// What feeds the recording: an input device, or one application's sound (a thread).
/// Dropping it always stops the source, also on an early error.
struct Source {
    stream: Option<cpal::Stream>,
    app: Option<(std::thread::JoinHandle<Result<()>>, Arc<AtomicBool>)>,
}
impl Source {
    /// Stops the source; an app source reports why it ended early, if it did.
    fn close(&mut self) -> Option<String> {
        self.stream.take();
        let (thread, quit) = self.app.take()?;
        quit.store(true, Ordering::Release);
        match thread.join() {
            Ok(Err(e)) => Some(e.to_string()),
            _ => None,
        }
    }
}
impl Drop for Source {
    fn drop(&mut self) {
        self.close();
    }
}

pub fn run(engine: &Ingest, args: &Value, record: bool) -> Result<()> {
    if let Some(app) = args["app"].as_str() {
        return run_app(engine, args, record, &app.to_lowercase());
    }
    let id = args["id"].as_str().unwrap_or("auto");
    let rate = args["rate"].as_u64().unwrap_or(48000) as u32;
    let d = device(id)?;
    let config = d
        .supported_input_configs()?
        .filter(|c| {
            c.channels() <= 2
                && c.min_sample_rate() <= rate
                && c.max_sample_rate() >= rate
                && matches!(
                    c.sample_format(),
                    cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::I32
                )
        })
        .max_by_key(|c| {
            (
                c.channels(),
                match c.sample_format() {
                    cpal::SampleFormat::F32 => 3,
                    cpal::SampleFormat::I32 => 2,
                    _ => 1,
                },
            )
        })
        .ok_or_else(|| anyhow!("Wejście nie obsługuje wybranej częstotliwości w mono/stereo"))?
        .with_sample_rate(rate);
    let channels = config.channels();
    let format = format!("{:?}", config.sample_format());
    let (tx, rx) = RingBuffer::<Packet>::new(256);
    let stream = device_stream(&d, &config, tx, engine)?;
    write(engine, args, record, rate, channels, &format, rx, Source { stream: Some(stream), app: None })
}

#[cfg(feature = "desktop")]
fn run_app(engine: &Ingest, args: &Value, record: bool, app: &str) -> Result<()> {
    // Most streaming apps decode at 44.1 kHz; Windows converts if the app uses another rate.
    let rate = if args["rate"].as_u64() == Some(48000) { 48000 } else { 44100 };
    let (mut tx, rx) = RingBuffer::<Packet>::new(512);
    let quit = Arc::new(AtomicBool::new(false));
    let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
    let signals = engine.signals.clone();
    let (q, id) = (quit.clone(), app.to_string());
    let thread = std::thread::spawn(move || {
        super::app_capture::run(&id, rate, q, ready_tx, |data| push(data, 2, &mut tx, &signals))
    });
    match ready_rx.recv_timeout(Duration::from_secs(8)) {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            let _ = thread.join();
            return Err(e);
        }
        Err(_) => {
            quit.store(true, Ordering::Release);
            bail!("Windows nie otworzył dźwięku aplikacji.")
        }
    }
    write(engine, args, record, rate, 2, "Aplikacja (32-bit float)", rx, Source { stream: None, app: Some((thread, quit)) })
}

#[cfg(not(feature = "desktop"))]
fn run_app(_: &Ingest, _: &Value, _: bool, _: &str) -> Result<()> {
    bail!("Nagrywanie z aplikacji działa w wersji Windows")
}

fn device_stream(d: &cpal::Device, config: &cpal::SupportedStreamConfig, mut tx: Producer<Packet>, engine: &Ingest) -> Result<cpal::Stream> {
    let channels = config.channels();
    let signals = engine.signals.clone();
    let sig = signals.clone();
    let on_error = move |_e| {
        sig.failed.store(true, Ordering::Release);
    };
    Ok(match config.sample_format() {
        cpal::SampleFormat::F32 => d.build_input_stream(
            config.config(),
            move |data: &[f32], _| push(data, channels as usize, &mut tx, &signals),
            on_error,
            None,
        )?,
        cpal::SampleFormat::I16 => d.build_input_stream(
            config.config(),
            move |data: &[i16], _| push(data, channels as usize, &mut tx, &signals),
            on_error,
            None,
        )?,
        cpal::SampleFormat::I32 => d.build_input_stream(
            config.config(),
            move |data: &[i32], _| push(data, channels as usize, &mut tx, &signals),
            on_error,
            None,
        )?,
        _ => bail!("Nieobsługiwany format wejścia"),
    })
}

/// Writes what the source delivers into the session's master file.
#[allow(clippy::too_many_arguments)]
fn write(
    engine: &Ingest,
    args: &Value,
    record: bool,
    rate: u32,
    channels: u16,
    format: &str,
    mut rx: rtrb::Consumer<Packet>,
    mut source: Source,
) -> Result<()> {
    let session = hex(getrandom_bytes()?);
    let dir = engine.root().join(&session);
    let partial = dir.join("master.wav.partial");
    let mut wav = if record {
        std::fs::create_dir_all(&dir)?;
        Some(wav::Wav::create(&partial, rate, channels, 24)?)
    } else {
        None
    };
    {
        let mut s = engine.state.lock().unwrap();
        s.session = session;
        s.rate = rate;
        s.channels = channels;
        s.input_format = format.to_string();
        s.recording = record;
    }
    if record {
        std::fs::write(
            dir.join("session.json"),
            serde_json::to_vec_pretty(
                &json!({"label":args["label"],"rate":rate,"channels":channels,"inputFormat":format,"app":args["app"],"containerBits":24,"markers":[]}),
            )?,
        )?;
    }
    if let Some(stream) = &source.stream {
        stream.play()?;
    }
    let mut buffer = Vec::with_capacity(3072);
    let mut disk_error = None;
    let mut last_sync = std::time::Instant::now();
    // End of a side: this many seconds below -50 dBFS after at least 30 s of recording.
    let auto_stop = args["autoStop"].as_u64().filter(|s| *s >= 3 && *s <= 120);
    let mut written: u64 = 0;
    let mut quiet_since: Option<u64> = None;
    let mut auto_ended = false;
    // App recordings start with the first sound (pressing play in the app after
    // starting here leaves no silence at the front) and may end at the album's length.
    let mut heard = !(record && args["waitForSound"].as_bool().unwrap_or(false));
    if !heard {
        engine.state.lock().unwrap().step = "Czekam na dźwięk z aplikacji. Włącz album od pierwszego utworu.".into();
    }
    let max_frames = args["maxMs"].as_u64().filter(|ms| *ms >= 10_000).map(|ms| ms * rate as u64 / 1000);
    // With the album's length known, a quiet stretch inside the album (a fade-out
    // followed by a quiet intro, a slow buffer in the app) does not end it: only the
    // last half minute ends on silence, or a long pause (playback stopped) anywhere.
    let album_end = max_frames.map(|m| m.saturating_sub(rate as u64 * 45));
    const LONG_PAUSE_S: u64 = 90;
    while !engine.signals.stop.load(Ordering::Acquire)
        && !engine.signals.failed.load(Ordering::Acquire)
        && !auto_ended
    {
        while let Ok(p) = rx.pop() {
            if !heard {
                let peak = p.samples[..p.len].iter().fold(0f32, |m, x| m.max(x.abs()));
                engine.signals.frames.store(0, Ordering::Release);
                if peak < 0.001 {
                    continue;
                }
                heard = true;
                engine.state.lock().unwrap().step.clear();
            }
            if max_frames.is_some_and(|m| written >= m) {
                auto_ended = true;
                engine.state.lock().unwrap().ended = "length".into();
                break;
            }
            if let (Some(limit), true) = (auto_stop, record) {
                let peak = p.samples[..p.len].iter().fold(0f32, |m, x| m.max(x.abs()));
                if peak < 0.00316 {
                    quiet_since.get_or_insert(written);
                } else {
                    quiet_since = None;
                }
                if let Some(q) = quiet_since {
                    let inside_album = album_end.is_some_and(|end| written < end);
                    let limit = if inside_album { LONG_PAUSE_S } else { limit };
                    if written > rate as u64 * 30 && written - q > rate as u64 * limit {
                        auto_ended = true;
                    }
                }
            }
            written += (p.len / channels as usize) as u64;
            if let Some(w) = wav.as_mut() {
                buffer.clear();
                for x in &p.samples[..p.len] {
                    let sample = if x.is_finite() {
                        (*x as f64 * 8388608.).round().clamp(-8388608., 8388607.) as i32
                    } else {
                        0
                    };
                    buffer.extend_from_slice(&sample.to_le_bytes()[..3]);
                }
                if let Err(e) = w.write(&buffer) {
                    disk_error = Some(e);
                    break;
                }
            }
        }
        if disk_error.is_some() {
            break;
        }
        if last_sync.elapsed() > Duration::from_secs(2) {
            if let Some(w) = wav.as_mut() {
                if let Err(e) = w.file.sync_data() {
                    disk_error = Some(e.into());
                    break;
                }
            }
            last_sync = std::time::Instant::now();
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    let source_error = source.close();
    while let Ok(p) = rx.pop() {
        if !heard || auto_ended {
            break;
        }
        if disk_error.is_none() {
            if let Some(w) = wav.as_mut() {
                buffer.clear();
                for x in &p.samples[..p.len] {
                    let sample = if x.is_finite() {
                        (*x as f64 * 8388608.).round().clamp(-8388608., 8388607.) as i32
                    } else {
                        0
                    };
                    buffer.extend_from_slice(&sample.to_le_bytes()[..3]);
                }
                if let Err(e) = w.write(&buffer) {
                    disk_error = Some(e);
                }
            }
        }
    }
    if record && !heard {
        drop(wav);
        let _ = std::fs::remove_dir_all(&dir);
        if let Some(e) = source_error {
            bail!("{e}")
        }
        bail!("Z aplikacji nie popłynął żaden dźwięk. Nic nie zapisano.")
    }
    if let Some(mut w) = wav {
        if disk_error.is_none() {
            if auto_ended && engine.state.lock().unwrap().ended != "length" {
                // Keep one second of the closing silence.
                if let Some(q) = quiet_since {
                    w.truncate(q + rate as u64)?;
                }
                engine.state.lock().unwrap().ended = "silence".into();
            }
            w.finish()?;
            let frames = w.frames();
            drop(w);
            std::fs::rename(&partial, dir.join("master.wav"))?;
            let mut s = engine.state.lock().unwrap();
            s.frames = frames;
            s.files
                .push(dir.join("master.wav").to_string_lossy().into_owned());
            std::fs::write(
                dir.join("session.json"),
                serde_json::to_vec_pretty(
                    &json!({"label":args["label"],"rate":rate,"channels":channels,"inputFormat":s.input_format,"app":args["app"],"containerBits":24,"markers":s.markers,"frames":frames,"dropouts":engine.signals.dropped.load(Ordering::Acquire),"clips":engine.signals.clips.load(Ordering::Acquire)}),
                )?,
            )?;
        }
    }
    if let Some(e) = disk_error {
        bail!("Błąd zapisu: {e}. Zachowano plik częściowy do odzyskania.")
    }
    if let Some(e) = source_error {
        bail!("{e} Zachowano nagrany fragment.")
    }
    if engine.signals.failed.load(Ordering::Acquire) {
        bail!("Nagranie zatrzymano po błędzie wejścia lub utracie próbek ({}). Zachowano zapisany fragment, bez ukrywania przerwy.",engine.signals.dropped.load(Ordering::Acquire))
    }
    Ok(())
}
