use anyhow::{Context, Result};
use std::{os::windows::ffi::OsStrExt, path::Path};
use tao::{
    dpi::LogicalSize,
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoop},
    window::WindowBuilder,
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
pub fn run(url: &str, data: &Path, on_close: impl Fn() + 'static) -> Result<()> {
    let event_loop = EventLoop::new();
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
        .build(&window)
        .context(
            "Nie można otworzyć okna WebView2. Sprawdź instalację Microsoft Edge WebView2 Runtime.",
        )?;
    unsafe {
        let console = GetConsoleWindow();
        if !console.is_null() {
            ShowWindow(console, SW_HIDE);
        }
    }
    event_loop.run(move |event, _, flow| {
        let _keep_alive = (&webview, &web_context, &window);
        *flow = ControlFlow::Wait;
        if let Event::WindowEvent {
            event: WindowEvent::CloseRequested,
            ..
        } = event
        {
            on_close();
            *flow = ControlFlow::Exit;
        }
    });
}
