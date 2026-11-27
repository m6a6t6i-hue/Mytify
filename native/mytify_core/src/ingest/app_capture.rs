//! Sound of one application (WASAPI process loopback, Windows 10 2004 or newer): only
//! that program and the processes it started. System sounds, other apps and Mytify
//! itself are not recorded, and the volume mixer does not change the level.
use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::{Duration, Instant},
};
use windows::{
    core::{implement, Interface, IUnknown, BOOL, HRESULT, PWSTR},
    Win32::{
        Foundation::{CloseHandle, HANDLE, HWND, LPARAM, S_OK},
        Media::Audio::*,
        System::{
            Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, StructuredStorage::PROPVARIANT, CLSCTX_ALL, COINIT_MULTITHREADED},
            Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS},
            Threading::{CreateEventW, OpenProcess, QueryFullProcessImageNameW, WaitForSingleObject, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION},
        },
        UI::WindowsAndMessaging::{EnumWindows, GetWindowLongW, GetWindowTextLengthW, GetWindowThreadProcessId, IsWindowVisible, GWL_EXSTYLE, WS_EX_TOOLWINDOW},
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

/// Programs that are not apps someone listens to (shell, helpers, Mytify itself).
const SKIP: &[&str] = &[
    "explorer", "applicationframehost", "textinputhost", "systemsettings", "shellexperiencehost", "startmenuexperiencehost",
    "searchhost", "searchapp", "lockapp", "msedgewebview2", "mytify", "widgets", "widgetservice", "phoneexperiencehost",
    "gamebar", "gamebarftserver", "ctfmon", "taskmgr", "svchost", "dwm", "csrss", "sihost", "runtimebroker", "conhost",
];

/// Music apps listed while running even without a visible window (closed to the tray).
const PLAYERS: &[&str] = &[
    "spotify", "tidal", "deezer", "qobuz", "applemusic", "itunes", "amazon music", "amazonmusic", "foobar2000", "aimp",
    "musicbee", "winamp", "vlc", "youtube music", "ytmdesktop", "audirvana", "roon", "plexamp", "tidalplayer",
];

struct Process {
    pid: u32,
    parent: u32,
    id: String,
    name: String,
}

/// All running processes, named like apps ("spotify" / "Spotify").
fn processes() -> Result<Vec<Process>> {
    let mut out = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)?;
        let mut e = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut ok = Process32FirstW(snap, &mut e).is_ok();
        while ok {
            let len = e.szExeFile.iter().position(|&c| c == 0).unwrap_or(e.szExeFile.len());
            let name = app_name(&String::from_utf16_lossy(&e.szExeFile[..len]));
            if !name.is_empty() {
                out.push(Process { pid: e.th32ProcessID, parent: e.th32ParentProcessID, id: name.to_lowercase(), name });
            }
            ok = Process32NextW(snap, &mut e).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    Ok(out)
}

unsafe extern "system" fn add_window(hwnd: HWND, list: LPARAM) -> BOOL {
    unsafe {
        let tool = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0;
        if IsWindowVisible(hwnd).as_bool() && !tool && GetWindowTextLengthW(hwnd) > 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            (*(list.0 as *mut HashSet<u32>)).insert(pid);
        }
    }
    BOOL(1)
}

/// Processes with a visible main window.
fn windowed() -> HashSet<u32> {
    let mut pids = HashSet::new();
    unsafe {
        let _ = EnumWindows(Some(add_window), LPARAM(&mut pids as *mut HashSet<u32> as isize));
    }
    pids
}

/// Apps to record from, one entry per program: every running program with a window
/// or sound, and music apps also when they sit in the tray. Nothing needs to play yet:
/// the recording waits for the first sound.
pub fn apps() -> Result<Value> {
    let procs = processes()?;
    let windows = windowed();
    let sessions = sessions().unwrap_or_default();
    let me = std::process::id();
    // name → (name, playing, has sound, listed)
    let mut by_id: BTreeMap<String, (String, bool, bool, bool)> = BTreeMap::new();
    for p in &procs {
        if p.pid == me || SKIP.contains(&p.id.as_str()) {
            continue;
        }
        let e = by_id.entry(p.id.clone()).or_insert((p.name.clone(), false, false, false));
        e.3 |= windows.contains(&p.pid) || PLAYERS.contains(&p.id.as_str());
    }
    for s in &sessions {
        let id = app_name(&s.path).to_lowercase();
        if let Some(e) = by_id.get_mut(&id) {
            e.1 |= s.active;
            e.2 = true;
            e.3 = true;
        }
    }
    let mut list: Vec<(String, String, bool, bool, bool)> = by_id
        .into_iter()
        .filter(|(_, e)| e.3)
        .map(|(id, (name, playing, sound, _))| {
            let player = PLAYERS.contains(&id.as_str());
            (id, name, playing, sound, player)
        })
        .collect();
    list.sort_by_key(|(id, _, playing, sound, player)| (!*player, !*playing, !*sound, id.clone()));
    Ok(json!(list
        .into_iter()
        .map(|(id, name, playing, sound, player)| json!({"id": id, "name": name, "playing": playing, "sound": sound, "player": player}))
        .collect::<Vec<_>>()))
}

/// The process to record for app `id` ("spotify"): the top of its process tree (its
/// helpers are included), the instance that is playing when there are several.
fn find(id: &str) -> Result<u32> {
    let procs = processes()?;
    let mine: Vec<&Process> = procs.iter().filter(|p| p.id == id).collect();
    let pids: HashSet<u32> = mine.iter().map(|p| p.pid).collect();
    let root = |mut pid: u32| {
        for _ in 0..64 {
            match mine.iter().find(|p| p.pid == pid) {
                Some(p) if pids.contains(&p.parent) && p.parent != pid => pid = p.parent,
                _ => break,
            }
        }
        pid
    };
    let playing = sessions()
        .unwrap_or_default()
        .into_iter()
        .filter(|s| pids.contains(&s.pid))
        .max_by_key(|s| s.active)
        .map(|s| s.pid);
    if let Some(pid) = playing {
        return Ok(root(pid));
    }
    let windows = windowed();
    let roots: Vec<u32> = mine.iter().filter(|p| !pids.contains(&p.parent)).map(|p| p.pid).collect();
    roots
        .iter()
        .find(|p| windows.contains(p))
        .or(roots.first())
        .copied()
        .ok_or_else(|| anyhow!("Ta aplikacja nie jest uruchomiona. Włącz ją i odśwież listę."))
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
