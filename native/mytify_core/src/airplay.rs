//! AirPlay C ABI. Library ownership outlives every function pointer and worker.
use crate::{
    audio::render::{Renderer, Signals},
    network::Target,
};
use anyhow::{anyhow, bail, Result};
use std::{
    ffi::{c_char, c_void, CString},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
type Open = unsafe extern "C" fn(
    *const c_char,
    i32,
    *const c_char,
    i32,
    i32,
    *const c_char,
    *const c_char,
    *const c_char,
    *const c_char,
) -> *mut c_void;
type State = unsafe extern "C" fn(*mut c_void) -> i32;
type Feed = unsafe extern "C" fn(*mut c_void, *const i16, i32) -> i32;
type Command = unsafe extern "C" fn(*mut c_void, i32, *const c_char);
type Text = unsafe extern "C" fn(*mut c_void, i32, *mut c_char, i32) -> i32;
type Close = unsafe extern "C" fn(*mut c_void);
struct Api {
    _lib: libloading::Library,
    open: Open,
    state: State,
    feed: Feed,
    free: State,
    command: Command,
    text: Text,
    close: Close,
}
impl Api {
    fn load() -> Result<Self> {
        let dir = std::env::current_exe()?
            .parent()
            .ok_or_else(|| anyhow!("Brak folderu programu"))?
            .to_owned();
        let file = dir.join(if cfg!(windows) {
            "mytify_airplay.dll"
        } else {
            "libmytify_airplay.so"
        });
        unsafe {
            let l = libloading::Library::new(file)
                .map_err(|e| anyhow!("Brak biblioteki AirPlay obok programu: {e}"))?;
            let r = Self {
                open: *l.get(b"mytify_airplay_open\0")?,
                state: *l.get(b"mytify_airplay_state\0")?,
                feed: *l.get(b"mytify_airplay_feed\0")?,
                free: *l.get(b"mytify_airplay_free\0")?,
                command: *l.get(b"mytify_airplay_command\0")?,
                text: *l.get(b"mytify_airplay_text\0")?,
                close: *l.get(b"mytify_airplay_close\0")?,
                _lib: l,
            };
            Ok(r)
        }
    }
}
pub struct Output {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Output {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
pub fn open(target: Target, mut renderer: Renderer, signals: Arc<Signals>) -> Result<Output> {
    let api = Api::load()?;
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    let root = crate::network::credential_root();
    let creds =
        std::fs::read_to_string(root.join(format!("{}.json", target.key()))).unwrap_or_default();
    let (tx, rx) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let c = |s: &str| CString::new(s.replace('\0', "")).unwrap();
        let identity = crate::network::sender_identity(&root);
        let p = unsafe {
            (api.open)(
                c(&target.host).as_ptr(),
                target.port as i32,
                c(&target.name).as_ptr(),
                target.auth,
                target.ap2 as i32,
                c(target.id.strip_prefix("airplay:").unwrap_or(&target.id)).as_ptr(),
                c(&creds).as_ptr(),
                c("").as_ptr(),
                c(&identity).as_ptr(),
            )
        };
        if p.is_null() {
            let _ = tx.send(Err("Nie można uruchomić nadajnika AirPlay".to_string()));
            return;
        }
        let _ = tx.send(Ok(()));
        let mut pcm = [0i16; 704];
        let mut floats = [0f32; 704];
        let mut started = Instant::now();
        let mut last_epoch = signals.epoch.load(Ordering::Acquire);
        let mut last_pause = true;
        let mut saved = creds;
        while !flag.load(Ordering::Acquire) {
            for (kind, text) in crate::network::airplay_commands() {
                unsafe { (api.command)(p, kind, c(&text).as_ptr()) };
                started = Instant::now();
            }
            let state = unsafe { (api.state)(p) };
            crate::network::airplay_status(
                state,
                if state == 3 {
                    let mut b = [0u8; 4096];
                    let n = unsafe { (api.text)(p, 0, b.as_mut_ptr().cast(), b.len() as i32) };
                    String::from_utf8_lossy(&b[..n.max(0) as usize]).into_owned()
                } else {
                    String::new()
                },
            );
            if state == 3
                || state == 4
                || (state == 0 && started.elapsed() > Duration::from_secs(25))
            {
                signals.device_failed.store(true, Ordering::Release);
                break;
            }
            let epoch = signals.epoch.load(Ordering::Acquire);
            let paused = signals.paused.load(Ordering::Acquire);
            if state == 1 && (epoch != last_epoch || (paused && !last_pause)) {
                unsafe { (api.command)(p, 3, c("").as_ptr()) };
                started = Instant::now();
                last_epoch = epoch;
                last_pause = paused;
                continue;
            }
            last_epoch = epoch;
            last_pause = paused;
            if state == 1 && !paused && unsafe { (api.free)(p) } >= 704 {
                renderer.render(&mut floats, 2);
                for (d, s) in pcm.iter_mut().zip(floats) {
                    *d = (s as f64 * 32768.).round().clamp(-32768., 32767.) as i16;
                }
                unsafe { (api.feed)(p, pcm.as_ptr(), 704) };
            } else {
                std::thread::sleep(Duration::from_millis(4));
            }
            if state == 1 {
                let mut b = vec![0u8; 16384];
                let n = unsafe { (api.text)(p, 1, b.as_mut_ptr().cast(), b.len() as i32) };
                if n > 0 {
                    let s = String::from_utf8_lossy(&b[..n as usize]).into_owned();
                    if s != saved {
                        let _ = crate::network::write_credentials(&root, &target.key(), &s);
                        saved = s;
                    }
                }
            }
        }
        unsafe { (api.close)(p) };
    });
    match rx.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok(())) => Ok(Output {
            stop,
            thread: Some(thread),
        }),
        _ => {
            stop.store(true, Ordering::Release);
            let _ = thread.join();
            bail!("Nie udało się uruchomić AirPlay")
        }
    }
}
