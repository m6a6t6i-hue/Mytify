use super::render::{Renderer, Signals};
#[cfg(windows)]
use anyhow::anyhow;
use anyhow::{bail, Result};
use serde::Serialize;
use std::sync::{atomic::Ordering, Arc};
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub name: String,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputInfo {
    pub device_id: String,
    pub name: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub sample_format: String,
    pub backend: String,
    pub shared: bool,
    pub test_sink: bool,
}
pub struct Spec {
    pub info: OutputInfo,
    network: Option<crate::network::Target>,
    #[cfg(windows)]
    device: Option<cpal::Device>,
    #[cfg(windows)]
    config: Option<cpal::SupportedStreamConfig>,
}
pub struct OutputHandle {
    _network: Option<crate::airplay::Output>,
    #[cfg(windows)]
    _stream: Option<cpal::Stream>,
    #[cfg(debug_assertions)]
    _test: Option<TestClock>,
}
#[cfg(debug_assertions)]
struct TestClock {
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
#[cfg(debug_assertions)]
impl Drop for TestClock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

pub fn devices(test: bool) -> Result<Vec<Device>> {
    let mut result = vec![Device {
        id: "auto".into(),
        name: "Domyślne urządzenie systemu".into(),
    }];
    #[cfg(debug_assertions)]
    if test {
        result.push(Device {
            id: "test-48000".into(),
            name: "Test 48 kHz (bez dźwięku)".into(),
        });
        result.push(Device {
            id: "test-44100".into(),
            name: "Test 44,1 kHz (bez dźwięku)".into(),
        });
        return Ok(result);
    }
    let _ = test;
    #[cfg(windows)]
    {
        use cpal::traits::{DeviceTrait, HostTrait};
        let host = cpal::default_host();
        for d in host.output_devices()? {
            result.push(Device {
                id: d.id()?.to_string(),
                name: d.description()?.name().into(),
            });
        }
        Ok(result)
    }
    #[cfg(not(windows))]
    {
        let _ = &mut result;
        bail!("Natywne wyjście tej paczki jest dostępne na Windows.")
    }
}
pub fn select(id: &str, test: bool) -> Result<Spec> {
    if let Some(t) = crate::network::target(id).filter(|t| t.kind == "airplay") {
        if t.auth == 1 {
            bail!("Odbiornik wymaga hasła AirPlay. Wybierz DLNA lub wyłącz hasło na odbiorniku.")
        }
        return Ok(Spec {
            info: OutputInfo {
                device_id: id.into(),
                name: t.name.clone(),
                sample_rate: 44100,
                channels: 2,
                sample_format: "PCM16 / ALAC".into(),
                backend: "AirPlay · 16 bit / 44,1 kHz".into(),
                shared: false,
                test_sink: false,
            },
            network: Some(t),
            #[cfg(windows)]
            device: None,
            #[cfg(windows)]
            config: None,
        });
    }

    #[cfg(debug_assertions)]
    if test {
        let rate = match id {
            "auto" | "test-48000" => 48000,
            "test-44100" => 44100,
            _ => bail!("Nie znaleziono urządzenia testowego."),
        };
        return Ok(Spec {
            network: None,
            info: OutputInfo {
                device_id: id.into(),
                name: "Wyjście testowe — bez dźwięku".into(),
                sample_rate: rate,
                channels: 2,
                sample_format: "F32".into(),
                backend: "test-clock".into(),
                shared: true,
                test_sink: true,
            },
            #[cfg(windows)]
            device: None,
            #[cfg(windows)]
            config: None,
        });
    }
    let _ = test;
    #[cfg(windows)]
    {
        use cpal::traits::{DeviceTrait, HostTrait};
        let host = cpal::default_host();
        let device = if id == "auto" {
            host.default_output_device()
        } else {
            host.device_by_id(&id.parse::<cpal::DeviceId>()?)
        }
        .ok_or_else(|| {
            anyhow!("Urządzenie jest niedostępne. Wybierz inne wyjście w ustawieniach dźwięku.")
        })?;
        let default = device.default_output_config()?;
        let rate = default.sample_rate();
        let config = device
            .supported_output_configs()?
            .find(|c| {
                c.channels() == 2
                    && c.sample_format() == cpal::SampleFormat::F32
                    && c.min_sample_rate() <= rate
                    && c.max_sample_rate() >= rate
            })
            .map(|c| c.with_sample_rate(rate))
            .unwrap_or(default);
        if !matches!(
            config.sample_format(),
            cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::I32
        ) {
            bail!("Wyjście wymaga nieobsługiwanego formatu próbek. Wybierz inne urządzenie.");
        }
        if !(1..=8).contains(&config.channels()) {
            bail!("Nieobsługiwana liczba kanałów urządzenia.");
        }
        let info = OutputInfo {
            device_id: device.id()?.to_string(),
            name: device.description()?.name().into(),
            sample_rate: config.sample_rate(),
            channels: config.channels(),
            sample_format: format!("{:?}", config.sample_format()),
            backend: "Windows WASAPI / CPAL".into(),
            shared: true,
            test_sink: false,
        };
        Ok(Spec {
            network: None,
            info,
            device: Some(device),
            config: Some(config),
        })
    }
    #[cfg(not(windows))]
    {
        let _ = id;
        bail!("Natywne wyjście tej paczki jest dostępne na Windows.")
    }
}
pub fn open(
    spec: Spec,
    mut renderer: Renderer,
    signals: Arc<Signals>,
    capture: Option<std::path::PathBuf>,
) -> Result<OutputHandle> {
    if let Some(t) = spec.network {
        return Ok(OutputHandle {
            _network: Some(crate::airplay::open(t, renderer, signals)?),
            #[cfg(windows)]
            _stream: None,
            #[cfg(debug_assertions)]
            _test: None,
        });
    }
    #[cfg(debug_assertions)]
    if spec.info.test_sink {
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        let rate = spec.info.sample_rate;
        let thread = std::thread::spawn(move || {
            use std::io::Write;
            let mut file = capture.and_then(|p| {
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(p)
                    .ok()
            });
            let mut buffer = [0.0f32; 1024];
            let period = std::time::Duration::from_secs_f64(512.0 / rate as f64);
            while !flag.load(Ordering::Acquire) {
                let now = std::time::Instant::now();
                renderer.render(&mut buffer, 2);
                if let Some(file) = &mut file {
                    let mut bytes = [0u8; 4096];
                    for (chunk, sample) in bytes.chunks_exact_mut(4).zip(buffer.iter()) {
                        chunk.copy_from_slice(&sample.to_le_bytes());
                    }
                    let _ = file.write_all(&bytes);
                }
                if let Some(wait) = period.checked_sub(now.elapsed()) {
                    std::thread::sleep(wait);
                }
            }
        });
        return Ok(OutputHandle {
            _network: None,
            #[cfg(windows)]
            _stream: None,
            _test: Some(TestClock {
                stop,
                thread: Some(thread),
            }),
        });
    }
    let _ = capture;
    #[cfg(windows)]
    {
        use cpal::traits::{DeviceTrait, StreamTrait};
        let device = spec.device.ok_or_else(|| anyhow!("Brak urządzenia"))?;
        let supported = spec.config.ok_or_else(|| anyhow!("Brak konfiguracji"))?;
        let channels = supported.channels() as usize;
        let config = supported.config();
        let error = move |_e| {
            signals.device_failed.store(true, Ordering::Release);
            signals.paused.store(true, Ordering::Release);
        };
        let stream = match supported.sample_format() {
            cpal::SampleFormat::F32 => device.build_output_stream(
                config,
                move |data: &mut [f32], _| renderer.render(data, channels),
                error,
                None,
            )?,
            cpal::SampleFormat::I16 => {
                let mut rng = 1u32;
                device.build_output_stream(
                    config,
                    move |data: &mut [i16], _| {
                        let mut scratch = [0f32; 4096];
                        for chunk in data.chunks_mut(512 * channels) {
                            renderer.render(&mut scratch[..chunk.len()], channels);
                            for (dest, &sample) in chunk.iter_mut().zip(scratch.iter()) {
                                rng ^= rng << 13;
                                rng ^= rng >> 17;
                                rng ^= rng << 5;
                                let a = rng as f64 / u32::MAX as f64;
                                rng ^= rng << 13;
                                rng ^= rng >> 17;
                                rng ^= rng << 5;
                                let b = rng as f64 / u32::MAX as f64;
                                *dest = (sample as f64 * 32768.0
                                    + if sample == 0.0 { 0.0 } else { a - b })
                                .round()
                                .clamp(-32768.0, 32767.0)
                                    as i16;
                            }
                        }
                    },
                    error,
                    None,
                )?
            }
            cpal::SampleFormat::I32 => device.build_output_stream(
                config,
                move |data: &mut [i32], _| {
                    let mut scratch = [0f32; 4096];
                    for chunk in data.chunks_mut(512 * channels) {
                        renderer.render(&mut scratch[..chunk.len()], channels);
                        for (dest, &sample) in chunk.iter_mut().zip(scratch.iter()) {
                            *dest = (sample as f64 * 2147483648.0)
                                .round()
                                .clamp(-2147483648.0, 2147483647.0)
                                as i32;
                        }
                    }
                },
                error,
                None,
            )?,
            _ => bail!("Nieobsługiwany format wyjścia"),
        };
        stream.play()?;
        Ok(OutputHandle {
            _network: None,
            _stream: Some(stream),
            #[cfg(debug_assertions)]
            _test: None,
        })
    }
    #[cfg(not(windows))]
    {
        let _ = (spec, renderer, signals);
        bail!("Brak systemowego wyjścia audio dla tej platformy.")
    }
}
