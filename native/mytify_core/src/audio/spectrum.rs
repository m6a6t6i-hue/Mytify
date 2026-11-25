//! Band levels of what the output is playing right now, for the seek bar display.
//! Computed on request from the renderer's sample ring, never in the audio callback.
use super::render::{Signals, SCOPE};
use std::sync::atomic::Ordering;

pub const WINDOW: usize = 2048;
pub const BANDS: usize = 40;
const LOW_HZ: f32 = 45.0;
const HIGH_HZ: f32 = 16000.0;

/// Levels in dBFS per band, low to high, with +3 dB/octave tilt around 1 kHz so music
/// reads evenly across the bar. `None` until a full window has been rendered.
pub fn bands(signals: &Signals, rate: u32) -> Option<Vec<f32>> {
    let head = signals.scope_head.load(Ordering::Acquire);
    if head < WINDOW as u64 || rate == 0 {
        return None;
    }
    let mut re = vec![0f32; WINDOW];
    let mut im = vec![0f32; WINDOW];
    let start = head - WINDOW as u64;
    for (i, v) in re.iter_mut().enumerate() {
        let s = f32::from_bits(
            signals.scope[((start + i as u64) as usize) & (SCOPE - 1)].load(Ordering::Relaxed),
        );
        let w = 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / (WINDOW - 1) as f32).cos();
        *v = if s.is_finite() { s * w } else { 0.0 };
    }
    fft(&mut re, &mut im);
    Some(levels(&re, &im, rate))
}

fn levels(re: &[f32], im: &[f32], rate: u32) -> Vec<f32> {
    let n = re.len();
    let hz = rate as f32 / n as f32;
    let top = HIGH_HZ.min(rate as f32 * 0.45);
    // Hann window halves the amplitude; scale so a full-scale sine reads about 0 dB.
    let scale = 4.0 / n as f32;
    let mag = |k: usize| (re[k] * re[k] + im[k] * im[k]).sqrt() * scale;
    (0..BANDS)
        .map(|b| {
            let lo = LOW_HZ * (top / LOW_HZ).powf(b as f32 / BANDS as f32);
            let hi = LOW_HZ * (top / LOW_HZ).powf((b + 1) as f32 / BANDS as f32);
            let (k0, k1) = ((lo / hz).floor() as usize, (hi / hz).ceil() as usize);
            let peak = if k1 <= k0 + 1 {
                // Narrower than one bin: interpolate at the band centre.
                let x = (lo * hi).sqrt() / hz;
                let k = (x.floor() as usize).min(n / 2 - 2);
                let f = x - k as f32;
                mag(k) * (1.0 - f) + mag(k + 1) * f
            } else {
                (k0..k1.min(n / 2)).map(mag).fold(0.0, f32::max)
            };
            let centre = (lo * hi).sqrt();
            let db = 20.0 * peak.max(1e-7).log10() + 3.0 * (centre / 1000.0).log2();
            (db * 10.0).round() / 10.0
        })
        .collect()
}

/// In-place radix-2 FFT. Length must be a power of two.
fn fft(re: &mut [f32], im: &mut [f32]) {
    let n = re.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let a = -2.0 * std::f64::consts::PI / len as f64;
        for i in (0..n).step_by(len) {
            for k in 0..len / 2 {
                let (s, c) = (a * k as f64).sin_cos();
                let (c, s) = (c as f32, s as f32);
                let (u, v) = (i + k, i + k + len / 2);
                let tr = re[v] * c - im[v] * s;
                let ti = re[v] * s + im[v] * c;
                re[v] = re[u] - tr;
                im[v] = im[u] - ti;
                re[u] += tr;
                im[u] += ti;
            }
        }
        len <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::render::Signals;

    fn feed(signals: &Signals, f: impl Fn(usize) -> f32) {
        for i in 0..WINDOW {
            signals.scope[i & (SCOPE - 1)].store(f(i).to_bits(), Ordering::Relaxed);
        }
        signals.scope_head.store(WINDOW as u64, Ordering::Release);
    }

    #[test]
    fn sine_lights_its_band_and_silence_stays_dark() {
        let s = Signals::new(80.0);
        assert!(bands(&s, 48000).is_none());
        feed(&s, |i| (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / 48000.0).sin() * 0.5);
        let b = bands(&s, 48000).unwrap();
        assert_eq!(b.len(), BANDS);
        let loudest = b.iter().enumerate().max_by(|x, y| x.1.total_cmp(y.1)).unwrap().0;
        let lo = LOW_HZ * (HIGH_HZ / LOW_HZ).powf(loudest as f32 / BANDS as f32);
        let hi = LOW_HZ * (HIGH_HZ / LOW_HZ).powf((loudest + 1) as f32 / BANDS as f32);
        let centre = (lo * hi).sqrt();
        assert!((centre / 1000.0).log2().abs() < 0.3, "{centre}");
        // -6 dBFS sine reads close to -6 dB at 1 kHz (tilt is zero there).
        assert!((b[loudest] + 6.0).abs() < 3.0, "{}", b[loudest]);
        feed(&s, |_| 0.0);
        assert!(bands(&s, 48000).unwrap().iter().all(|v| *v < -100.0));
    }
}
