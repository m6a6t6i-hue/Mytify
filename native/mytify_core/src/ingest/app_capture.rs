//! Sound of one application (WASAPI process loopback, Windows 10 2004 or newer): only
//! that program and the processes it started. System sounds, other apps and Mytify
//! itself are not recorded, and the volume mixer does not change the level.
use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::{Duration, Instant},
};
use windows::{
    core::{implement, Interface, IUnknown, HRESULT, PWSTR},
    Win32::{
        Foundation::{CloseHandle, HANDLE, S_OK},
        Media::Audio::*,
        System::{
            Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, StructuredStorage::PROPVARIANT, CLSCTX_ALL, COINIT_MULTITHREADED},
            Threading::{CreateEventW, OpenProcess, QueryFullProcessImageNameW, WaitForSingleObject, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION},
        },
    },
};

/// COM for the calling thread, released when dropped.
struct Com(bool);
impl Com {
    fn init() -> Self {
        Com(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok())
    }
}
impl Drop for Com {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() }
        }
    }
}

fn exe_path(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut n = buf.len() as u32;
        let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut n);
        let _ = CloseHandle(h);
        r.ok()?;
        Some(String::from_utf16_lossy(&buf[..n as usize]))
    }
}

/// "C:\…\Spotify.exe" → "Spotify".
fn app_name(path: &str) -> String {
    let file = path.rsplit(['\\', '/']).next().unwrap_or(path);
    let stem = file.strip_suffix(".exe").or_else(|| file.strip_suffix(".EXE")).unwrap_or(file);
    let mut c = stem.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => String::new(),
    }
}

struct Session {
    pid: u32,
    path: String,
    active: bool,
}

/// Programs that have an audio session on any output now (playing or ready to play).
fn sessions() -> Result<Vec<Session>> {
    let _com = Com::init();
    let mut out = Vec::new();
    unsafe {
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let list = devices.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)?;
        for i in 0..list.GetCount()? {
            let Ok(device) = list.Item(i) else { continue };
            let Ok(manager) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) else { continue };
            let Ok(all) = manager.GetSessionEnumerator() else { continue };
            for j in 0..all.GetCount().unwrap_or(0) {
                let Ok(control) = all.GetSession(j) else { continue };
                let Ok(control2) = control.cast::<IAudioSessionControl2>() else { continue };
                if control2.IsSystemSoundsSession() == S_OK {
                    continue;
                }
                let Ok(pid) = control2.GetProcessId() else { continue };
                if pid == 0 || pid == std::process::id() {
                    continue;
                }
                let Some(path) = exe_path(pid) else { continue };
                let active = control.GetState().is_ok_and(|s| s == AudioSessionStateActive);
                out.push(Session { pid, path, active });
            }
        }
    }
    Ok(out)
}

/// Apps to record from, one entry per program, playing ones first.
pub fn apps() -> Result<Value> {
    let mut by_path: BTreeMap<String, (u32, bool)> = BTreeMap::new();
    for s in sessions()? {
        let e = by_path.entry(s.path.to_lowercase()).or_insert((s.pid, s.active));
        if s.active && !e.1 {
            *e = (s.pid, true);
        }
    }
    let mut list: Vec<Value> = by_path
        .into_iter()
        .map(|(path, (pid, active))| {
            let path = exe_path(pid).unwrap_or(path);
            json!({"id": app_name(&path).to_lowercase(), "name": app_name(&path), "pid": pid, "playing": active})
        })
        .collect();
    list.sort_by_key(|v| (!v["playing"].as_bool().unwrap_or(false), v["name"].as_str().unwrap_or("").to_lowercase()));
    list.dedup_by(|a, b| a["id"] == b["id"]);
    Ok(json!(list))
}

/// Process of the app named `id` ("spotify"), the one playing when there are several.
fn find(id: &str) -> Result<u32> {
    let mut best: Option<(u32, bool)> = None;
    for s in sessions()? {
        if app_name(&s.path).to_lowercase() != id {
            continue;
        }
        if best.is_none_or(|b| s.active && !b.1) {
            best = Some((s.pid, s.active));
        }
    }
    best.map(|b| b.0).ok_or_else(|| anyhow!("Aplikacja nie gra teraz dźwięku. Włącz ją i odtwórz cokolwiek, potem odśwież listę."))
}

#[implement(IActivateAudioInterfaceCompletionHandler)]
struct Activated(mpsc::SyncSender<()>);

impl IActivateAudioInterfaceCompletionHandler_Impl for Activated_Impl {
    fn ActivateCompleted(&self, _operation: windows::core::Ref<IActivateAudioInterfaceAsyncOperation>) -> windows::core::Result<()> {
        let _ = self.0.try_send(());
        Ok(())
    }
}

/// PROPVARIANT holding a BLOB (VT_BLOB), laid out as the system expects.
#[repr(C)]
struct BlobVariant {
    vt: u16,
    reserved: [u16; 3],
    size: u32,
    data: *mut u8,
}

fn open(pid: u32, rate: u32) -> Result<IAudioClient> {
    let mut params = AUDIOCLIENT_ACTIVATION_PARAMS {
        ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
        Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 {
            ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                TargetProcessId: pid,
                ProcessLoopbackMode: PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            },
        },
    };
    let blob = BlobVariant {
        vt: 65, // VT_BLOB
        reserved: [0; 3],
        size: std::mem::size_of::<AUDIOCLIENT_ACTIVATION_PARAMS>() as u32,
        data: &mut params as *mut _ as *mut u8,
    };
    let (tx, rx) = mpsc::sync_channel(1);
    let handler: IActivateAudioInterfaceCompletionHandler = Activated(tx).into();
    unsafe {
        let operation = ActivateAudioInterfaceAsync(
            VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
            &IAudioClient::IID,
            Some(&blob as *const BlobVariant as *const PROPVARIANT),
            &handler,
        )
        .map_err(|e| anyhow!("Nagrywanie aplikacji wymaga Windows 10 (2004) lub nowszego: {e}"))?;
        rx.recv_timeout(Duration::from_secs(5)).map_err(|_| anyhow!("Windows nie otworzył dźwięku aplikacji."))?;
        let mut result = HRESULT(0);
        let mut unknown: Option<IUnknown> = None;
        operation.GetActivateResult(&mut result, &mut unknown)?;
        result.ok().map_err(|e| anyhow!("Windows nie otworzył dźwięku aplikacji: {e}"))?;
        let client: IAudioClient = unknown.ok_or_else(|| anyhow!("Windows nie otworzył dźwięku aplikacji."))?.cast()?;
        // 32-bit float keeps what the app plays above full scale.
        let float = WAVEFORMATEX {
            wFormatTag: 3, // WAVE_FORMAT_IEEE_FLOAT
            nChannels: 2,
            nSamplesPerSec: rate,
            nAvgBytesPerSec: rate * 8,
            nBlockAlign: 8,
            wBitsPerSample: 32,
            cbSize: 0,
        };
        let flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM;
        client
            .Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2_000_000, 0, &float, None)
            .map_err(|e| anyhow!("Nie można nagrywać tej aplikacji: {e}"))?;
        Ok(client)
    }
}

/// Records app `id` at `rate` (stereo float) until `quit`, calling `data` with
/// interleaved samples. Time the app is silent (nothing delivered) becomes silence,
/// so the recording keeps real time. `ready` gets the result of opening.
pub fn run(id: &str, rate: u32, quit: Arc<AtomicBool>, ready: mpsc::SyncSender<Result<()>>, mut data: impl FnMut(&[f32])) -> Result<()> {
    let _com = Com::init();
    let opened = (|| -> Result<(IAudioClient, IAudioCaptureClient, HANDLE)> {
        let pid = find(id)?;
        let client = open(pid, rate)?;
        unsafe {
            let event = CreateEventW(None, false, false, windows::core::PCWSTR::null())?;
            client.SetEventHandle(event)?;
            let capture: IAudioCaptureClient = client.GetService()?;
            client.Start()?;
            Ok((client, capture, event))
        }
    })();
    let (client, capture, event) = match opened {
        Ok(v) => {
            let _ = ready.send(Ok(()));
            v
        }
        Err(e) => {
            let _ = ready.send(Err(anyhow!("{e}")));
            return Err(e);
        }
    };
    let started = Instant::now();
    let mut delivered: u64 = 0;
    let mut last_packet = Instant::now();
    let silence = vec![0f32; 2048];
    let result = (|| -> Result<()> {
        while !quit.load(Ordering::Acquire) {
            unsafe {
                let _ = WaitForSingleObject(event, 100);
                loop {
                    let n = capture.GetNextPacketSize()?;
                    if n == 0 {
                        break;
                    }
                    let mut ptr = std::ptr::null_mut();
                    let mut frames = 0u32;
                    let mut flags = 0u32;
                    capture.GetBuffer(&mut ptr, &mut frames, &mut flags, None, None)?;
                    let count = frames as usize * 2;
                    if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 || ptr.is_null() {
                        let mut left = count;
                        while left > 0 {
                            let k = left.min(silence.len());
                            data(&silence[..k]);
                            left -= k;
                        }
                    } else {
                        data(std::slice::from_raw_parts(ptr as *const f32, count));
                    }
                    capture.ReleaseBuffer(frames)?;
                    delivered += frames as u64;
                    last_packet = Instant::now();
                }
            }
            // The app went quiet (paused, between files): Windows sends nothing, so
            // fill the time with silence once nothing came for a quarter of a second.
            if last_packet.elapsed() > Duration::from_millis(250) {
                let expected = (started.elapsed().as_secs_f64() * rate as f64) as u64;
                let mut missing = expected.saturating_sub(delivered) as usize * 2;
                delivered = delivered.max(expected);
                while missing > 0 {
                    let k = missing.min(silence.len());
                    data(&silence[..k]);
                    missing -= k;
                }
            }
        }
        Ok(())
    })();
    unsafe {
        let _ = client.Stop();
        let _ = CloseHandle(event);
    }
    if result.is_err() && find(id).is_err() {
        bail!("Aplikacja została zamknięta podczas nagrania.")
    }
    result
}

#[cfg(test)]
mod tests {
    #[test]
    fn app_names() {
        assert_eq!(super::app_name(r"C:\Users\Mat\AppData\Roaming\Spotify\Spotify.exe"), "Spotify");
        assert_eq!(super::app_name(r"C:\Program Files\foobar2000\foobar2000.exe"), "Foobar2000");
    }
}
