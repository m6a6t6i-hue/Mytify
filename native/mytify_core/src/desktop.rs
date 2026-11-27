use anyhow::{Context, Result};
use std::{os::windows::ffi::OsStrExt, sync::Arc};
use tao::{
    dpi::{LogicalSize, PhysicalPosition, PhysicalSize},
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    platform::windows::WindowExtWindows,
    window::{Fullscreen, Window, WindowBuilder},
};
use windows_sys::Win32::{
    Foundation::RECT,
    Graphics::Gdi::{MonitorFromRect, MONITOR_DEFAULTTONULL},
    UI::WindowsAndMessaging::{
        GetWindowPlacement, MessageBoxW, SetWindowPlacement, MB_ICONERROR, MB_OK, SW_HIDE, WINDOWPLACEMENT,
    },
};
use wry::{DragDropEvent, NewWindowResponse, WebContext, WebViewBuilder};

/// Smallest full window: below this the app would switch to its phone layout.
const MIN_WIDTH: f64 = 860.0;

/// Opens an http(s) link in the system browser, nothing else.
fn open_external(target: &str) {
    if !(target.starts_with("https://") || target.starts_with("http://")) {
        return;
    }
    let _ = std::process::Command::new("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", target])
        .spawn();
}

pub fn show_error(message: &str) {
    let text: Vec<u16> = std::ffi::OsStr::new(message)
        .encode_wide()
        .chain(Some(0))
        .collect();
    let title: Vec<u16> = std::ffi::OsStr::new("Mytify")
        .encode_wide()
        .chain(Some(0))
        .collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}
/// Window layouts the UI can ask for: the full app, the floating mini players and full screen.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Normal,
    Mini,
    Nano,
    Fullscreen,
}

impl Mode {
    fn size(self) -> Option<LogicalSize<f64>> {
        match self {
            Mode::Mini => Some(LogicalSize::new(244.0, 82.0)),
            Mode::Nano => Some(LogicalSize::new(196.0, 44.0)),
            _ => None,
        }
    }
}

/// Remembered between runs: the full window (normal position, size and maximized),
/// where the mini player floats, whether it stays on top, and closing to the tray.
#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Placement {
    mini: Option<(i32, i32)>,
    nano: Option<(i32, i32)>,
    #[serde(default = "pinned")]
    pin: bool,
    #[serde(default)]
    window: Option<(i32, i32, i32, i32, bool)>,
    #[serde(default = "pinned")]
    tray: bool,
    #[serde(default)]
    tray_told: bool,
}
fn pinned() -> bool {
    true
}

struct Windowing {
    mode: Mode,
    /// Full app position, size and maximized state to come back to.
    normal: Option<(PhysicalPosition<i32>, PhysicalSize<u32>, bool)>,
    place: Placement,
    file: std::path::PathBuf,
}

impl Windowing {
    fn save(&self) {
        if let Ok(b) = serde_json::to_vec(&self.place) {
            let _ = std::fs::write(&self.file, b);
        }
    }

    fn rounded(window: &Window, on: bool) {
        use windows_sys::Win32::Graphics::Dwm::{
            DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DEFAULT, DWMWCP_ROUND,
        };
        let value = if on { DWMWCP_ROUND } else { DWMWCP_DEFAULT };
        // Windows 11 rounds the borderless mini player; older systems ignore the call.
        unsafe {
            DwmSetWindowAttribute(
                window.hwnd() as _,
                DWMWA_WINDOW_CORNER_PREFERENCE as u32,
                (&value as *const i32).cast(),
                4,
            );
        }
    }

    fn remember_floating(&mut self, window: &Window) {
        if let Ok(p) = window.outer_position() {
            match self.mode {
                Mode::Mini => self.place.mini = Some((p.x, p.y)),
                Mode::Nano => self.place.nano = Some((p.x, p.y)),
                _ => {}
            }
        }
    }

    fn set(&mut self, window: &Window, next: Mode) {
        if next == self.mode {
            return;
        }
        if self.mode == Mode::Normal {
            if let Ok(p) = window.outer_position() {
                self.normal = Some((p, window.inner_size(), window.is_maximized()));
            }
        }
        self.remember_floating(window);
        match next {
            Mode::Normal => {
                window.set_fullscreen(None);
                window.set_always_on_top(false);
                Self::rounded(window, false);
                window.set_decorations(true);
                window.set_resizable(true);
                window.set_min_inner_size(Some(LogicalSize::new(MIN_WIDTH, 560.0)));
                if let Some((p, size, maximized)) = self.normal {
                    window.set_inner_size(size);
                    window.set_outer_position(p);
                    window.set_maximized(maximized);
                }
            }
            Mode::Mini | Mode::Nano => {
                window.set_fullscreen(None);
                window.set_maximized(false);
                window.set_decorations(false);
                window.set_resizable(false);
                window.set_min_inner_size(None::<LogicalSize<f64>>);
                let size = next.size().unwrap();
                window.set_inner_size(size);
                Self::rounded(window, true);
                let saved = if next == Mode::Mini { self.place.mini } else { self.place.nano };
                let position = saved.map(|(x, y)| PhysicalPosition::new(x, y)).or_else(|| {
                    // First time: bottom right corner of the current screen, above the taskbar.
                    let m = window.current_monitor()?;
                    let scale = m.scale_factor();
                    let px = size.to_physical::<i32>(scale);
                    let margin = (24.0 * scale) as i32;
                    let taskbar = (56.0 * scale) as i32;
                    Some(PhysicalPosition::new(
                        m.position().x + m.size().width as i32 - px.width - margin,
                        m.position().y + m.size().height as i32 - px.height - margin - taskbar,
                    ))
                });
                if let Some(p) = position {
                    window.set_outer_position(p);
                }
                window.set_always_on_top(self.place.pin);
            }
            Mode::Fullscreen => {
                if self.mode != Mode::Normal {
                    self.mode = Mode::Normal;
                    self.set(window, Mode::Normal);
                }
                window.set_fullscreen(Some(Fullscreen::Borderless(None)));
            }
        }
        self.mode = next;
        crate::chrome::enable(next == Mode::Normal);
        self.save();
    }

    /// Normal position and size of the full window (also while maximized).
    fn remember_window(&mut self, window: &Window) {
        if self.mode != Mode::Normal {
            return;
        }
        let mut p: WINDOWPLACEMENT = unsafe { std::mem::zeroed() };
        p.length = std::mem::size_of::<WINDOWPLACEMENT>() as u32;
        if unsafe { GetWindowPlacement(window.hwnd() as _, &mut p) } != 0 {
            let r = p.rcNormalPosition;
            self.place.window = Some((r.left, r.top, r.right, r.bottom, window.is_maximized()));
        }
    }

    /// Puts the window where it was, if that place is still on a screen; shows it.
    fn restore_window(&self, window: &Window) {
        if let Some((l, t, r, b, max)) = self.place.window {
            let rect = RECT { left: l, top: t, right: r, bottom: b };
            let on_screen = !unsafe { MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) }.is_null();
            if on_screen && r - l >= 400 && b - t >= 300 {
                // Position only (still hidden); showing and maximizing go through the
                // window library so it knows the state.
                let mut p: WINDOWPLACEMENT = unsafe { std::mem::zeroed() };
                p.length = std::mem::size_of::<WINDOWPLACEMENT>() as u32;
                p.showCmd = SW_HIDE as u32;
                p.rcNormalPosition = rect;
                if unsafe { SetWindowPlacement(window.hwnd() as _, &p) } != 0 && max {
                    window.set_maximized(true);
                }
            }
        }
        window.set_visible(true);
    }

    fn handle(&mut self, window: &Window, v: &serde_json::Value) {
        match v["action"].as_str().unwrap_or("") {
            "mode" => {
                let next = match v["mode"].as_str().unwrap_or("") {
                    "mini" => Mode::Mini,
                    "nano" => Mode::Nano,
                    "fullscreen" => Mode::Fullscreen,
                    _ => Mode::Normal,
                };
                self.set(window, next);
            }
            "drag" => {
                let _ = window.drag_window();
            }
            "pin" => {
                self.place.pin = v["value"].as_bool().unwrap_or(true);
                if matches!(self.mode, Mode::Mini | Mode::Nano) {
                    window.set_always_on_top(self.place.pin);
                }
                self.save();
            }
            "minimize" => window.set_minimized(true),
            "maximize" => window.set_maximized(!window.is_maximized()),
            "systemMenu" => crate::chrome::system_menu(),
            "chrome" => crate::chrome::colors(v),
            "progress" => crate::os_media::taskbar_progress(v["value"].as_f64(), v["state"].as_str().unwrap_or("normal")),
            "notify" => {
                // Only when the user is elsewhere: in the app the change is already visible.
                if !crate::chrome::focused() {
                    crate::chrome::notify(v["title"].as_str().unwrap_or("Mytify"), v["text"].as_str().unwrap_or(""));
                }
            }
            "closeToTray" => {
                self.place.tray = v["value"].as_bool().unwrap_or(true);
                self.save();
            }
            _ => {}
        }
    }
}

pub fn run(app: Arc<mytify_core::server::App>, on_close: impl Fn() + 'static) -> Result<()> {
    let url = app.origin.as_str();
    let data = app.catalog.root.as_path();
    let event_loop = EventLoopBuilder::<serde_json::Value>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let media_proxy = event_loop.create_proxy();
    let file = data.join("window.json");
    let mut windowing = Windowing {
        mode: Mode::Normal,
        normal: None,
        place: std::fs::read(&file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(Placement { pin: true, tray: true, ..Default::default() }),
        file,
    };
    let window = WindowBuilder::new()
        .with_title("Mytify")
        .with_theme(Some(tao::window::Theme::Dark))
        // Same dark as the Winyl intro, so the window never flashes white.
        .with_background_color((12, 13, 15, 255))
        .with_window_icon({
            let icon = image::load_from_memory(include_bytes!("../../../assets/mytify-icon.png"))?.to_rgba8();
            let (w, h) = icon.dimensions();
            Some(tao::window::Icon::from_rgba(icon.into_raw(), w, h)?)
        })
        .with_inner_size(LogicalSize::new(1280.0, 850.0))
        .with_min_inner_size(LogicalSize::new(MIN_WIDTH, 560.0))
        // Shown once the title bar is in place and the last position restored.
        .with_visible(false)
        .build(&event_loop)?;
    let mut web_context = WebContext::new(Some(data.join("webview-profile")));
    let origin = url.to_owned();
    let drop_proxy = event_loop.create_proxy();
    let chrome_proxy = event_loop.create_proxy();
    let webview = WebViewBuilder::new_with_web_context(&mut web_context)
        .with_url(url)
        .with_background_color((12, 13, 15, 255))
        // Links such as the author's page open in the default browser.
        .with_new_window_req_handler(|target, _| {
            open_external(&target);
            NewWindowResponse::Deny
        })
        .with_navigation_handler(move |next| {
            next == origin || next.starts_with(&format!("{origin}/"))
        })
        // Files and folders dragged from Explorer are imported.
        .with_drag_drop_handler(move |event| {
            if let DragDropEvent::Drop { paths, .. } = event {
                let list: Vec<String> = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
                let _ = drop_proxy.send_event(serde_json::json!({"action": "dropped", "paths": list}));
            }
            true
        })
        // Window layout requests from the page (mini player, full screen visualization).
        .with_ipc_handler(move |request| {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(request.body()) {
                let _ = proxy.send_event(v);
            }
        })
        .build(&window)
        .context(
            "Nie można otworzyć okna WebView2. Sprawdź instalację Microsoft Edge WebView2 Runtime.",
        )?;
    // Media keys, the volume flyout and taskbar buttons control the same player.
    let mut media = crate::os_media::Media::new(window.hwnd() as _, app.clone());
    crate::os_media::watch(app.clone(), media_proxy);
    // Title bar inside the app, tray icon; then the window appears where it was.
    crate::chrome::install(window.hwnd() as _, chrome_proxy);
    windowing.restore_window(&window);
    window.set_focus();
    crate::chrome::front();
    let player = app.clone();
    let quit = move |windowing: &mut Windowing, window: &Window, flow: &mut ControlFlow| {
        windowing.remember_floating(window);
        windowing.remember_window(window);
        windowing.save();
        crate::chrome::tray_remove();
        on_close();
        *flow = ControlFlow::Exit;
    };
    event_loop.run(move |event, _, flow| {
        let _keep_alive = (&webview, &web_context, &window);
        *flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(v) if v["action"] == "nowPlaying" => media.update(&v),
            Event::UserEvent(v) if v["action"] == "tray" => match v["command"].as_str().unwrap_or("") {
                command @ ("show" | "launch") => {
                    let hidden = !window.is_visible() || window.is_minimized();
                    window.set_visible(true);
                    if window.is_minimized() {
                        window.set_minimized(false);
                    }
                    window.set_focus();
                    crate::chrome::front();
                    // Started again from the Start menu or a shortcut: the intro plays
                    // like at a real start (not when brought back from the tray icon).
                    if command == "launch" && hidden {
                        let _ = webview.evaluate_script("window.mytifyIntro&&window.mytifyIntro()");
                    }
                }
                "minimize" => window.set_minimized(true),
                "maximize" => window.set_maximized(!window.is_maximized()),
                "toggle" => {
                    let s = player.player.state();
                    if s.current_id.is_some() {
                        let _ = player.player.command(if s.playing { mytify_core::audio::Action::Pause } else { mytify_core::audio::Action::Play });
                    }
                }
                "next" => {
                    let _ = player.player.command(mytify_core::audio::Action::Next);
                }
                "previous" => {
                    let _ = player.player.command(mytify_core::audio::Action::Previous);
                }
                "quit" => quit(&mut windowing, &window, flow),
                _ => {}
            },
            Event::UserEvent(v) if v["action"] == "dropped" => {
                // Folders become library sources, single files are imported as files.
                let (mut folders, mut files) = (Vec::new(), Vec::new());
                for p in v["paths"].as_array().into_iter().flatten().filter_map(|p| p.as_str()) {
                    if std::path::Path::new(p).is_dir() {
                        folders.push(p.to_string());
                    } else {
                        files.push(p.to_string());
                    }
                }
                let payload = serde_json::json!({"folders": folders, "files": files});
                let _ = webview.evaluate_script(&format!("window.mytifyDropped && window.mytifyDropped({payload})"));
            }
            Event::UserEvent(v) => windowing.handle(&window, &v),
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                // Closing hides to the tray (music goes on) unless the user turned it off.
                if windowing.place.tray && crate::chrome::has_tray() && windowing.mode == Mode::Normal {
                    windowing.remember_window(&window);
                    windowing.save();
                    window.set_visible(false);
                    if !windowing.place.tray_told {
                        windowing.place.tray_told = true;
                        windowing.save();
                        crate::chrome::notify(
                            "Mytify działa dalej",
                            "Muzyka gra, Mytify jest w zasobniku obok zegara. Zamkniesz go z menu ikony; w Ustawieniach wyłączysz chowanie.",
                        );
                    }
                } else {
                    quit(&mut windowing, &window, flow);
                }
            }
            _ => {}
        }
    });
}
