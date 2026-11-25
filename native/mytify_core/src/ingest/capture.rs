use super::*;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::Sample;
use rtrb::{Producer, RingBuffer};
use std::{sync::atomic::Ordering, time::Duration};
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
    if s.failed.load(Ordering::Relaxed) || s.stop.load(Ordering::Relaxed) {
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
pub fn run(engine: &Ingest, args: &Value, record: bool) -> Result<()> {
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
        s.input_format = format!("{:?}", config.sample_format());
        s.recording = record;
    }
    if record {
        std::fs::write(
            dir.join("session.json"),
            serde_json::to_vec_pretty(
                &json!({"label":args["label"],"rate":rate,"channels":channels,"inputFormat":format!("{:?}",config.sample_format()),"containerBits":24,"markers":[]}),
            )?,
        )?;
    }
    let (mut tx, mut rx) = RingBuffer::<Packet>::new(256);
    let signals = engine.signals.clone();
    let sig = signals.clone();
    let on_error = move |_e| {
        sig.failed.store(true, Ordering::Release);
    };
    let stream = match config.sample_format() {
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
    };
    stream.play()?;
    let mut buffer = Vec::with_capacity(3072);
    let mut disk_error = None;
    let mut last_sync = std::time::Instant::now();
    while !engine.signals.stop.load(Ordering::Acquire)
        && !engine.signals.failed.load(Ordering::Acquire)
    {
        while let Ok(p) = rx.pop() {
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
    drop(stream);
    while let Ok(p) = rx.pop() {
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
    if let Some(mut w) = wav {
        if disk_error.is_none() {
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
                    &json!({"label":args["label"],"rate":rate,"channels":channels,"inputFormat":s.input_format,"containerBits":24,"markers":s.markers,"frames":frames,"dropouts":engine.signals.dropped.load(Ordering::Acquire),"clips":engine.signals.clips.load(Ordering::Acquire)}),
                )?,
            )?;
        }
    }
    if let Some(e) = disk_error {
        bail!("Błąd zapisu: {e}. Zachowano plik częściowy do odzyskania.")
    }
    if engine.signals.failed.load(Ordering::Acquire) {
        bail!("Nagranie zatrzymano po błędzie wejścia lub utracie próbek ({}). Zachowano zapisany fragment, bez ukrywania przerwy.",engine.signals.dropped.load(Ordering::Acquire))
    }
    Ok(())
}
