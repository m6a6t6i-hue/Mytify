use mytify_core::{
    audio::{
        decoder::AudioSource,
        render::{pipe, Signals, BLOCK},
        Action, Player,
    },
    catalog::{Catalog, ScanRequest},
};
use std::{
    alloc::{GlobalAlloc, Layout, System},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
thread_local! {static WATCH:std::cell::Cell<bool>=const{std::cell::Cell::new(false)};}
static ALLOCS: AtomicUsize = AtomicUsize::new(0);
struct CountAlloc;
unsafe impl GlobalAlloc for CountAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if WATCH.try_with(|v| v.get()).unwrap_or(false) {
            ALLOCS.fetch_add(1, Ordering::Relaxed);
        }
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        if WATCH.try_with(|v| v.get()).unwrap_or(false) {
            ALLOCS.fetch_add(1, Ordering::Relaxed);
        }
        System.dealloc(p, layout)
    }
}
#[global_allocator]
static ALLOC: CountAlloc = CountAlloc;
fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/fixtures")
        .join(name)
}
fn decode(name: &str, rate: u32) -> Vec<[f32; 2]> {
    let mut source = AudioSource::open(&fixture(name), rate, 0).unwrap();
    let mut data = vec![];
    while let Some(frame) = source.next_frame().unwrap() {
        data.push(frame);
    }
    data
}
#[test]
fn native_decoders_read_real_music_formats() {
    for name in [
        "sample.wav",
        "sample.flac",
        "sample.mp3",
        "sample.m4a",
        "audio/codec.ogg",
        "audio/codec.m4a",
    ] {
        let data = decode(name, 48000);
        assert!(data.len() > 40000, "{name}: {}", data.len());
        assert!(data.iter().any(|s| s[0].abs() > 0.01), "{name}");
        assert!(data.iter().all(|s| s.iter().all(|v| v.is_finite())));
    }
}
#[test]
fn flac_and_wav_preserve_24bit_samples_without_resampling() {
    let wav = decode("audio/hires-24.wav", 96000);
    let flac = decode("audio/hires-24.flac", 96000);
    assert_eq!(wav.len(), 48000);
    assert_eq!(wav, flac);
    let source = AudioSource::open(&fixture("audio/hires-24.flac"), 96000, 0).unwrap();
    assert_eq!(source.info.bit_depth, 24);
    assert!(!source.info.resampled);
}
#[test]
fn lossless_alac_matches_pcm_reference() {
    assert_eq!(
        decode("audio/codec.m4a", 48000),
        decode("audio/whole.wav", 48000)
    );
}
#[test]
fn mp3_encoder_delay_and_padding_are_trimmed() {
    let wav = decode("sample.wav", 44100);
    let mp3 = decode("sample.mp3", 44100);
    assert_eq!(mp3.len(), wav.len());
}
#[test]
fn sinc_resampling_has_correct_length_and_rejects_out_of_band_alias() {
    let samples = decode("audio/hires-24.wav", 48000);
    assert_eq!(samples.len(), 24000);
    let amplitude = |frequency: f64| {
        let samples = &samples[512..samples.len() - 512];
        let mut re = 0.0;
        let mut im = 0.0;
        let mut weight = 0.0;
        for (i, s) in samples.iter().enumerate() {
            let w = 0.5
                - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (samples.len() - 1) as f64).cos();
            let phase = 2.0 * std::f64::consts::PI * frequency * i as f64 / 48000.0;
            re += s[0] as f64 * w * phase.cos();
            im += s[0] as f64 * w * phase.sin();
            weight += w;
        }
        2.0 * (re * re + im * im).sqrt() / weight
    };
    let tone = amplitude(1000.0);
    let alias = amplitude(18000.0);
    assert!((tone - 0.5).abs() < 0.002, "Tone {tone}");
    assert!(alias < 0.0001, "Alias amplitude {alias}");
    println!(
        "SRC 96k->48k: tone {tone:0.6}, 30k alias {:0.1} dBFS",
        20.0 * alias.max(1e-12).log10()
    );
}
#[test]
fn sinc_delay_is_compensated_and_last_samples_are_not_dropped() {
    let output = decode("audio/dc-44100.wav", 48000);
    assert_eq!(
        output.len(),
        (12345.0f64 * 48000.0 / 44100.0).round() as usize
    );
    assert!(output[0][0] > 0.1);
    assert!(
        output.last().unwrap()[0] > 0.1,
        "Tail: {:?}; First: {:?}",
        &output[output.len() - 8..],
        &output[..8]
    );
    assert!(output[500..output.len() - 500]
        .iter()
        .all(|f| (f[0] - 0.25).abs() < 0.0001));
}
#[test]
fn decoder_seek_reaches_requested_pcm_sample() {
    let full = decode("audio/whole.wav", 48000);
    let mut source = AudioSource::open(&fixture("audio/whole.wav"), 48000, 350).unwrap();
    let first = source.next_frame().unwrap().unwrap();
    assert_eq!(first, full[16800]);
}
#[test]
fn invalid_audio_is_rejected() {
    assert!(AudioSource::open(&fixture("cover.png"), 48000, 0).is_err());
    assert!(AudioSource::open(&fixture("sample.wav"), 1, 0).is_err());
}
#[test]
fn pcm_and_flac_boundary_has_no_inserted_samples_or_callback_allocations() {
    let reference = decode("audio/whole.wav", 48000);
    let signals = Arc::new(Signals::new(100.0));
    let (mut feeder, mut renderer) = pipe(48000, signals.clone());
    for (track, name) in ["audio/part-a.wav", "audio/part-b.flac"].iter().enumerate() {
        let frames = decode(name, 48000);
        for (n, chunk) in frames.chunks(BLOCK).enumerate() {
            let mut b = feeder.take().unwrap();
            b.epoch = 1;
            b.track = track;
            b.start = (n * BLOCK) as u64;
            b.len = chunk.len();
            b.terminal = false;
            b.samples[..chunk.len()].copy_from_slice(chunk);
            feeder.send(b);
        }
    }
    let mut end = feeder.take().unwrap();
    end.epoch = 1;
    end.len = 0;
    end.terminal = true;
    feeder.send(end);
    signals.ready.store(true, Ordering::Release);
    signals.paused.store(false, Ordering::Release);
    let mut result = vec![0f32; (reference.len() + 512) * 2];
    let before = ALLOCS.load(Ordering::Relaxed);
    WATCH.with(|v| v.set(true));
    for chunk in result.chunks_mut(512 * 2) {
        renderer.render(chunk, 2);
    }
    WATCH.with(|v| v.set(false));
    assert_eq!(
        ALLOCS.load(Ordering::Relaxed) - before,
        0,
        "Callback allocated or freed heap memory"
    );
    for (i, sample) in reference.iter().enumerate() {
        assert_eq!(result[i * 2], sample[0], "left frame {i}");
        assert_eq!(result[i * 2 + 1], sample[1], "right frame {i}");
    }
    assert!(result[reference.len() * 2..].iter().all(|v| *v == 0.0));
    assert!(signals.completed.load(Ordering::Acquire));
    assert_eq!(signals.underrun_frames.load(Ordering::Relaxed), 0);
    assert_eq!(signals.active.load(Ordering::Acquire), 1);
}
#[test]
fn pause_keeps_buffer_and_seek_generation_discards_stale_audio() {
    let sig = Arc::new(Signals::new(100.0));
    let (mut feeder, mut renderer) = pipe(48000, sig.clone());
    let mut block = feeder.take().unwrap();
    block.len = 512;
    block.epoch = 1;
    block.samples.fill([0.1, 0.1]);
    feeder.send(block);
    sig.ready.store(true, Ordering::Release);
    let mut output = [9f32; 128];
    renderer.render(&mut output, 2);
    assert!(output.iter().all(|v| *v == 0.0));
    sig.epoch.store(2, Ordering::Release);
    renderer.render(&mut output, 2);
    let mut block = feeder.take().unwrap();
    block.len = 512;
    block.epoch = 2;
    block.track = 2;
    block.start = 24000;
    block.samples.fill([0.75, -0.75]);
    feeder.send(block);
    sig.paused.store(false, Ordering::Release);
    renderer.render(&mut output, 2);
    assert_eq!(&output[..2], &[0.75, -0.75]);
    assert_eq!(sig.position.load(Ordering::Acquire), 24064);
}
fn wait(player: &Player, predicate: impl Fn(&mytify_core::audio::State) -> bool) {
    let start = Instant::now();
    while !predicate(&player.state()) {
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "Player wait timed out: {}",
            serde_json::to_string(&player.state()).unwrap()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn library() -> (
    tempfile::TempDir,
    tempfile::TempDir,
    Arc<Catalog>,
    Vec<String>,
) {
    let source = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    for file in ["part-a.wav", "part-b.flac"] {
        std::fs::copy(fixture(&format!("audio/{file}")), source.path().join(file)).unwrap();
    }
    let c = Arc::new(Catalog::open(data.path()).unwrap());
    c.scan(
        ScanRequest {
            paths: vec![source.path().to_string_lossy().into()],
            folder: true,
            ..Default::default()
        },
        &std::sync::atomic::AtomicBool::new(false),
        |_| {},
    )
    .unwrap();
    let ids = c.tracks().unwrap().into_iter().map(|t| t.id).collect();
    (source, data, c, ids)
}
#[test]
fn rust_player_advances_without_any_ui_polling() {
    let (_source, _data, c, ids) = library();
    let p = Player::new(c, true, None);
    p.command(Action::Load {
        ids: ids.clone(),
        index: 0,
    })
    .unwrap();
    // This checks autonomous queue completion, not OS timer precision.
    // Leave headroom for coarse Windows sleep resolution and concurrent builds.
    std::thread::sleep(Duration::from_millis(3000));
    let state = p.state();
    assert!(state.completed);
    assert_eq!(state.current_id, Some(ids[1].clone()));
    assert_eq!(state.rendered_frames, 48000);
}
#[test]
fn rust_player_pause_seek_repeat_shuffle_and_stop() {
    let (_source, _data, c, ids) = library();
    let p = Player::new(c, true, None);
    p.command(Action::Load {
        ids: ids.clone(),
        index: 0,
    })
    .unwrap();
    wait(&p, |s| s.position_ms > 50);
    p.command(Action::Pause).unwrap();
    let paused = p.state().position_ms;
    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(p.state().position_ms, paused);
    p.command(Action::Seek { position_ms: 200 }).unwrap();
    wait(&p, |s| !s.buffering);
    assert_eq!(p.state().position_ms, 200);
    p.command(Action::Shuffle { value: true }).unwrap();
    assert_eq!(p.state().queue_ids[0], ids[0]);
    p.command(Action::Repeat { value: true }).unwrap();
    p.command(Action::Play).unwrap();
    wait(&p, |s| s.rendered_frames > 10000);
    assert!(p.state().repeat);
    p.command(Action::Stop).unwrap();
    assert!(p.state().queue_ids.is_empty());
    assert!(!p.state().playing);
}
#[test]
fn failed_device_does_not_persist_or_fall_back_and_volume_survives_restart() {
    let (_source, data, c, ids) = library();
    let p = Player::new(c.clone(), true, None);
    p.command(Action::Load { ids, index: 0 }).unwrap();
    p.command(Action::Volume { value: 37.0 }).unwrap();
    p.command(Action::Device {
        id: "missing-device".into(),
    })
    .unwrap_err();
    assert_eq!(p.state().selected_device, "auto");
    assert!(!p.state().playing);
    p.command(Action::Device {
        id: "test-44100".into(),
    })
    .unwrap();
    assert_eq!(p.state().output.unwrap().sample_rate, 44100);
    p.flush_settings().unwrap();
    drop(p);
    let start = Instant::now();
    while !data.path().join("audio-settings.json").exists() {
        assert!(start.elapsed() < Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(10));
    }
    let p = Player::new(c, true, None);
    assert!((p.state().volume - 37.0).abs() < 0.001);
    assert_eq!(p.state().selected_device, "test-44100");
    assert!(p.command(Action::Volume { value: 101.0 }).is_err());
}
#[test]
fn missing_source_reports_error_and_finishes_instead_of_looping() {
    let (source, _data, c, ids) = library();
    let p = Player::new(c, true, None);
    std::fs::remove_dir_all(source.path()).unwrap();
    p.command(Action::Repeat { value: true }).unwrap();
    p.command(Action::Load { ids, index: 0 }).unwrap();
    wait(&p, |s| s.completed);
    assert!(p.state().error.is_some());
}
#[test]
fn resampled_impulses_keep_input_alignment_at_both_ends() {
    let frames = decode("audio/impulse-44100.wav", 48000);
    assert_eq!(
        frames.len(),
        (2048.0f64 * 48000.0 / 44100.0).round() as usize
    );
    let peak = frames[530..560]
        .iter()
        .enumerate()
        .max_by(|a, b| a.1[0].abs().total_cmp(&b.1[0].abs()))
        .unwrap()
        .0
        + 530;
    assert!((peak as i64 - 544).abs() <= 1, "Shifted impulse at {peak}");
    assert!(frames[0][0].abs() > 0.3);
    assert!(frames.last().unwrap()[0].abs() > 0.3);
}
