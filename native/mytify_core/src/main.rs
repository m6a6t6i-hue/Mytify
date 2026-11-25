use anyhow::{bail, Context, Result};
use mytify_core::server;
use std::{io::Write, path::PathBuf, sync::Arc};

#[cfg(all(windows, feature = "desktop"))]
mod desktop;

fn main() {
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
        desktop::run(&running.app.origin, &running.app.catalog.root, move || {
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
