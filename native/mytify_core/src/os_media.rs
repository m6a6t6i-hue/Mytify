//! Windows media integration for the desktop app: System Media Transport Controls
//! (media keys, the volume flyout, lock screen) and play/next/previous buttons in the
//! taskbar thumbnail. Both drive the same Rust player as the UI does.
use mytify_core::{audio::Action, server::App};
use serde_json::{json, Value};
use souvlaki::{
    MediaControlEvent, MediaControls, MediaMetadata, MediaPlayback, MediaPosition,
    PlatformConfig, SeekDirection,
};
use std::{
    cell::RefCell,
    ffi::c_void,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tao::event_loop::EventLoopProxy;

fn act(app: &App, action: Action) {
    let _ = app.player.command(action);
}

fn toggle(app: &App) {
    let state = app.player.state();
    if state.current_id.is_none() {
        return;
    }
    act(app, if state.playing { Action::Pause } else { Action::Play });
}

fn on_media_key(app: &App, event: MediaControlEvent) {
    let state = app.player.state();
    match event {
        MediaControlEvent::Play => act(app, Action::Play),
        MediaControlEvent::Pause | MediaControlEvent::Stop => act(app, Action::Pause),
        MediaControlEvent::Toggle => toggle(app),
        MediaControlEvent::Next => act(app, Action::Next),
        MediaControlEvent::Previous => act(app, Action::Previous),
        MediaControlEvent::Seek(direction) | MediaControlEvent::SeekBy(direction, _) => {
            let step = match event {
                MediaControlEvent::SeekBy(_, by) => by.as_millis() as u64,
                _ => 10_000,
            };
            let position_ms = match direction {
                SeekDirection::Forward => (state.position_ms + step).min(state.duration_ms),
                SeekDirection::Backward => state.position_ms.saturating_sub(step),
            };
            act(app, Action::Seek { position_ms });
        }
        MediaControlEvent::SetPosition(MediaPosition(at)) => act(
            app,
            Action::Seek {
                position_ms: at.as_millis() as u64,
            },
        ),
        _ => {}
    }
}

/// Watches the player and sends "nowPlaying" to the window's event loop when the track,
/// play state or (every few seconds) the position changes.
pub fn watch(app: Arc<App>, proxy: EventLoopProxy<Value>) {
    std::thread::spawn(move || {
        let mut last: Option<(Option<String>, bool)> = None;
        let mut since = 0u32;
        loop {
            std::thread::sleep(Duration::from_millis(400));
            let s = app.player.state();
            let key = (s.current_id.clone(), s.playing);
            since += 1;
            let changed_track = last.as_ref().map(|l| &l.0) != Some(&s.current_id);
            if last.as_ref() == Some(&key) && since < 12 {
                continue;
            }
            since = 0;
            let mut v = json!({
                "action": "nowPlaying",
                "id": s.current_id,
                "playing": s.playing,
                "positionMs": s.position_ms,
                "durationMs": s.duration_ms,
                "meta": changed_track,
            });
            if changed_track {
                if let Some(t) = s.current_id.as_deref().and_then(|id| app.catalog.track(id).ok().flatten()) {
                    v["title"] = json!(t.title);
                    v["artist"] = json!(if t.artist.is_empty() { t.album_artist } else { t.artist });
                    v["album"] = json!(t.album);
                    if let Some(path) = t.cover.as_deref().and_then(|c| app.catalog.artwork_path(c).ok()) {
                        v["cover"] = json!(format!("file://{}", path.display()));
                    }
                }
            }
            last = Some(key);
            if proxy.send_event(v).is_err() {
                return;
            }
        }
    });
}

pub struct Media {
    controls: Option<MediaControls>,
}

impl Media {
    pub fn new(hwnd: *mut c_void, app: Arc<App>) -> Self {
        let controls = MediaControls::new(PlatformConfig {
            display_name: "Mytify",
            dbus_name: "mytify",
            hwnd: Some(hwnd),
        })
        .ok()
        .and_then(|mut c| {
            let a = app.clone();
            c.attach(move |e| on_media_key(&a, e)).ok()?;
            Some(c)
        });
        taskbar::install(hwnd, app);
        Self { controls }
    }

    pub fn update(&mut self, v: &Value) {
        let has = !v["id"].is_null();
        let playing = v["playing"].as_bool().unwrap_or(false);
        if let Some(c) = &mut self.controls {
            if v["meta"].as_bool().unwrap_or(false) {
                let _ = c.set_metadata(MediaMetadata {
                    title: Some(v["title"].as_str().unwrap_or("")),
                    artist: Some(v["artist"].as_str().unwrap_or("")),
                    album: Some(v["album"].as_str().unwrap_or("")),
                    cover_url: v["cover"].as_str(),
                    duration: Some(Duration::from_millis(v["durationMs"].as_u64().unwrap_or(0))),
                });
            }
            let progress = Some(MediaPosition(Duration::from_millis(
                v["positionMs"].as_u64().unwrap_or(0),
            )));
            let _ = c.set_playback(if !has {
                MediaPlayback::Stopped
            } else if playing {
                MediaPlayback::Playing { progress }
            } else {
                MediaPlayback::Paused { progress }
            });
        }
        taskbar::show_state(playing, has);
    }
}

/// Buttons in the taskbar thumbnail (ITaskbarList3). Everything runs on the UI thread.
mod taskbar {
    use super::*;
    use windows::Win32::{
        Foundation::HWND,
        System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED},
        UI::{
            Shell::{ITaskbarList3, TaskbarList, THBF_DISABLED, THBF_ENABLED, THB_FLAGS, THB_ICON, THB_TOOLTIP, THUMBBUTTON},
            WindowsAndMessaging::HICON,
        },
    };
    use windows_sys::Win32::{
        Graphics::Gdi::{CreateBitmap, DeleteObject},
        UI::{
            Shell::{DefSubclassProc, SetWindowSubclass},
            WindowsAndMessaging::{CreateIconIndirect, RegisterWindowMessageW, ICONINFO, WM_COMMAND},
        },
    };

    const THBN_CLICKED: usize = 0x1800;
    const PREVIOUS: u32 = 1;
    const TOGGLE: u32 = 2;
    const NEXT: u32 = 3;

    struct Bar {
        list: ITaskbarList3,
        hwnd: HWND,
        /// previous, play, pause, next
        icons: [HICON; 4],
        added: bool,
        playing: bool,
        enabled: bool,
    }

    thread_local! {
        static BAR: RefCell<Option<Bar>> = const { RefCell::new(None) };
    }
    static APP: OnceLock<Arc<App>> = OnceLock::new();
    static CREATED: OnceLock<u32> = OnceLock::new();

    /// White glyph with soft edges, drawn here so no icon files ship with the app.
    fn glyph(kind: u32) -> HICON {
        const N: usize = 32;
        let tri = |p: (f32, f32), a: (f32, f32), b: (f32, f32), c: (f32, f32)| {
            let s = |p: (f32, f32), q: (f32, f32), r: (f32, f32)| (p.0 - r.0) * (q.1 - r.1) - (q.0 - r.0) * (p.1 - r.1);
            let (d1, d2, d3) = (s(p, a, b), s(p, b, c), s(p, c, a));
            !((d1 < 0.0 || d2 < 0.0 || d3 < 0.0) && (d1 > 0.0 || d2 > 0.0 || d3 > 0.0))
        };
        let rect = |p: (f32, f32), x0: f32, x1: f32| p.0 >= x0 && p.0 <= x1 && p.1 >= 0.22 && p.1 <= 0.78;
        let inside = |p: (f32, f32)| match kind {
            0 => tri(p, (0.78, 0.22), (0.78, 0.78), (0.38, 0.5)) || rect(p, 0.24, 0.34),
            1 => tri(p, (0.3, 0.2), (0.3, 0.8), (0.8, 0.5)),
            2 => rect(p, 0.27, 0.42) || rect(p, 0.58, 0.73),
            _ => tri(p, (0.22, 0.22), (0.22, 0.78), (0.62, 0.5)) || rect(p, 0.66, 0.76),
        };
        let mut bgra = vec![0u8; N * N * 4];
        for y in 0..N {
            for x in 0..N {
                let mut hits = 0u32;
                for sy in 0..4 {
                    for sx in 0..4 {
                        let p = ((x as f32 + (sx as f32 + 0.5) / 4.0) / N as f32, (y as f32 + (sy as f32 + 0.5) / 4.0) / N as f32);
                        hits += inside(p) as u32;
                    }
                }
                let a = (hits * 255 / 16) as u8;
                let i = (y * N + x) * 4;
                // Premultiplied white.
                bgra[i..i + 4].copy_from_slice(&[a, a, a, a]);
            }
        }
        let mask = vec![0u8; N * N / 8];
        unsafe {
            let color = CreateBitmap(N as i32, N as i32, 1, 32, bgra.as_ptr().cast());
            let mono = CreateBitmap(N as i32, N as i32, 1, 1, mask.as_ptr().cast());
            let info = ICONINFO {
                fIcon: 1,
                xHotspot: 0,
                yHotspot: 0,
                hbmMask: mono,
                hbmColor: color,
            };
            let icon = CreateIconIndirect(&info);
            DeleteObject(color);
            DeleteObject(mono);
            HICON(icon)
        }
    }

    fn tip(text: &str) -> [u16; 260] {
        let mut out = [0u16; 260];
        for (i, c) in text.encode_utf16().take(259).enumerate() {
            out[i] = c;
        }
        out
    }

    fn buttons(bar: &Bar) -> [THUMBBUTTON; 3] {
        let flags = if bar.enabled { THBF_ENABLED } else { THBF_DISABLED };
        let b = |id: u32, icon: HICON, text: &str| THUMBBUTTON {
            dwMask: THB_ICON | THB_TOOLTIP | THB_FLAGS,
            iId: id,
            iBitmap: 0,
            hIcon: icon,
            szTip: tip(text),
            dwFlags: flags,
        };
        [
            b(PREVIOUS, bar.icons[0], "Poprzedni"),
            if bar.playing {
                b(TOGGLE, bar.icons[2], "Pauza")
            } else {
                b(TOGGLE, bar.icons[1], "Odtwarzaj")
            },
            b(NEXT, bar.icons[3], "Następny"),
        ]
    }

    fn add() {
        BAR.with(|b| {
            if let Ok(mut b) = b.try_borrow_mut() {
                if let Some(bar) = b.as_mut() {
                    if !bar.added {
                        bar.added = unsafe { bar.list.ThumbBarAddButtons(bar.hwnd, &buttons(bar)) }.is_ok();
                    }
                }
            }
        });
    }

    unsafe extern "system" fn subclass(
        hwnd: *mut c_void,
        msg: u32,
        wparam: usize,
        lparam: isize,
        _id: usize,
        _data: usize,
    ) -> isize {
        if Some(&msg) == CREATED.get() {
            add();
        } else if msg == WM_COMMAND && (wparam >> 16) & 0xffff == THBN_CLICKED {
            if let Some(app) = APP.get() {
                match (wparam & 0xffff) as u32 {
                    PREVIOUS => act(app, Action::Previous),
                    TOGGLE => toggle(app),
                    NEXT => act(app, Action::Next),
                    _ => {}
                }
            }
            return 0;
        }
        DefSubclassProc(hwnd, msg, wparam, lparam)
    }

    pub fn install(hwnd: *mut c_void, app: Arc<App>) {
        let _ = APP.set(app);
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            let name: Vec<u16> = "TaskbarButtonCreated\0".encode_utf16().collect();
            let _ = CREATED.set(RegisterWindowMessageW(name.as_ptr()));
            let created: windows::core::Result<ITaskbarList3> = CoCreateInstance(&TaskbarList, None, CLSCTX_INPROC_SERVER);
            let Ok(list) = created else {
                return;
            };
            if list.HrInit().is_err() {
                return;
            }
            BAR.with(|b| {
                *b.borrow_mut() = Some(Bar {
                    list,
                    hwnd: HWND(hwnd),
                    icons: [glyph(0), glyph(1), glyph(2), glyph(3)],
                    added: false,
                    playing: false,
                    enabled: false,
                })
            });
            SetWindowSubclass(hwnd, Some(subclass), 0x4d79, 0);
        }
        // The taskbar button may already exist: then "TaskbarButtonCreated" came before us.
        add();
    }

    pub fn show_state(playing: bool, enabled: bool) {
        BAR.with(|b| {
            if let Ok(mut b) = b.try_borrow_mut() {
                if let Some(bar) = b.as_mut() {
                    if bar.playing == playing && bar.enabled == enabled && bar.added {
                        return;
                    }
                    bar.playing = playing;
                    bar.enabled = enabled;
                    if bar.added {
                        let _ = unsafe { bar.list.ThumbBarUpdateButtons(bar.hwnd, &buttons(bar)) };
                    }
                }
            }
        });
        add();
    }
}
