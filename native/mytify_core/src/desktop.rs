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
    System::Console::GetConsoleWindow,
    UI::WindowsAndMessaging::{MessageBoxW, ShowWindow, MB_ICONERROR, MB_OK, SW_HIDE},
};
use wry::{NewWindowResponse, WebContext, WebViewBuilder};

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

/// Remembered between runs: where the mini player floats and whether it stays on top.
#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Placement {
    mini: Option<(i32, i32)>,
    nano: Option<(i32, i32)>,
    #[serde(default = "pinned")]
    pin: bool,
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
                window.set_min_inner_size(Some(LogicalSize::new(760.0, 560.0)));
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
        self.save();
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
            .unwrap_or(Placement { pin: true, ..Default::default() }),
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
        .with_min_inner_size(LogicalSize::new(760.0, 560.0))
        .build(&event_loop)?;
    let mut web_context = WebContext::new(Some(data.join("webview-profile")));
    let origin = url.to_owned();
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
    unsafe {
        let console = GetConsoleWindow();
        if !console.is_null() {
            ShowWindow(console, SW_HIDE);
        }
    }
    event_loop.run(move |event, _, flow| {
        let _keep_alive = (&webview, &web_context, &window);
        *flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(v) if v["action"] == "nowPlaying" => media.update(&v),
            Event::UserEvent(v) => windowing.handle(&window, &v),
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                windowing.remember_floating(&window);
                windowing.save();
                on_close();
                *flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}
