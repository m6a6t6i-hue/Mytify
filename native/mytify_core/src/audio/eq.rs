//! 10-band graphic equalizer applied in the render callback: peaking biquads (RBJ),
//! no allocation, coefficients recomputed only when the settings change.
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

pub const BANDS: [f32; 10] = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
pub const MAX_DB: f32 = 12.0;
/// About one octave per band.
const Q: f32 = 1.41;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Equalizer {
    pub enabled: bool,
    /// dB per band, -12..=12.
    pub gains: Vec<f32>,
}
impl Equalizer {
    pub fn clean(mut self) -> Self {
        self.gains.resize(BANDS.len(), 0.0);
        for g in &mut self.gains {
            *g = if g.is_finite() { g.clamp(-MAX_DB, MAX_DB) } else { 0.0 };
        }
        self
    }
}

/// Settings shared with the callback.
pub struct Shared {
    enabled: AtomicBool,
    gains: [AtomicU32; 10],
    version: AtomicU64,
}
impl Shared {
    pub fn new(eq: &Equalizer) -> Self {
        let s = Self {
            enabled: AtomicBool::new(false),
            gains: std::array::from_fn(|_| AtomicU32::new(0)),
            version: AtomicU64::new(1),
        };
        s.set(eq);
        s
    }
    pub fn set(&self, eq: &Equalizer) {
        let eq = eq.clone().clean();
        for (a, g) in self.gains.iter().zip(&eq.gains) {
            a.store(g.to_bits(), Ordering::Relaxed);
        }
        self.enabled.store(eq.enabled, Ordering::Relaxed);
        self.version.fetch_add(1, Ordering::Release);
    }
}

#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}
impl Biquad {
    fn peaking(f: f32, rate: f32, db: f32) -> Self {
        let a = 10f32.powf(db / 40.0);
        let w = 2.0 * std::f32::consts::PI * f / rate;
        let alpha = w.sin() / (2.0 * Q);
        let cos = w.cos();
        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: -2.0 * cos / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: -2.0 * cos / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }
}

/// Per-stream filter state, owned by the renderer.
pub struct Filter {
    rate: f32,
    version: u64,
    active: bool,
    preamp: f32,
    coef: [Biquad; 10],
    on: [bool; 10],
    /// Transposed direct form II state per band and channel.
    z: [[[f32; 2]; 2]; 10],
}
impl Filter {
    pub fn new(rate: u32) -> Self {
        Self {
            rate: rate.max(1) as f32,
            version: 0,
            active: false,
            preamp: 1.0,
            coef: [Biquad::default(); 10],
            on: [false; 10],
            z: [[[0.0; 2]; 2]; 10],
        }
    }
    /// Picks up new settings; cheap when nothing changed.
    pub fn update(&mut self, shared: &Shared) {
        let v = shared.version.load(Ordering::Acquire);
        if v == self.version {
            return;
        }
        self.version = v;
        let enabled = shared.enabled.load(Ordering::Relaxed);
        let mut peak = 0f32;
        let mut any = false;
        for i in 0..BANDS.len() {
            let db = f32::from_bits(shared.gains[i].load(Ordering::Relaxed));
            // Bands above ~0.45 of the sample rate cannot be represented.
            let on = enabled && db.abs() > 0.05 && BANDS[i] < self.rate * 0.45;
            if on {
                self.coef[i] = Biquad::peaking(BANDS[i], self.rate, db);
                peak = peak.max(db);
                any = true;
            } else if self.on[i] {
                self.z[i] = [[0.0; 2]; 2];
            }
            self.on[i] = on;
        }
        self.active = any;
        // Boosts would clip at full scale: lower the input by the largest boost.
        self.preamp = 10f32.powf(-peak / 20.0);
    }
    #[inline]
    pub fn process(&mut self, sample: [f32; 2]) -> [f32; 2] {
        if !self.active {
            return sample;
        }
        let mut out = [sample[0] * self.preamp, sample[1] * self.preamp];
        for i in 0..BANDS.len() {
            if !self.on[i] {
                continue;
            }
            let c = self.coef[i];
            for (ch, x) in out.iter_mut().enumerate() {
                let z = &mut self.z[i][ch];
                let y = c.b0 * *x + z[0];
                z[0] = c.b1 * *x - c.a1 * y + z[1];
                z[1] = c.b2 * *x - c.a2 * y;
                *x = y;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone_gain(eq: &Equalizer, f: f32) -> f32 {
        let rate = 44100.0;
        let shared = Shared::new(eq);
        let mut filter = Filter::new(rate as u32);
        filter.update(&shared);
        let n = 44100;
        let (mut inp, mut out) = (0f32, 0f32);
        for i in 0..n {
            let x = 0.25 * (2.0 * std::f32::consts::PI * f * i as f32 / rate).sin();
            let y = filter.process([x, x])[0];
            if i > n / 2 {
                inp += x * x;
                out += y * y;
            }
        }
        10.0 * (out / inp).log10()
    }

    #[test]
    fn bass_boost_lifts_lows_not_highs_with_headroom() {
        let mut gains = vec![0.0; 10];
        gains[1] = 6.0;
        let eq = Equalizer { enabled: true, gains };
        // 62 Hz: +6 dB boost, -6 dB preamp, so about level.
        assert!(tone_gain(&eq, 62.0).abs() < 0.8, "{}", tone_gain(&eq, 62.0));
        // 4 kHz: untouched by the band, only the preamp.
        assert!((tone_gain(&eq, 4000.0) + 6.0).abs() < 0.5);
    }

    #[test]
    fn disabled_or_flat_is_bit_exact() {
        let eq = Equalizer { enabled: false, gains: vec![9.0; 10] };
        let mut f = Filter::new(48000);
        f.update(&Shared::new(&eq));
        assert_eq!(f.process([0.3, -0.2]), [0.3, -0.2]);
        let flat = Equalizer { enabled: true, gains: vec![0.0; 10] };
        f.update(&Shared::new(&flat));
        assert_eq!(f.process([0.3, -0.2]), [0.3, -0.2]);
    }

    #[test]
    fn cut_lowers_the_band() {
        let mut gains = vec![0.0; 10];
        gains[5] = -9.0;
        let eq = Equalizer { enabled: true, gains };
        assert!((tone_gain(&eq, 1000.0) + 9.0).abs() < 0.8);
    }

    #[test]
    fn clean_clamps_and_pads() {
        let eq = Equalizer { enabled: true, gains: vec![30.0, f32::NAN] }.clean();
        assert_eq!(eq.gains.len(), 10);
        assert_eq!(eq.gains[0], 12.0);
        assert_eq!(eq.gains[1], 0.0);
    }
}
