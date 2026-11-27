//! One pass over a WAV range: optional restoration of a copy (hum notch, declick,
//! tape speed), FLAC and optional MP3 output, and loudness for ReplayGain.
//! The source WAV is only read, never changed.
use super::loudness::Loudness;
use super::wav::Wav;
use anyhow::{anyhow, bail, Result};
use flacenc::{
    bitsink::ByteSink,
    component::{BitRepr, Stream},
    error::Verify,
    source::{Fill, FrameBuf},
};
use md5::Digest;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
};

/// Restoration applied to the exported copy. All off by default.
#[derive(Clone, Debug, PartialEq)]
pub struct Restore {
    /// Mains hum frequency to notch out with its first harmonics (50 or 60 Hz).
    pub hum: Option<f64>,
    /// Remove short clicks and pops (vinyl).
    pub declick: bool,
    /// Playback speed correction, e.g. 1.015 when the tape ran 1.5% slow.
    pub speed: f64,
}
impl Default for Restore {
    fn default() -> Self {
        Self { hum: None, declick: false, speed: 1.0 }
    }
}
impl Restore {
    pub fn from_json(v: &serde_json::Value) -> Result<Self> {
        let hum = match v["hum"].as_f64() {
            None => None,
            Some(f) if f == 50.0 || f == 60.0 => Some(f),
            Some(_) => bail!("Filtr brumu: 50 lub 60 Hz"),
        };
        let speed = v["speed"].as_f64().unwrap_or(1.0);
        if !(0.9..=1.1).contains(&speed) {
            bail!("Korekta prędkości mieści się w zakresie ±10%")
        }
        Ok(Self { hum, declick: v["declick"].as_bool().unwrap_or(false), speed })
    }
    pub fn active(&self) -> bool {
        self.hum.is_some() || self.declick || (self.speed - 1.0).abs() > 1e-6
    }
}

#[derive(Clone, Copy)]
struct Notch {
    b: [f64; 3],
    a: [f64; 2],
    z: [f64; 2],
}
impl Notch {
    fn new(rate: f64, f0: f64, q: f64) -> Self {
        let w = 2.0 * std::f64::consts::PI * f0 / rate;
        let alpha = w.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        Self {
            b: [1.0 / a0, -2.0 * w.cos() / a0, 1.0 / a0],
            a: [-2.0 * w.cos() / a0, (1.0 - alpha) / a0],
            z: [0.0; 2],
        }
    }
    fn run(&mut self, x: f64) -> f64 {
        let y = self.b[0] * x + self.z[0];
        self.z[0] = self.b[1] * x - self.a[0] * y + self.z[1];
        self.z[1] = self.b[2] * x - self.a[1] * y;
        y
    }
}

/// Click repair: a sample whose second-order prediction error is far above the
/// local error level starts a click; up to ~1.5 ms is replaced by interpolation.
struct Declick {
    history: [f64; 2],
    level: f64,
    max_len: usize,
}
impl Declick {
    fn new(rate: u32) -> Self {
        Self { history: [0.0; 2], level: 1e-4, max_len: (rate as usize * 3 / 2000).max(4) }
    }
    fn run(&mut self, x: &mut [f64]) -> usize {
        let h = self.history;
        // Sample k of this block, reaching back into the previous block for k < 0.
        let at = |x: &[f64], k: isize| -> f64 {
            if k >= 0 {
                x[k as usize]
            } else if k == -1 {
                h[1]
            } else {
                h[0]
            }
        };
        let mut repaired = 0;
        let mut i = 0usize;
        while i < x.len() {
            let k = i as isize;
            let e = (x[i] - (2.0 * at(x, k - 1) - at(x, k - 2))).abs();
            if e > self.level * 10.0 && e > 0.02 {
                // Find where the signal returns to the predicted path.
                let before = at(x, k - 1);
                let mut end = i + 1;
                while end < x.len() && end - i < self.max_len {
                    let q = end as isize;
                    let pred = 2.0 * at(x, q - 1) - at(x, q - 2);
                    if (x[end] - pred).abs() < (self.level * 4.0).max(e * 0.1) {
                        break;
                    }
                    end += 1;
                }
                if end < x.len() && end - i < self.max_len {
                    let after = x[end];
                    let span = (end - i + 1) as f64;
                    for (n, v) in x[i..end].iter_mut().enumerate() {
                        *v = before + (after - before) * ((n + 1) as f64 / span);
                    }
                    repaired += 1;
                    i = end;
                    continue;
                }
            }
            self.level = self.level * 0.999 + e.min(0.05) * 0.001;
            i += 1;
        }
        let n = x.len();
        if n >= 2 {
            self.history = [x[n - 2], x[n - 1]];
        } else if n == 1 {
            self.history = [h[1], x[0]];
        }
        repaired
    }
}

pub struct Outputs<'a> {
    /// Lossless copy; None when only MP3 is wanted (recordings of a lossy stream).
    pub flac: Option<&'a Path>,
    pub mp3: Option<&'a Path>,
    /// MP3 bitrate in kb/s (192 or 320).
    pub mp3_kbps: u32,
    pub restore: Restore,
    /// Share of this part already written (0..1, f32 bits), for the progress bar.
    pub progress: Option<&'a std::sync::atomic::AtomicU32>,
}

pub struct Encoded {
    pub loudness: Loudness,
    pub clicks: usize,
    pub frames: u64,
}

struct Flac {
    file: File,
    info: flacenc::component::StreamInfo,
    config: flacenc::error::Verified<flacenc::config::Encoder>,
    md5: md5::Md5,
    channels: usize,
    bits: usize,
    pending: Vec<i32>,
    number: usize,
}
impl Flac {
    fn new(path: &Path, rate: u32, channels: usize, bits: usize) -> Result<Self> {
        let info = flacenc::component::StreamInfo::new(rate as usize, channels, bits).map_err(|e| anyhow!("{e}"))?;
        let config = flacenc::config::Encoder::default().into_verified().map_err(|e| anyhow!("{e:?}"))?;
        let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
        file.write_all(&Self::header(&info)?)?;
        Ok(Self { file, info, config, md5: md5::Md5::new(), channels, bits, pending: Vec::new(), number: 0 })
    }
    fn header(i: &flacenc::component::StreamInfo) -> Result<Vec<u8>> {
        let mut sink = ByteSink::new();
        Stream::with_stream_info(i.clone()).write(&mut sink)?;
        Ok(sink.as_slice().to_vec())
    }
    fn push(&mut self, samples: &[i32]) -> Result<()> {
        self.pending.extend_from_slice(samples);
        let block = 4096 * self.channels;
        while self.pending.len() >= block {
            let rest = self.pending.split_off(block);
            let chunk = std::mem::replace(&mut self.pending, rest);
            self.frame(&chunk)?;
        }
        Ok(())
    }
    fn frame(&mut self, chunk: &[i32]) -> Result<()> {
        let bytes = self.bits / 8;
        for s in chunk {
            self.md5.update(&s.to_le_bytes()[..bytes]);
        }
        let mut buf = FrameBuf::with_size(self.channels, 4096).map_err(|e| anyhow!("{e}"))?;
        buf.fill_interleaved(chunk).map_err(|e| anyhow!("{e}"))?;
        let frame = flacenc::encode_fixed_size_frame(&self.config, &buf, self.number, &self.info)
            .map_err(|e| anyhow!("{e}"))?;
        self.info.update_frame_info(&frame);
        let mut sink = ByteSink::new();
        frame.write(&mut sink)?;
        self.file.write_all(sink.as_slice())?;
        self.number += 1;
        Ok(())
    }
    fn finish(mut self) -> Result<()> {
        if !self.pending.is_empty() {
            let chunk = std::mem::take(&mut self.pending);
            self.frame(&chunk)?;
        }
        self.info.set_block_sizes(4096, 4096).map_err(|e| anyhow!("{e}"))?;
        self.info.set_md5_digest(&self.md5.finalize().into());
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(&Self::header(&self.info)?)?;
        self.file.sync_all()?;
        Ok(())
    }
}

struct Mp3 {
    file: File,
    encoder: mp3lame_encoder::Encoder,
    channels: usize,
    buffer: Vec<u8>,
}
impl Mp3 {
    fn new(path: &Path, rate: u32, channels: usize, kbps: u32) -> Result<Self> {
        use mp3lame_encoder::{Bitrate, Builder, Quality};
        let mut b = Builder::new().ok_or_else(|| anyhow!("Koder MP3 niedostępny"))?;
        b.set_num_channels(channels as u8).map_err(|e| anyhow!("MP3: {e:?}"))?;
        b.set_sample_rate(rate).map_err(|e| anyhow!("MP3: {e:?}"))?;
        if rate > 48000 {
            b.set_output_sample_rate(std::num::NonZeroU32::new(48000)).map_err(|e| anyhow!("MP3: {e:?}"))?;
        }
        b.set_brate(if kbps >= 320 { Bitrate::Kbps320 } else { Bitrate::Kbps192 }).map_err(|e| anyhow!("MP3: {e:?}"))?;
        b.set_quality(if kbps >= 320 { Quality::Best } else { Quality::Good }).map_err(|e| anyhow!("MP3: {e:?}"))?;
        let encoder = b.build().map_err(|e| anyhow!("MP3: {e:?}"))?;
        let file = OpenOptions::new().write(true).create_new(true).open(path)?;
        Ok(Self { file, encoder, channels, buffer: Vec::new() })
    }
    fn push(&mut self, pcm: &[i16]) -> Result<()> {
        self.buffer.clear();
        self.buffer.reserve(mp3lame_encoder::max_required_buffer_size(pcm.len() / self.channels));
        if self.channels == 1 {
            self.encoder
                .encode_to_vec(mp3lame_encoder::MonoPcm(pcm), &mut self.buffer)
                .map_err(|e| anyhow!("MP3: {e:?}"))?;
        } else {
            self.encoder
                .encode_to_vec(mp3lame_encoder::InterleavedPcm(pcm), &mut self.buffer)
                .map_err(|e| anyhow!("MP3: {e:?}"))?;
        }
        self.file.write_all(&self.buffer)?;
        Ok(())
    }
    fn finish(mut self) -> Result<()> {
        self.buffer.clear();
        self.buffer.reserve(7200);
        self.encoder
            .flush_to_vec::<mp3lame_encoder::FlushNoGap>(&mut self.buffer)
            .map_err(|e| anyhow!("MP3: {e:?}"))?;
        self.file.write_all(&self.buffer)?;
        self.file.sync_all()?;
        Ok(())
    }
}

/// Encodes frames `start..end` of `input`.
pub fn encode(input: &Path, start: u64, end: u64, out: &Outputs, cancel: &AtomicBool) -> Result<Encoded> {
    let mut wav = Wav::read(input)?;
    if start >= end || end > wav.frames() {
        bail!("Nieprawidłowy podział nagrania")
    }
    let channels = wav.channels as usize;
    let bits = wav.bits as usize;
    let bytes = bits / 8;
    let rate = wav.rate;
    let full = (1i64 << (bits - 1)) as f64;
    if out.flac.is_none() && out.mp3.is_none() {
        bail!("Nie wybrano formatu zapisu")
    }
    let mut flac = match out.flac {
        Some(p) => Some(Flac::new(p, rate, channels, bits)?),
        None => None,
    };
    let mut mp3 = match out.mp3 {
        Some(p) => Some(Mp3::new(p, rate, channels, out.mp3_kbps)?),
        None => None,
    };
    let mut loudness = Loudness::new(rate, channels);
    let restore = &out.restore;
    let mut notches: Vec<Vec<Notch>> = (0..channels)
        .map(|_| match restore.hum {
            Some(f) => [1.0, 2.0, 3.0]
                .iter()
                .filter(|h| f * *h < rate as f64 / 2.0)
                .map(|h| Notch::new(rate as f64, f * h, 30.0))
                .collect(),
            None => Vec::new(),
        })
        .collect();
    let mut declick: Vec<Declick> = (0..channels).map(|_| Declick::new(rate)).collect();
    let speed = (restore.speed - 1.0).abs() > 1e-6;
    let mut resampler = if speed {
        use rubato::{SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction};
        Some(
            SincFixedIn::<f64>::new(
                1.0 / restore.speed,
                1.0,
                SincInterpolationParameters {
                    sinc_len: 128,
                    f_cutoff: 0.95,
                    oversampling_factor: 128,
                    interpolation: SincInterpolationType::Cubic,
                    window: WindowFunction::BlackmanHarris2,
                },
                4096,
                channels,
            )
            .map_err(|e| anyhow!("Korekta prędkości: {e}"))?,
        )
    } else {
        None
    };
    let mut clicks = 0;
    let mut written = 0u64;
    // The resampler adds a short delay at the start and pads the last block; keep
    // exactly the corrected length.
    let mut skip = resampler.as_ref().map(|r| {
        use rubato::Resampler;
        r.output_delay()
    }).unwrap_or(0);
    let wanted = if speed { ((end - start) as f64 / restore.speed).round() as u64 } else { end - start };
    wav.file.seek(SeekFrom::Start(44 + start * (channels * bytes) as u64))?;
    let mut pos = start;
    let mut raw = vec![0u8; 4096 * channels * bytes];
    // Planar buffers for restoration.
    let mut planar: Vec<Vec<f64>> = vec![Vec::with_capacity(4096); channels];
    let mut emit = |planar: &[Vec<f64>],
                    flac: &mut Option<Flac>,
                    mp3: &mut Option<Mp3>,
                    loudness: &mut Loudness,
                    written: &mut u64|
     -> Result<()> {
        let total = planar.first().map(|c| c.len()).unwrap_or(0);
        let from = skip.min(total);
        skip -= from;
        let n = (total - from).min(wanted.saturating_sub(*written) as usize);
        let planar: Vec<&[f64]> = planar.iter().map(|c| &c[from..from + n]).collect();
        let mut ints = Vec::with_capacity(n * channels);
        let mut shorts = Vec::with_capacity(n * channels);
        let mut frame = vec![0.0; channels];
        for i in 0..n {
            for c in 0..channels {
                let x = planar[c][i].clamp(-1.0, 1.0 - 1.0 / full);
                frame[c] = x;
                ints.push((x * full).round() as i32);
                shorts.push((x * 32768.0).round().clamp(-32768.0, 32767.0) as i16);
            }
            loudness.feed(&frame);
        }
        if let Some(f) = flac.as_mut() {
            f.push(&ints)?;
        }
        if let Some(m) = mp3.as_mut() {
            m.push(&shorts)?;
        }
        *written += n as u64;
        Ok(())
    };
    while pos < end {
        if cancel.load(Ordering::Acquire) {
            bail!("Anulowano eksport — zachowano oryginał i ukończone utwory")
        }
        let n = (end - pos).min(4096) as usize;
        let b = &mut raw[..n * channels * bytes];
        wav.file.read_exact(b)?;
        for c in planar.iter_mut() {
            c.clear();
        }
        for (i, s) in b.chunks_exact(bytes).enumerate() {
            let v = match bytes {
                2 => i16::from_le_bytes([s[0], s[1]]) as i32,
                3 => i32::from_le_bytes([0, s[0], s[1], s[2]]) >> 8,
                _ => i32::from_le_bytes([s[0], s[1], s[2], s[3]]),
            };
            planar[i % channels].push(v as f64 / full);
        }
        for c in 0..channels {
            for f in notches[c].iter_mut() {
                for x in planar[c].iter_mut() {
                    *x = f.run(*x);
                }
            }
            if restore.declick {
                clicks += declick[c].run(&mut planar[c]);
            }
        }
        if let Some(r) = resampler.as_mut() {
            use rubato::Resampler;
            if n == 4096 {
                let out = r.process(planar.as_slice(), None).map_err(|e| anyhow!("{e}"))?;
                emit(&out, &mut flac, &mut mp3, &mut loudness, &mut written)?;
            } else {
                let out = r.process_partial(Some(planar.as_slice()), None).map_err(|e| anyhow!("{e}"))?;
                emit(&out, &mut flac, &mut mp3, &mut loudness, &mut written)?;
                let tail = r.process_partial::<Vec<f64>>(None, None).map_err(|e| anyhow!("{e}"))?;
                emit(&tail, &mut flac, &mut mp3, &mut loudness, &mut written)?;
            }
        } else {
            emit(&planar, &mut flac, &mut mp3, &mut loudness, &mut written)?;
        }
        pos += n as u64;
        if let Some(p) = out.progress {
            p.store(((pos - start) as f32 / (end - start) as f32).to_bits(), Ordering::Release);
        }
    }
    if let Some(f) = flac {
        f.finish()?;
    }
    if let Some(m) = mp3 {
        m.finish()?;
    }
    Ok(Encoded { loudness, clicks, frames: written })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::decoder::NativeSource;

    fn sine(path: &Path, rate: u32, seconds: f64, hum: bool, clicks: bool) {
        let mut w = Wav::create(path, rate, 2, 24).unwrap();
        let mut raw = Vec::new();
        for i in 0..(rate as f64 * seconds) as usize {
            let t = i as f64 / rate as f64;
            let mut x = (2.0 * std::f64::consts::PI * 440.0 * t).sin() * 0.3;
            if hum {
                x += (2.0 * std::f64::consts::PI * 50.0 * t).sin() * 0.1;
            }
            if clicks && i % 9000 == 4500 {
                x += 0.6;
            }
            let v = (x * 8388608.0) as i32;
            for _ in 0..2 {
                raw.extend_from_slice(&v.to_le_bytes()[..3]);
            }
        }
        w.write(&raw).unwrap();
        w.finish().unwrap();
    }

    fn decode(path: &Path) -> Vec<f32> {
        let mut d = NativeSource::open(path, 0).unwrap();
        let mut out = Vec::new();
        while let Some(s) = d.next().unwrap() {
            out.push(s[0]);
        }
        out
    }

    #[test]
    fn plain_copy_is_lossless_and_writes_mp3() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("m.wav");
        sine(&src, 44100, 1.0, false, false);
        let before = std::fs::read(&src).unwrap();
        let flac = d.path().join("a.flac");
        let mp3 = d.path().join("a.mp3");
        let r = encode(&src, 0, 44100, &Outputs { flac: Some(&flac), mp3: Some(&mp3), mp3_kbps: 192, restore: Restore::default(), progress: None }, &AtomicBool::new(false)).unwrap();
        assert_eq!(r.frames, 44100);
        assert_eq!(std::fs::read(&src).unwrap(), before);
        let a = decode(&flac);
        assert_eq!(a.len(), 44100);
        assert!((a[100] as f64 - (2.0 * std::f64::consts::PI * 440.0 * 100.0 / 44100.0).sin() * 0.3).abs() < 1e-6);
        assert!(std::fs::metadata(&mp3).unwrap().len() > 10_000);
        assert!(super::super::loudness::integrated(&r.loudness.blocks).is_some());
    }

    #[test]
    fn mp3_only_at_320_kbps() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("m.wav");
        sine(&src, 44100, 1.0, false, false);
        let mp3 = d.path().join("a.mp3");
        let r = encode(&src, 0, 44100, &Outputs { flac: None, mp3: Some(&mp3), mp3_kbps: 320, restore: Restore::default(), progress: None }, &AtomicBool::new(false)).unwrap();
        assert_eq!(r.frames, 44100);
        // One second at 320 kb/s is about 40 kB (192 kb/s would be about 24 kB).
        let size = std::fs::metadata(&mp3).unwrap().len();
        assert!(size > 34_000, "{size}");
        assert!(encode(&src, 0, 44100, &Outputs { flac: None, mp3: None, mp3_kbps: 320, restore: Restore::default(), progress: None }, &AtomicBool::new(false)).is_err());
    }

    #[test]
    fn hum_notch_declick_and_speed() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("m.wav");
        sine(&src, 48000, 2.0, true, true);
        let flac = d.path().join("b.flac");
        let restore = Restore { hum: Some(50.0), declick: true, speed: 1.0 };
        let r = encode(&src, 0, 96000, &Outputs { flac: Some(&flac), mp3: None, mp3_kbps: 192, restore, progress: None }, &AtomicBool::new(false)).unwrap();
        assert!(r.clicks >= 8, "{}", r.clicks);
        let out = decode(&flac);
        // After the notch settles, the 50 Hz component is gone: compare 50 Hz energy.
        let energy = |x: &[f32], f: f64| {
            let (mut re, mut im) = (0.0, 0.0);
            for (i, v) in x.iter().enumerate() {
                let a = 2.0 * std::f64::consts::PI * f * i as f64 / 48000.0;
                re += *v as f64 * a.cos();
                im += *v as f64 * a.sin();
            }
            (re * re + im * im).sqrt() / x.len() as f64
        };
        let tail = &out[48000..];
        assert!(energy(tail, 50.0) < 0.005, "{}", energy(tail, 50.0));
        assert!(energy(tail, 440.0) > 0.1);
        let fast = d.path().join("c.flac");
        let r = encode(&src, 0, 96000, &Outputs { flac: Some(&fast), mp3: None, mp3_kbps: 192, restore: Restore { hum: None, declick: false, speed: 1.02 }, progress: None }, &AtomicBool::new(false)).unwrap();
        let expected = (96000.0 / 1.02) as i64;
        assert!((r.frames as i64 - expected).abs() < 300, "{} vs {expected}", r.frames);
    }
}
