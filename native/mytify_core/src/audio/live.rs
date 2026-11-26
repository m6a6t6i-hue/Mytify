//! A live radio stream: a network thread connects, decodes (MP3, OGG and FLAC through
//! symphonia, AAC and HE-AAC through fdk-aac), resamples to the output rate and queues
//! a few seconds ahead. Pausing drops the stream; playing again reconnects.
use super::decoder::{Converter, NativeSource, Stereo, StereoInput};
use crate::radio::{self, Kind, LiveMeta};
use anyhow::{bail, Result};
use std::{
    collections::VecDeque,
    io::Read,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex,
    },
    time::Duration,
};

struct Shared {
    queue: Mutex<VecDeque<Stereo>>,
    space: Condvar,
    failed: Mutex<Option<String>>,
    stop: AtomicBool,
}
pub(crate) struct Live {
    shared: Arc<Shared>,
}
impl Drop for Live {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.space.notify_all();
    }
}
impl Live {
    pub fn start(url: String, output_rate: u32, meta: Arc<Mutex<LiveMeta>>) -> Self {
        let shared = Arc::new(Shared {
            queue: Mutex::new(VecDeque::new()),
            space: Condvar::new(),
            failed: Mutex::new(None),
            stop: AtomicBool::new(false),
        });
        let worker = shared.clone();
        std::thread::Builder::new()
            .name("radio".into())
            .spawn(move || stream(url, output_rate, worker, meta))
            .ok();
        Self { shared }
    }
    pub fn buffered(&self) -> usize {
        self.shared.queue.lock().unwrap().len()
    }
    pub fn take(&self, out: &mut [Stereo]) -> usize {
        let mut q = self.shared.queue.lock().unwrap();
        let n = out.len().min(q.len());
        for (slot, frame) in out.iter_mut().zip(q.drain(..n)) {
            *slot = frame;
        }
        drop(q);
        self.shared.space.notify_all();
        n
    }
    pub fn failed(&self) -> Option<String> {
        self.shared.failed.lock().unwrap().clone()
    }
}

fn stream(url: String, rate: u32, shared: Arc<Shared>, meta: Arc<Mutex<LiveMeta>>) {
    let capacity = rate as usize * 4;
    let mut failures = 0;
    while !shared.stop.load(Ordering::Acquire) {
        let mut produced = false;
        let result = (|| -> Result<()> {
            let opened = radio::open(&url, &meta)?;
            let input = open_input(opened.reader, opened.kind)?;
            let source_rate = input.rate();
            let mut converter = Converter::new(input, source_rate, rate)?;
            meta.lock().unwrap().reconnecting = false;
            let mut chunk = Vec::with_capacity(1024);
            loop {
                if shared.stop.load(Ordering::Acquire) {
                    return Ok(());
                }
                chunk.clear();
                while chunk.len() < 1024 {
                    match converter.next()? {
                        Some(f) => chunk.push(f),
                        None => break,
                    }
                }
                if chunk.is_empty() {
                    bail!("Stacja zakończyła nadawanie.");
                }
                let mut q = shared.queue.lock().unwrap();
                while q.len() + chunk.len() > capacity && !shared.stop.load(Ordering::Acquire) {
                    q = shared.space.wait_timeout(q, Duration::from_millis(200)).unwrap().0;
                }
                q.extend(chunk.iter().copied());
                produced = true;
            }
        })();
        if shared.stop.load(Ordering::Acquire) {
            return;
        }
        let message = match result {
            Ok(()) => return,
            Err(e) => format!("{e:#}"),
        };
        // HLS and bad addresses will not fix themselves; a dropped connection may.
        let permanent = message == radio::HLS_UNSUPPORTED
            || message.contains("Nieprawidłowy adres")
            || message.contains("Nieznany format")
            || message.contains("strona internetowa");
        failures = if produced { 1 } else { failures + 1 };
        if permanent || failures > 4 {
            *shared.failed.lock().unwrap() = Some(if failures > 4 && !permanent {
                format!("Nie udało się połączyć ze stacją: {message}")
            } else {
                message
            });
            return;
        }
        meta.lock().unwrap().reconnecting = true;
        let wait = Duration::from_millis(500 * failures as u64);
        let start = std::time::Instant::now();
        while start.elapsed() < wait && !shared.stop.load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

trait LiveInput: StereoInput {
    fn rate(&self) -> u32;
}
impl StereoInput for Box<dyn LiveInput> {
    fn next_input(&mut self) -> Result<Option<Stereo>> {
        (**self).next_input()
    }
}
impl LiveInput for NativeSource {
    fn rate(&self) -> u32 {
        self.info.sample_rate
    }
}

/// symphonia needs a Sync source; the network reader is only Send.
struct SyncRead(Mutex<Box<dyn Read + Send>>);
impl Read for SyncRead {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.get_mut().unwrap().read(buf)
    }
}

fn open_input(reader: Box<dyn Read + Send>, kind: Kind) -> Result<Box<dyn LiveInput>> {
    if kind == Kind::Aac {
        return Ok(Box::new(AacInput::open(reader)?));
    }
    let name = match kind {
        Kind::Mp3 => "stream.mp3",
        Kind::Ogg => "stream.ogg",
        Kind::Flac => "stream.flac",
        _ => "stream",
    };
    let source = symphonia::core::io::ReadOnlySource::new(SyncRead(Mutex::new(reader)));
    Ok(Box::new(NativeSource::open_reader(Box::new(source), name, 0)?))
}

/// ADTS AAC, HE-AAC and HE-AAC v2 through the Fraunhofer decoder, down-mixed to stereo.
pub(crate) struct AacInput {
    reader: Box<dyn Read + Send>,
    decoder: fdk_aac::dec::Decoder,
    pending: Vec<u8>,
    pcm: Vec<i16>,
    frames: Vec<Stereo>,
    at: usize,
    rate: u32,
}
impl AacInput {
    pub fn open(reader: Box<dyn Read + Send>) -> Result<Self> {
        let mut decoder = fdk_aac::dec::Decoder::new(fdk_aac::dec::Transport::Adts);
        let _ = decoder.set_max_output_channels(2);
        let mut s = Self {
            reader,
            decoder,
            pending: Vec::new(),
            pcm: vec![0; 2048 * 8 * 2],
            frames: Vec::new(),
            at: 0,
            rate: 0,
        };
        if !s.decode()? {
            bail!("Stacja nie przesłała dźwięku AAC.");
        }
        if !(8000..=96000).contains(&s.rate) {
            bail!("Nieobsługiwana częstotliwość strumienia: {} Hz", s.rate);
        }
        Ok(s)
    }
    fn decode(&mut self) -> Result<bool> {
        let mut errors = 0;
        loop {
            match self.decoder.decode_frame(&mut self.pcm) {
                Ok(()) => {
                    let info = self.decoder.stream_info();
                    let channels = info.numChannels.max(0) as usize;
                    let size = info.frameSize.max(0) as usize;
                    let rate = info.sampleRate.max(0) as u32;
                    if channels == 0 || size == 0 || channels * size > self.pcm.len() {
                        errors += 1;
                    } else {
                        if self.rate != 0 && rate != self.rate {
                            bail!("Stacja zmieniła częstotliwość dźwięku.");
                        }
                        self.rate = rate;
                        self.frames.clear();
                        self.at = 0;
                        for f in self.pcm[..channels * size].chunks_exact(channels) {
                            let l = f[0] as f32 / 32768.0;
                            let r = if channels > 1 { f[1] as f32 / 32768.0 } else { l };
                            self.frames.push([l, r]);
                        }
                        return Ok(true);
                    }
                }
                Err(e) if e == fdk_aac::dec::DecoderError::NOT_ENOUGH_BITS => {
                    if self.pending.is_empty() {
                        let mut buf = [0u8; 4096];
                        let n = self.reader.read(&mut buf)?;
                        if n == 0 {
                            return Ok(false);
                        }
                        self.pending.extend_from_slice(&buf[..n]);
                    }
                    let used = self
                        .decoder
                        .fill(&self.pending)
                        .map_err(|e| anyhow::anyhow!("Błąd dekodera AAC: {e}"))?;
                    self.pending.drain(..used);
                    continue;
                }
                // A damaged frame: the decoder resynchronises on the next one.
                Err(_) => errors += 1,
            }
            if errors > 64 {
                bail!("Strumień AAC jest uszkodzony.");
            }
        }
    }
}
impl StereoInput for AacInput {
    fn next_input(&mut self) -> Result<Option<Stereo>> {
        if self.at >= self.frames.len() && !self.decode()? {
            return Ok(None);
        }
        let f = self.frames[self.at];
        self.at += 1;
        Ok(Some(f))
    }
}
impl LiveInput for AacInput {
    fn rate(&self) -> u32 {
        self.rate
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::Write;

    pub fn sine(rate: u32, seconds: f32) -> Vec<i16> {
        let n = (rate as f32 * seconds) as usize;
        let mut out = Vec::with_capacity(n * 2);
        for i in 0..n {
            let v = ((i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 12000.0) as i16;
            out.push(v);
            out.push(v);
        }
        out
    }
    pub fn adts(rate: u32, he: bool) -> Vec<u8> {
        use fdk_aac::enc::*;
        let enc = Encoder::new(EncoderParams {
            bit_rate: BitRate::Cbr(if he { 48000 } else { 96000 }),
            sample_rate: rate,
            transport: Transport::Adts,
            channels: ChannelMode::Stereo,
            audio_object_type: if he { AudioObjectType::Mpeg4HeAac } else { AudioObjectType::Mpeg4LowComplexity },
        })
        .unwrap();
        let pcm = sine(rate, 2.0);
        let mut out = Vec::new();
        let mut buf = vec![0u8; 8192];
        for chunk in pcm.chunks(2048 * 2) {
            let mut input = chunk;
            while !input.is_empty() {
                let info = enc.encode(input, &mut buf).unwrap();
                out.extend_from_slice(&buf[..info.output_size]);
                if info.input_consumed == 0 {
                    break;
                }
                input = &input[info.input_consumed..];
            }
        }
        out
    }
    pub fn mp3(rate: u32) -> Vec<u8> {
        use mp3lame_encoder::{Builder, FlushNoGap, InterleavedPcm};
        let mut b = Builder::new().unwrap();
        b.set_num_channels(2).unwrap();
        b.set_sample_rate(rate).unwrap();
        b.set_brate(mp3lame_encoder::Bitrate::Kbps128).unwrap();
        let mut enc = b.build().unwrap();
        let pcm = sine(rate, 2.0);
        let mut out = Vec::new();
        out.reserve(mp3lame_encoder::max_required_buffer_size(pcm.len() / 2));
        enc.encode_to_vec(InterleavedPcm(&pcm), &mut out).unwrap();
        out.reserve(7200);
        enc.flush_to_vec::<FlushNoGap>(&mut out).unwrap();
        out
    }
    fn level(frames: &[Stereo]) -> f32 {
        (frames.iter().map(|f| f[0] * f[0]).sum::<f32>() / frames.len().max(1) as f32).sqrt()
    }

    #[test]
    fn aac_and_he_aac_decode_from_the_middle_of_a_stream() {
        for he in [false, true] {
            let data = adts(44100, he);
            // Joining a station starts mid-frame; the decoder has to find the next one.
            let reader: Box<dyn Read + Send> = Box::new(std::io::Cursor::new(data[37..].to_vec()));
            let mut input = AacInput::open(reader).unwrap();
            assert_eq!(input.rate, 44100);
            let mut frames = Vec::new();
            while let Some(f) = input.next_input().unwrap() {
                frames.push(f);
            }
            assert!(frames.len() > 44100, "{he}: {}", frames.len());
            let l = level(&frames[20000..40000]);
            assert!(l > 0.15 && l < 0.4, "{he}: level {l}");
        }
    }

    /// An Icecast-like server: ICY metadata every `interval` bytes, endless repetition.
    pub fn serve(content_type: &'static str, body: Vec<u8>, interval: usize, title: &'static str) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut s) = stream else { continue };
                let body = body.clone();
                std::thread::spawn(move || {
                    let mut req = [0u8; 2048];
                    let n = s.read(&mut req).unwrap_or(0);
                    let wants = String::from_utf8_lossy(&req[..n]).to_lowercase().contains("icy-metadata: 1");
                    let interval = if wants { interval } else { 0 };
                    let mut head = format!("HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nicy-name: Test FM\r\nicy-br: 128\r\n");
                    if interval > 0 {
                        head += &format!("icy-metaint: {interval}\r\n");
                    }
                    head += "\r\n";
                    if s.write_all(head.as_bytes()).is_err() {
                        return;
                    }
                    let mut meta = format!("StreamTitle='{title}';").into_bytes();
                    let blocks = meta.len().div_ceil(16);
                    meta.resize(blocks * 16, 0);
                    meta.insert(0, blocks as u8);
                    let mut since = 0;
                    let playlist = content_type == "audio/x-scpls" || content_type.contains("mpegurl");
                    loop {
                        for b in body.chunks(1000) {
                            let mut b = b;
                            while !b.is_empty() {
                                let n = if interval > 0 { b.len().min(interval - since) } else { b.len() };
                                if s.write_all(&b[..n]).is_err() {
                                    return;
                                }
                                b = &b[n..];
                                since += n;
                                if interval > 0 && since == interval {
                                    if s.write_all(&meta).is_err() {
                                        return;
                                    }
                                    since = 0;
                                }
                            }
                            std::thread::sleep(Duration::from_millis(2));
                        }
                        if playlist {
                            return;
                        }
                    }
                });
            }
        });
        format!("http://{addr}/live")
    }

    fn listen(url: String, seconds: f32) -> (Vec<Stereo>, Arc<Mutex<LiveMeta>>) {
        let meta = Arc::new(Mutex::new(LiveMeta::default()));
        let live = Live::start(url, 48000, meta.clone());
        let mut frames = Vec::new();
        let mut buf = vec![[0.0; 2]; 4096];
        let start = std::time::Instant::now();
        while frames.len() < (48000.0 * seconds) as usize && start.elapsed() < Duration::from_secs(20) {
            assert_eq!(live.failed(), None);
            let n = live.take(&mut buf);
            frames.extend_from_slice(&buf[..n]);
            if n == 0 {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        (frames, meta)
    }

    #[test]
    fn stations_play_mp3_and_aac_with_titles() {
        let cases = [
            ("audio/mpeg", mp3(44100), "MP3"),
            ("audio/aacp", adts(44100, true), "AAC"),
            ("application/octet-stream", adts(48000, false), "AAC"),
        ];
        for (ct, body, codec) in cases {
            let url = serve(ct, body, 4000, "Artysta - Utwór");
            let (frames, meta) = listen(url, 3.0);
            assert!(frames.len() >= 144000, "{ct}: {}", frames.len());
            let l = level(&frames[48000..96000]);
            assert!(l > 0.15 && l < 0.4, "{ct}: level {l}");
            let m = meta.lock().unwrap();
            assert_eq!(m.title.as_deref(), Some("Artysta - Utwór"));
            assert_eq!(m.station.as_deref(), Some("Test FM"));
            assert_eq!(m.codec, codec);
            assert_eq!(m.bitrate, 128);
        }
    }

    #[test]
    fn playlists_lead_to_the_stream_and_hls_is_refused() {
        let stream = serve("audio/mpeg", mp3(48000), 0, "");
        let pls = serve("audio/x-scpls", format!("[playlist]\nFile1={stream}\n").into_bytes(), 0, "");
        let (frames, _) = listen(pls, 1.0);
        assert!(frames.len() >= 48000);
        let hls = serve("application/vnd.apple.mpegurl", b"#EXTM3U\n#EXT-X-TARGETDURATION:6\na.aac\n".to_vec(), 0, "");
        let meta = Arc::new(Mutex::new(LiveMeta::default()));
        let live = Live::start(hls, 48000, meta);
        let start = std::time::Instant::now();
        while live.failed().is_none() && start.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(live.failed().as_deref(), Some(radio::HLS_UNSUPPORTED));
    }

    #[test]
    fn player_plays_a_station_pauses_live_and_returns_to_files() {
        use crate::audio::{Action, Player};
        let data = tempfile::tempdir().unwrap();
        let c = Arc::new(crate::catalog::Catalog::open(data.path()).unwrap());
        let p = Player::new(c, true, None);
        let wait = |f: &dyn Fn(&crate::audio::State) -> bool| {
            let start = std::time::Instant::now();
            while !f(&p.state()) {
                assert!(start.elapsed() < Duration::from_secs(15), "{}", serde_json::to_string(&p.state()).unwrap());
                std::thread::sleep(Duration::from_millis(20));
            }
        };
        // Exactly what the app sends, extra fields included.
        let station = |url: String| -> Action {
            serde_json::from_value(serde_json::json!({
                "action": "radio", "id": "radio:test", "url": url, "name": "Test", "logo": "",
                "codec": "AAC+", "bitrate": 48, "hls": false,
            }))
            .unwrap()
        };
        assert!(p.command(station("ftp://x".into())).is_err());
        let url = serve("audio/aacp", adts(44100, true), 3000, "Artysta - Utwór");
        p.command(station(url)).unwrap();
        wait(&|s| s.rendered_frames > 24000 && s.radio.as_ref().is_some_and(|r| r.title.is_some()));
        let s = p.state();
        assert_eq!(s.current_id.as_deref(), Some("radio:test"));
        assert_eq!(s.duration_ms, 0);
        let r = s.radio.unwrap();
        assert_eq!((r.title.as_deref(), r.codec.as_str(), r.station.as_deref()), (Some("Artysta - Utwór"), "AAC", Some("Test FM")));
        // Seeking means nothing on air; with a single station neither does skipping.
        p.command(Action::Seek { position_ms: 90_000 }).unwrap();
        p.command(Action::Next).unwrap();
        assert_eq!(p.state().current_id.as_deref(), Some("radio:test"));
        // With a list, next and previous change the station and go round.
        let other = serve("audio/mpeg", mp3(44100), 4000, "Inny - Utwór");
        let list: Action = serde_json::from_value(serde_json::json!({
            "action": "radio", "id": "radio:b", "url": other, "name": "B", "logo": "", "codec": "MP3", "bitrate": 128, "hls": false,
            "stations": [
                {"id": "radio:a", "url": p.state().radio.unwrap().url, "name": "A", "logo": "", "tags": ["jazz"]},
                {"id": "radio:b", "url": "http://ignored.example/", "name": "B", "logo": ""},
                {"id": "bad", "url": "http://x/", "name": "X", "logo": ""},
            ],
        }))
        .unwrap();
        p.command(list).unwrap();
        wait(&|s| s.current_id.as_deref() == Some("radio:b") && s.radio.as_ref().is_some_and(|r| r.title.as_deref() == Some("Inny - Utwór")));
        assert_eq!(p.state().radio.unwrap().stations.len(), 2);
        p.command(Action::Next).unwrap();
        wait(&|s| s.current_id.as_deref() == Some("radio:a") && s.radio.as_ref().is_some_and(|r| r.name == "A" && r.title.is_some()));
        p.command(Action::Next).unwrap();
        assert_eq!(p.state().current_id.as_deref(), Some("radio:b"));
        p.command(Action::Previous).unwrap();
        assert_eq!(p.state().current_id.as_deref(), Some("radio:a"));
        p.command(Action::Pause).unwrap();
        let frames = p.state().rendered_frames;
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(p.state().rendered_frames, frames);
        assert!(p.state().error.is_none());
        p.command(Action::Play).unwrap();
        wait(&|s| s.rendered_frames > frames + 24000);
        p.command(Action::Stop).unwrap();
        assert!(p.state().radio.is_none());
        let failed = serve("text/html", b"<html></html>".to_vec(), 0, "");
        p.command(station(failed)).unwrap();
        wait(&|s| s.error.as_deref().is_some_and(|e| e.contains("strona internetowa")) && !s.playing);
    }
}
