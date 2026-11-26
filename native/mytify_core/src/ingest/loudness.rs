//! ReplayGain 2.0: integrated loudness per EBU R128 / ITU-R BS.1770 (K-weighting,
//! 400 ms blocks with 75% overlap, absolute and relative gating), reference -18 LUFS.

#[derive(Clone, Copy, Default)]
struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    z: [f64; 2],
}
impl Biquad {
    fn run(&mut self, x: f64) -> f64 {
        let y = self.b[0] * x + self.z[0];
        self.z[0] = self.b[1] * x - self.a[0] * y + self.z[1];
        self.z[1] = self.b[2] * x - self.a[1] * y;
        y
    }
}

fn k_weighting(rate: f64) -> [Biquad; 2] {
    let pi = std::f64::consts::PI;
    // High shelf (head acoustics).
    let (f0, g, q) = (1681.974450955533, 3.999843853973347, 0.7071752369554196);
    let k = (pi * f0 / rate).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let shelf = Biquad {
        b: [(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        z: [0.0; 2],
    };
    // High pass (RLB).
    let (f0, q) = (38.13547087602444, 0.5003270373238773);
    let k = (pi * f0 / rate).tan();
    let a0 = 1.0 + k / q + k * k;
    let high = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        z: [0.0; 2],
    };
    [shelf, high]
}

/// Collects 400 ms block energies of one track; several tracks combine into an album.
pub struct Loudness {
    filters: Vec<[Biquad; 2]>,
    step: usize,
    count: usize,
    acc: f64,
    quarters: [f64; 4],
    filled: usize,
    pub blocks: Vec<f64>,
    pub peak: f64,
}

impl Loudness {
    pub fn new(rate: u32, channels: usize) -> Self {
        Self {
            filters: vec![k_weighting(rate as f64); channels.max(1)],
            step: (rate as usize / 10).max(1),
            count: 0,
            acc: 0.0,
            quarters: [0.0; 4],
            filled: 0,
            blocks: Vec::new(),
            peak: 0.0,
        }
    }

    /// Interleaved samples scaled to -1..1.
    pub fn feed(&mut self, frame: &[f64]) {
        let mut sum = 0.0;
        for (c, x) in frame.iter().enumerate().take(self.filters.len()) {
            self.peak = self.peak.max(x.abs());
            let f = &mut self.filters[c];
            let s = f[0].run(*x);
            let y = f[1].run(s);
            sum += y * y;
        }
        self.acc += sum;
        self.count += 1;
        if self.count == self.step {
            self.quarters.rotate_left(1);
            self.quarters[3] = self.acc / self.step as f64;
            self.filled += 1;
            if self.filled >= 4 {
                self.blocks.push(self.quarters.iter().sum::<f64>() / 4.0);
            }
            self.acc = 0.0;
            self.count = 0;
        }
    }

    pub fn feed_pcm16(&mut self, pcm: &[u8]) {
        for f in pcm.chunks_exact(4) {
            let l = i16::from_le_bytes([f[0], f[1]]) as f64 / 32768.0;
            let r = i16::from_le_bytes([f[2], f[3]]) as f64 / 32768.0;
            self.feed(&[l, r]);
        }
    }
}

/// Integrated loudness in LUFS of the given blocks, None for silence.
pub fn integrated(blocks: &[f64]) -> Option<f64> {
    let lufs = |e: f64| -0.691 + 10.0 * e.log10();
    let gated: Vec<f64> = blocks.iter().copied().filter(|e| *e > 0.0 && lufs(*e) > -70.0).collect();
    if gated.is_empty() {
        return None;
    }
    let mean = gated.iter().sum::<f64>() / gated.len() as f64;
    let relative = lufs(mean) - 10.0;
    let kept: Vec<f64> = gated.into_iter().filter(|e| lufs(*e) > relative).collect();
    if kept.is_empty() {
        return None;
    }
    Some(lufs(kept.iter().sum::<f64>() / kept.len() as f64))
}

/// ReplayGain 2.0 gain in dB for a loudness, reference -18 LUFS.
pub fn gain(lufs: f64) -> f64 {
    -18.0 - lufs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sine_at_1khz_reads_as_expected() {
        // EBU Tech 3341: a stereo 1 kHz sine at -N dBFS reads -N LUFS.
        for rate in [44100u32, 48000] {
            let mut l = Loudness::new(rate, 2);
            for i in 0..rate as usize * 5 {
                let x = (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / rate as f64).sin() * 0.5;
                l.feed(&[x, x]);
            }
            let v = integrated(&l.blocks).unwrap();
            assert!((v - (-6.02)).abs() < 0.1, "{rate}: {v}");
            assert!((l.peak - 0.5).abs() < 1e-3);
            assert!((gain(v) - (-11.98)).abs() < 0.1);
        }
        let mut quiet = Loudness::new(44100, 2);
        for _ in 0..44100 * 2 {
            quiet.feed(&[0.0, 0.0]);
        }
        assert_eq!(integrated(&quiet.blocks), None);
    }
}
