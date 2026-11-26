use super::{
    decoder::{Converter, NativeSource, SourceInfo, Stereo, StereoInput},
    Data,
};
use crate::catalog::Catalog;
use anyhow::Result;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
#[derive(Clone)]
struct Plan {
    ids: Vec<String>,
    order: Vec<usize>,
    repeat: bool,
}
struct Opened {
    source: NativeSource,
    first: Stereo,
    cursor: usize,
    seek_ms: u64,
}
struct Segment {
    index: usize,
    start_native: u64,
    start_output: u64,
    seek_ms: u64,
}
struct QueueInput {
    catalog: Arc<Catalog>,
    data: Arc<Mutex<Data>>,
    plan: Arc<Plan>,
    source: NativeSource,
    first: Option<Stereo>,
    cursor: usize,
    rate: u32,
    output_rate: u32,
    native_frames: u64,
    segments: VecDeque<Segment>,
    pending: Option<Opened>,
    finished: bool,
}
impl QueueInput {
    fn report(data: &Mutex<Data>, message: impl ToString) {
        let mut d = data.lock().unwrap();
        d.error = Some(message.to_string());
        d.error_serial += 1;
    }
    /// `wait`: when the first track lives on a NAS that does not answer, give up with the
    /// reason instead of skipping to the next track, so the caller can reach the NAS and retry.
    fn open(
        catalog: &Arc<Catalog>,
        data: &Arc<Mutex<Data>>,
        plan: &Plan,
        mut cursor: usize,
        mut seek_ms: u64,
        wait: bool,
    ) -> std::result::Result<Option<Opened>, String> {
        for attempt in 0..plan.order.len() {
            let Some(&index) = plan.order.get(cursor) else {
                return Ok(None);
            };
            let id = &plan.ids[index];
            let result = catalog
                .open_audio(id)
                .and_then(|input| NativeSource::open_reader(input.reader, &input.name, seek_ms))
                .and_then(|mut source| source.next().map(|first| (source, first)));
            match result {
                Ok((source, Some(first))) => {
                    return Ok(Some(Opened {
                        source,
                        first,
                        cursor,
                        seek_ms,
                    }))
                }
                Ok(_) => Self::report(data, "Pominięto pusty utwór audio."),
                Err(e) if wait && attempt == 0 && catalog.network_only(id) => return Err(format!("{e:#}")),
                Err(e) => Self::report(data, format!("Nie można odtworzyć utworu: {e:#}")),
            }
            if cursor + 1 < plan.order.len() {
                cursor += 1;
            } else if plan.repeat {
                cursor = 0;
            } else {
                return Ok(None);
            }
            seek_ms = 0;
        }
        Ok(None)
    }
    fn new(
        catalog: Arc<Catalog>,
        data: Arc<Mutex<Data>>,
        plan: Arc<Plan>,
        opened: Opened,
        output_rate: u32,
    ) -> Self {
        let rate = opened.source.info.sample_rate;
        let index = plan.order[opened.cursor];
        let mut info = opened.source.info.clone();
        info.resampled = rate != output_rate;
        data.lock().unwrap().infos[index] = info;
        Self {
            catalog,
            data,
            plan,
            source: opened.source,
            first: Some(opened.first),
            cursor: opened.cursor,
            rate,
            output_rate,
            native_frames: 0,
            segments: VecDeque::from([Segment {
                index,
                start_native: 0,
                start_output: 0,
                seek_ms: opened.seek_ms,
            }]),
            pending: None,
            finished: false,
        }
    }
    fn finish_track(&mut self) {
        let segment = self.segments.back().unwrap();
        let duration =
            segment.seek_ms + (self.native_frames - segment.start_native) * 1000 / self.rate as u64;
        self.data.lock().unwrap().infos[segment.index].duration_ms = duration;
    }
    fn tag(&mut self, output_frame: u64) -> (usize, u64) {
        while self.segments.len() > 1 && self.segments[1].start_output <= output_frame {
            self.segments.pop_front();
        }
        let s = self.segments.front().unwrap();
        (
            s.index,
            output_frame.saturating_sub(s.start_output)
                + s.seek_ms * self.output_rate as u64 / 1000,
        )
    }
}
impl StereoInput for QueueInput {
    fn next_input(&mut self) -> Result<Option<Stereo>> {
        if self.finished {
            return Ok(None);
        }
        loop {
            let frame = if let Some(first) = self.first.take() {
                Some(first)
            } else {
                match self.source.next() {
                    Ok(v) => v,
                    Err(e) => {
                        Self::report(&self.data, format!("Błąd dekodowania: {e:#}"));
                        None
                    }
                }
            };
            if let Some(frame) = frame {
                self.native_frames += 1;
                return Ok(Some(frame));
            }
            self.finish_track();
            let cursor = if self.cursor + 1 < self.plan.order.len() {
                self.cursor + 1
            } else if self.plan.repeat {
                0
            } else {
                self.finished = true;
                return Ok(None);
            };
            let Some(opened) = Self::open(&self.catalog, &self.data, &self.plan, cursor, 0, false).unwrap_or(None) else {
                self.finished = true;
                return Ok(None);
            };
            if opened.source.info.sample_rate != self.rate {
                self.pending = Some(opened);
                self.finished = true;
                return Ok(None);
            }
            let index = self.plan.order[opened.cursor];
            let mut info: SourceInfo = opened.source.info.clone();
            info.resampled = self.rate != self.output_rate;
            self.data.lock().unwrap().infos[index] = info;
            self.segments.push_back(Segment {
                index,
                start_native: self.native_frames,
                start_output: (self.native_frames as f64 * self.output_rate as f64
                    / self.rate as f64)
                    .round() as u64,
                seek_ms: 0,
            });
            self.source = opened.source;
            self.first = Some(opened.first);
            self.cursor = opened.cursor;
        }
    }
}
pub struct TaggedFrame {
    pub sample: Stereo,
    pub index: usize,
    pub position: u64,
}
/// Adjacent files at the same source rate share one sinc state and fractional phase.
/// This avoids zero-padding/filter resets at album boundaries, including 44.1 -> 48 kHz.
/// What opening the queue gave: sound, nothing left, or a NAS that does not answer (yet).
pub enum Opening {
    Ready(SequenceSource),
    Ended,
    Unreachable(String),
}
pub struct SequenceSource {
    converter: Converter<QueueInput>,
    position: u64,
    output_rate: u32,
}
impl SequenceSource {
    pub fn open(
        catalog: Arc<Catalog>,
        data: Arc<Mutex<Data>>,
        cursor: usize,
        seek_ms: u64,
        output_rate: u32,
        wait: bool,
    ) -> Result<Opening> {
        let plan = {
            let d = data.lock().unwrap();
            Arc::new(Plan {
                ids: d.ids.clone(),
                order: d.order.clone(),
                repeat: d.repeat,
            })
        };
        let opened = match QueueInput::open(&catalog, &data, &plan, cursor, seek_ms, wait) {
            Ok(Some(opened)) => opened,
            Ok(None) => return Ok(Opening::Ended),
            Err(reason) => return Ok(Opening::Unreachable(reason)),
        };
        let input = QueueInput::new(catalog, data, plan, opened, output_rate);
        let rate = input.rate;
        Ok(Opening::Ready(Self {
            converter: Converter::new(input, rate, output_rate)?,
            position: 0,
            output_rate,
        }))
    }
    pub fn next(&mut self) -> Result<Option<TaggedFrame>> {
        loop {
            if let Some(sample) = self.converter.next()? {
                let (index, position) = self.converter.input.tag(self.position);
                self.position += 1;
                return Ok(Some(TaggedFrame {
                    sample,
                    index,
                    position,
                }));
            }
            let input = &mut self.converter.input;
            let Some(opened) = input.pending.take() else {
                return Ok(None);
            };
            let input = QueueInput::new(
                input.catalog.clone(),
                input.data.clone(),
                input.plan.clone(),
                opened,
                self.output_rate,
            );
            let rate = input.rate;
            self.converter = Converter::new(input, rate, self.output_rate)?;
            self.position = 0;
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{audio::decoder::AudioSource, catalog::ScanRequest};
    use std::{path::Path, sync::atomic::AtomicBool};
    fn compare(parts: &[&str], whole: Option<&str>) {
        let src = tempfile::tempdir().unwrap();
        let dest = tempfile::tempdir().unwrap();
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/audio");
        for (name, file) in parts.iter().enumerate() {
            std::fs::copy(
                fixtures.join(file),
                src.path().join(format!(
                    "{name}.{}",
                    Path::new(file).extension().unwrap().to_string_lossy()
                )),
            )
            .unwrap();
        }
        let catalog = Arc::new(Catalog::open(dest.path()).unwrap());
        catalog
            .scan(
                ScanRequest {
                    paths: vec![src.path().to_string_lossy().into()],
                    folder: true,
                    ..Default::default()
                },
                &AtomicBool::new(false),
                |_| {},
            )
            .unwrap();
        let mut tracks = catalog.tracks().unwrap();
        tracks.sort_by(|a, b| a.file_name.cmp(&b.file_name));
        let data = Arc::new(Mutex::new(Data {
            ids: tracks.iter().map(|t| t.id.clone()).collect(),
            order: (0..parts.len()).collect(),
            infos: vec![SourceInfo::default(); parts.len()],
            ..Default::default()
        }));
        let Opening::Ready(mut source) = SequenceSource::open(catalog, data.clone(), 0, 0, 48000, true).unwrap() else {
            panic!("the queue did not open")
        };
        let mut samples = vec![];
        let mut boundaries = vec![];
        while let Some(frame) = source.next().unwrap() {
            if frame.position == 0 {
                boundaries.push((frame.index, samples.len()));
            }
            samples.push(frame.sample);
        }
        let mut reference = vec![];
        for name in whole.map(|w| vec![w]).unwrap_or_else(|| parts.to_vec()) {
            let mut s = AudioSource::open(&fixtures.join(name), 48000, 0).unwrap();
            while let Some(f) = s.next_frame().unwrap() {
                reference.push(f);
            }
        }
        assert_eq!(samples.len(), reference.len());
        assert_eq!(samples, reference, "Boundary changed waveform");
        assert_eq!(boundaries.len(), parts.len());
        assert_eq!(boundaries[0], (0, 0));
        assert_eq!(boundaries[1], (1, 24000));
    }
    #[test]
    fn shared_sinc_state_keeps_44100_album_boundary_identical_to_unsplit_file() {
        compare(
            &["part-44100-a.wav", "part-44100-b.flac"],
            Some("whole-44100.wav"),
        );
    }
    #[test]
    fn changing_source_rates_has_exact_duration_and_no_inserted_block() {
        compare(&["part-a.wav", "dc-44100.wav"], None);
    }
}
