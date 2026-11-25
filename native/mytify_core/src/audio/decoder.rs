use anyhow::{anyhow, bail, Context, Result};
use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
use std::{fs::File, path::Path};
use symphonia::core::{
    audio::SampleBuffer,
    codecs::{Decoder, DecoderOptions},
    errors::Error,
    formats::{FormatOptions, FormatReader, SeekMode, SeekTo},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
    units::Time,
};

pub type Stereo = [f32; 2];
#[derive(Clone, Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceInfo {
    pub sample_rate: u32,
    pub channels: usize,
    pub bit_depth: u32,
    pub duration_ms: u64,
    pub resampled: bool,
}
pub(crate) struct NativeSource {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    buffer: Vec<Stereo>,
    offset: usize,
    skip: u64,
    pub(crate) info: SourceInfo,
}
impl NativeSource {
    pub(crate) fn open(path: &Path, seek_ms: u64) -> Result<Self> {
        let file = File::open(path).context("Nie można otworzyć pliku audio")?;
        Self::open_reader(Box::new(file), &path.to_string_lossy(), seek_ms)
    }
    /// Any seekable byte source: a local file or a network reader (WebDAV ranges).
    pub(crate) fn open_reader(
        reader: Box<dyn symphonia::core::io::MediaSource>,
        name: &str,
        seek_ms: u64,
    ) -> Result<Self> {
        let mut hint = Hint::new();
        if let Some(ext) = Path::new(name).extension().and_then(|s| s.to_str()) {
            hint.with_extension(ext);
        }
        let probed = symphonia::default::get_probe().format(
            &hint,
            MediaSourceStream::new(reader, Default::default()),
            &FormatOptions {
                enable_gapless: true,
                ..Default::default()
            },
            &MetadataOptions::default(),
        )?;
        let mut format = probed.format;
        let track = format
            .default_track()
            .ok_or_else(|| anyhow!("Brak ścieżki audio"))?;
        let track_id = track.id;
        let params = track.codec_params.clone();
        let mut decoder = symphonia::default::get_codecs()
            .make(&params, &DecoderOptions::default())
            .context("Ten kodek nie jest jeszcze obsługiwany przez odtwarzacz")?;
        let sr = params.sample_rate.unwrap_or(0);
        let duration_ms = if let (Some(tb), Some(n)) = (params.time_base, params.n_frames) {
            let time = tb.calc_time(n);
            time.seconds * 1000 + (time.frac * 1000.0).round() as u64
        } else {
            0
        };
        let mut skip = 0;
        if seek_ms > 0 {
            let result = format
                .seek(
                    SeekMode::Accurate,
                    SeekTo::Time {
                        time: Time::from(seek_ms as f64 / 1000.0),
                        track_id: Some(track_id),
                    },
                )
                .context("Nie można przewinąć tego pliku")?;
            decoder.reset();
            let actual = params.time_base.map(|tb| tb.calc_time(result.actual_ts));
            let actual_s = actual.map(|t| t.seconds as f64 + t.frac).unwrap_or(0.0);
            skip = ((seek_ms as f64 / 1000.0 - actual_s).max(0.0) * sr as f64).round() as u64;
        }
        let mut source = Self {
            format,
            decoder,
            track_id,
            buffer: vec![],
            offset: 0,
            skip,
            info: SourceInfo {
                sample_rate: sr,
                channels: params.channels.map(|c| c.count()).unwrap_or(0),
                bit_depth: params.bits_per_sample.unwrap_or(0),
                duration_ms,
                resampled: false,
            },
        };
        source.refill()?; // Read one packet to confirm actual decoder parameters before opening DSP.
        if !(8000..=384000).contains(&source.info.sample_rate) {
            bail!(
                "Nieobsługiwana częstotliwość źródła: {} Hz",
                source.info.sample_rate
            );
        }
        Ok(source)
    }
    fn refill(&mut self) -> Result<bool> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(Error::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                    self.buffer.clear();
                    self.offset = 0;
                    return Ok(false);
                }
                Err(e) => return Err(e.into()),
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            let decoded = self
                .decoder
                .decode(&packet)
                .context("Błąd dekodowania pliku audio")?;
            let spec = *decoded.spec();
            let channels = spec.channels.count();
            if channels != 1 && channels != 2 {
                bail!("Obsługujemy obecnie muzykę mono i stereo; ten plik ma {channels} kanałów.");
            }
            if self.info.sample_rate != 0 && spec.rate != self.info.sample_rate {
                bail!("Zmienna częstotliwość wewnątrz pliku nie jest jeszcze obsługiwana.");
            }
            self.info.sample_rate = spec.rate;
            self.info.channels = channels;
            let mut samples = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
            samples.copy_interleaved_ref(decoded);
            self.buffer.clear();
            self.offset = 0;
            for sample in samples.samples().chunks_exact(channels) {
                if self.skip > 0 {
                    self.skip -= 1;
                    continue;
                }
                if sample.iter().any(|v| !v.is_finite()) {
                    bail!("Plik zawiera nieprawidłowe próbki audio.");
                }
                self.buffer
                    .push([sample[0], sample[if channels == 1 { 0 } else { 1 }]]);
            }
            if !self.buffer.is_empty() {
                return Ok(true);
            }
        }
    }
    pub(crate) fn next(&mut self) -> Result<Option<Stereo>> {
        if self.offset >= self.buffer.len() && !self.refill()? {
            return Ok(None);
        }
        let frame = self.buffer[self.offset];
        self.offset += 1;
        Ok(Some(frame))
    }
}

pub(crate) trait StereoInput {
    fn next_input(&mut self) -> Result<Option<Stereo>>;
}
impl StereoInput for NativeSource {
    fn next_input(&mut self) -> Result<Option<Stereo>> {
        self.next()
    }
}

/// The SincFixedIn 0.16 stream is already sample-aligned: its reported output_delay
/// is lookahead latency, not a silent prefix to remove. Impulse/end tests pin this behavior.
pub(crate) struct Converter<I: StereoInput> {
    pub input: I,
    resampler: Option<SincFixedIn<f64>>,
    pending: Vec<Stereo>,
    cursor: usize,
    input_frames: u64,
    output_frames: u64,
    eof: bool,
    done: bool,
    input_rate: u32,
    output_rate: u32,
}
impl<I: StereoInput> Converter<I> {
    pub fn new(input: I, input_rate: u32, output_rate: u32) -> Result<Self> {
        if !(8000..=384000).contains(&output_rate) {
            bail!("Nieprawidłowa częstotliwość wyjścia.");
        }
        let resampler = if input_rate == output_rate {
            None
        } else {
            Some(SincFixedIn::<f64>::new(
                output_rate as f64 / input_rate as f64,
                2.0,
                SincInterpolationParameters {
                    sinc_len: 256,
                    f_cutoff: 0.95,
                    interpolation: SincInterpolationType::Linear,
                    oversampling_factor: 256,
                    window: WindowFunction::BlackmanHarris2,
                },
                1024,
                2,
            )?)
        };
        Ok(Self {
            input,
            resampler,
            pending: vec![],
            cursor: 0,
            input_frames: 0,
            output_frames: 0,
            eof: false,
            done: false,
            input_rate,
            output_rate,
        })
    }
    pub fn next(&mut self) -> Result<Option<Stereo>> {
        if self.resampler.is_none() {
            return self.input.next_input();
        }
        loop {
            if self.cursor < self.pending.len() {
                let frame = self.pending[self.cursor];
                self.cursor += 1;
                return Ok(Some(frame));
            }
            if self.done {
                return Ok(None);
            }
            let mut input = [
                Vec::<f64>::with_capacity(1024),
                Vec::<f64>::with_capacity(1024),
            ];
            if !self.eof {
                while input[0].len() < 1024 {
                    match self.input.next_input()? {
                        Some(f) => {
                            input[0].push(f[0] as f64);
                            input[1].push(f[1] as f64);
                            self.input_frames += 1;
                        }
                        None => {
                            self.eof = true;
                            break;
                        }
                    }
                }
            }
            let output = if self.eof {
                if input[0].is_empty() {
                    self.resampler
                        .as_mut()
                        .unwrap()
                        .process_partial::<Vec<f64>>(None, None)?
                } else {
                    self.resampler
                        .as_mut()
                        .unwrap()
                        .process_partial(Some(&input), None)?
                }
            } else {
                self.resampler.as_mut().unwrap().process(&input, None)?
            };
            let target = (self.input_frames as f64 * self.output_rate as f64
                / self.input_rate as f64)
                .round() as u64;
            self.pending.clear();
            self.cursor = 0;
            for (&l, &r) in output[0].iter().zip(output[1].iter()) {
                if self.eof && self.output_frames >= target {
                    self.done = true;
                    break;
                }
                self.pending.push([l as f32, r as f32]);
                self.output_frames += 1;
            }
            if self.eof && self.output_frames >= target {
                self.done = true;
            }
        }
    }
}
pub struct AudioSource {
    converter: Converter<NativeSource>,
    pub info: SourceInfo,
}
impl AudioSource {
    pub fn open(path: &Path, output_rate: u32, seek_ms: u64) -> Result<Self> {
        let native = NativeSource::open(path, seek_ms)?;
        let mut info = native.info.clone();
        info.resampled = info.sample_rate != output_rate;
        let converter = Converter::new(native, info.sample_rate, output_rate)?;
        Ok(Self { converter, info })
    }
    pub fn next_frame(&mut self) -> Result<Option<Stereo>> {
        self.converter.next()
    }
}
