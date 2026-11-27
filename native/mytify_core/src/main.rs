// The desktop app is a window, not a console program: no command window at start.
// (Tests and --headless keep their output; see attach_console.)
#![cfg_attr(all(windows, feature = "desktop", not(debug_assertions)), windows_subsystem = "windows")]
use anyhow::{bail, Context, Result};
use mytify_core::server;
use std::{io::Write, path::PathBuf, sync::Arc};

#[cfg(all(windows, feature = "desktop"))]
mod chrome;
#[cfg(all(windows, feature = "desktop"))]
mod desktop;
#[cfg(all(windows, feature = "desktop"))]
mod os_media;

/// Started from a terminal with --headless or --version: print there.
#[cfg(all(windows, feature = "desktop"))]
fn attach_console() {
    if std::env::args().any(|a| a == "--headless" || a == "--version" || a == "--browser") {
        unsafe {
            windows_sys::Win32::System::Console::AttachConsole(u32::MAX);
        }
    }
}

/// A crash in the window app has no console: write it to a log next to the library
/// and tell the user.
#[cfg(all(windows, feature = "desktop"))]
fn crash_log() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(dir) = std::env::var_os("LOCALAPPDATA") {
            let path = PathBuf::from(dir).join("Mytify").join("mytify-crash.log");
            let _ = std::fs::create_dir_all(path.parent().unwrap());
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
                let _ = writeln!(f, "{info}\n{}", std::backtrace::Backtrace::force_capture());
            }
        }
        default(info);
    }));
}

fn main() {
    #[cfg(all(windows, feature = "desktop"))]
    {
        attach_console();
        crash_log();
    }
    if let Err(error) = run() {
        eprintln!("Mytify: {error:#}");
        #[cfg(all(windows, feature = "desktop"))]
        desktop::show_error(&format!("Nie można uruchomić Mytify.\n\n{error:#}"));
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let value = |key: &str| {
        args.iter()
            .position(|a| a == key)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    if args.iter().any(|a| a == "--version") {
        println!("Mytify 0.9.0");
        return Ok(());
    }
    let data = value("--data-dir").map(PathBuf::from).unwrap_or_else(|| {
        let root = std::env::var_os(if cfg!(windows) {
            "LOCALAPPDATA"
        } else {
            "XDG_DATA_HOME"
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        root.join("Mytify").join("library-v2")
    });
    let port = value("--port")
        .map(|v| v.parse::<u16>())
        .transpose()?
        .unwrap_or(47173);
    let ui = value("--ui-dir").map(PathBuf::from);
    let headless = args.iter().any(|a| a == "--headless");
    let _browser = args.iter().any(|a| a == "--browser");
    #[cfg(debug_assertions)]
    let audio_test = args.iter().any(|a| a == "--audio-test");
    #[cfg(not(debug_assertions))]
    if args
        .iter()
        .any(|a| a == "--audio-test" || a == "--audio-test-output")
    {
        bail!("Wyjście testowe jest dostępne tylko w buildzie testowym.");
    }
    #[cfg(not(debug_assertions))]
    let audio_test = false;
    #[cfg(debug_assertions)]
    let capture = value("--audio-test-output").map(PathBuf::from);
    #[cfg(not(debug_assertions))]
    let capture = None;
    // One desktop window: a second start brings the first one to the front.
    #[cfg(all(windows, feature = "desktop"))]
    if !headless && !_browser {
        if !chrome::single_instance() {
            return Ok(());
        }
        chrome::app_id();
    }
    let running = Arc::new(
        server::start_with_audio(data, port, ui, audio_test, capture)
            .context("Uruchomienie lokalnego katalogu")?,
    );
    if headless {
        println!(
            "{}",
            serde_json::json!({"base":running.app.origin,"token":running.app.token,"version":"0.9.0"})
        );
    }
    std::io::stdout().flush()?;
    #[cfg(all(windows, feature = "desktop"))]
    if !headless && !_browser {
        let worker = running.clone();
        std::thread::spawn(move || worker.serve());
        let app = running.app.clone();
        desktop::run(running.app.clone(), move || {
            let _ = app.player.flush_settings();
        })?;
        return Ok(());
    }
    if !headless {
        #[cfg(windows)]
        std::process::Command::new("cmd")
            .args(["/C", "start", "", &running.app.origin])
            .spawn()?;
        #[cfg(not(windows))]
        {
            let _ = std::process::Command::new("xdg-open")
                .arg(&running.app.origin)
                .spawn();
        }
        eprintln!(
            "Mytify działa lokalnie pod {}. Zamknij to okno, aby zakończyć.",
            running.app.origin
        );
    }
    running.serve();
    bail!("Serwer Mytify został zatrzymany.")
}
