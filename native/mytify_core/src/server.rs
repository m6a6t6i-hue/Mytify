use crate::catalog::{
    getrandom_bytes, hex, Catalog, Progress, Report, ScanRequest, AUDIO_EXTENSIONS,
};
use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{Cursor, Read},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

#[cfg(feature = "embed-ui")]
static UI: include_dir::Dir<'_> = include_dir::include_dir!("$CARGO_MANIFEST_DIR/../../build/web");

#[derive(Clone, Serialize)]
pub struct Job {
    pub progress: Progress,
    pub result: Option<Report>,
    pub error: Option<String>,
    pub finished: bool,
}
pub struct App {
    pub transfer: Arc<crate::transfer::Transfer>,
    pub downloads: Arc<crate::downloads::Downloads>,
    pub ingest: crate::ingest::Ingest,
    pub network: crate::network::Network,
    pub player: crate::audio::Player,
    pub metadata: crate::metadata::MetadataService,
    pub catalog: Arc<Catalog>,
    pub token: String,
    pub origin: String,
    pub ui_dir: Option<PathBuf>,
    pub jobs: Mutex<HashMap<String, Job>>,
    pub cancellation: Mutex<HashMap<String, Arc<AtomicBool>>>,
    pub busy: AtomicBool,
    pub radio: crate::radio::Directory,
    pub shop: crate::shop::Shop,
}
pub struct RunningServer {
    pub app: Arc<App>,
    pub server: Arc<Server>,
}

pub fn start(data: PathBuf, port: u16, ui_dir: Option<PathBuf>) -> Result<RunningServer> {
    start_with_audio(data, port, ui_dir, false, None)
}
pub fn start_with_audio(
    data: PathBuf,
    port: u16,
    ui_dir: Option<PathBuf>,
    test: bool,
    capture: Option<PathBuf>,
) -> Result<RunningServer> {
    // Bind before opening the DB so a second instance cannot disturb a running scan.
    let server = Arc::new(
        Server::http(("127.0.0.1", port))
            .map_err(|e| anyhow!("Nie można uruchomić Mytify: {e}"))?,
    );
    let port = server
        .server_addr()
        .to_ip()
        .ok_or_else(|| anyhow!("Brak portu lokalnego"))?
        .port();
    let catalog = Arc::new(
        Catalog::open(data.clone())
            .with_context(|| format!("Otwarcie katalogu {}", data.display()))?,
    );
    let player = crate::audio::Player::new(catalog.clone(), test, capture);
    let app = Arc::new(App {
        transfer: crate::transfer::Transfer::new(catalog.clone())
            .context("Inicjalizacja transferu PC -> telefon")?,
        downloads: crate::downloads::Downloads::new(catalog.clone()).context("Inicjalizacja pobrań")?,
        ingest: crate::ingest::Ingest::new(catalog.clone()),
        network: crate::network::Network::new(catalog.clone())
            .context("Inicjalizacja odbiorników sieciowych")?,
        player,
        metadata: crate::metadata::MetadataService::new(data.clone()),
        catalog,
        token: hex(getrandom_bytes()?),
        origin: format!("http://127.0.0.1:{port}"),
        ui_dir,
        jobs: Mutex::new(HashMap::new()),
        cancellation: Mutex::new(HashMap::new()),
        busy: AtomicBool::new(false),
        radio: crate::radio::Directory::new(),
        shop: crate::shop::Shop::new(),
    });
    app.downloads.start();
    if !test {
        // Reachability of NAS shares, off the request path: an offline NAS must never block the UI.
        let catalog = app.catalog.clone();
        let downloads = app.downloads.clone();
        let transfer = app.transfer.clone();
        thread::spawn(move || loop {
            let _ = catalog.probe_network_sources();
            // Playlists kept offline pick up new entries when the server is back.
            let _ = downloads.refresh_kept(&transfer.playlist_entries());
            thread::sleep(std::time::Duration::from_secs(120));
        });
    }
    Ok(RunningServer { app, server })
}
impl RunningServer {
    pub fn serve(&self) {
        for request in self.server.incoming_requests() {
            let app = self.app.clone();
            thread::spawn(move || {
                if let Err(error) = handle(app, request) {
                    eprintln!("Żądanie lokalne: {error}");
                }
            });
        }
    }
}
fn header(request: &Request, name: &'static str) -> Option<String> {
    request
        .headers()
        .iter()
        .find(|h| h.field.equiv(name))
        .map(|h| h.value.as_str().to_owned())
}
fn token_equal(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |v, (a, b)| v | (a ^ b)) == 0
}
fn common_headers(content_type: &str) -> Vec<Header> {
    [
        ("Content-Type", content_type),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]
    .into_iter()
    .map(|(a, b)| Header::from_bytes(a, b).unwrap())
    .collect()
}
fn send_json(request: Request, code: u16, value: Value) -> Result<()> {
    let bytes = serde_json::to_vec(&value)?;
    let response = Response::new(
        StatusCode(code),
        common_headers("application/json; charset=utf-8"),
        Cursor::new(bytes.clone()),
        Some(bytes.len()),
        None,
    );
    request.respond(response)?;
    Ok(())
}
fn send_error(request: Request, code: u16, error: impl ToString) -> Result<()> {
    send_json(request, code, json!({"error":error.to_string()}))
}
fn read_json(request: &mut Request) -> Result<Value> {
    let mut body = Vec::new();
    request
        .as_reader()
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut body)?;
    if body.len() > 2 * 1024 * 1024 {
        bail!("Zbyt duże żądanie.");
    }
    Ok(serde_json::from_slice(&body)?)
}
fn encode_tracks(app: &App) -> Result<Value> {
    let mut tracks = app.catalog.tracks()?;
    for track in &mut tracks {
        if let Some(id) = track.cover.take() {
            track.cover = Some(format!(
                "{}/api/artwork/{id}?token={}",
                app.origin, app.token
            ));
        }
    }
    Ok(serde_json::to_value(tracks)?)
}

fn start_job(app: &Arc<App>, scan: ScanRequest) -> Result<String> {
    if app
        .busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed)
        .is_err()
    {
        bail!("Trwa już import lub skan biblioteki.");
    }
    let id = hex(getrandom_bytes()?);
    let cancel = Arc::new(AtomicBool::new(false));
    {
        let mut jobs = app.jobs.lock().unwrap();
        if jobs.len() > 64 {
            jobs.retain(|_, j| !j.finished);
        }
        jobs.insert(
            id.clone(),
            Job {
                progress: Progress::default(),
                result: None,
                error: None,
                finished: false,
            },
        );
    }
    app.cancellation
        .lock()
        .unwrap()
        .insert(id.clone(), cancel.clone());
    let app = app.clone();
    let worker_id = id.clone();
    thread::spawn(move || {
        let only = scan.source_id.clone();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut report = app.catalog.scan(scan, &cancel, |progress| {
                if let Some(job) = app.jobs.lock().unwrap().get_mut(&worker_id) {
                    job.progress = progress;
                }
            })?;
            // Music servers: playlists follow the library.
            for s in app.catalog.sources()?.into_iter().filter(|s| {
                s.kind == "subsonic" && s.state == "online" && only.as_ref().is_none_or(|o| *o == s.id)
            }) {
                if let Err(e) = crate::playlist_sync::sync(&app.catalog, &app.transfer, &s.id) {
                    report.errors.push(format!("{}: playlisty: {e}", s.name));
                }
            }
            let _ = app.downloads.refresh_kept(&app.transfer.playlist_entries());
            Ok::<_, anyhow::Error>(report)
        }));
        if let Some(job) = app.jobs.lock().unwrap().get_mut(&worker_id) {
            job.finished = true;
            match result {
                Ok(Ok(report)) => job.result = Some(report),
                Ok(Err(error)) => job.error = Some(error.to_string()),
                Err(_) => {
                    job.error = Some(
                        "Skan został przerwany przez błąd. Zapisane dane pozostają w katalogu."
                            .into(),
                    )
                }
            }
        }
        app.cancellation.lock().unwrap().remove(&worker_id);
        app.busy.store(false, Ordering::Release);
    });
    Ok(id)
}

fn flush_servers(app: &Arc<App>) {
    let catalog = app.catalog.clone();
    thread::spawn(move || {
        for s in catalog.sources().unwrap_or_default().into_iter().filter(|s| s.kind == "subsonic") {
            let _ = catalog.flush_pending(&s.id);
        }
    });
}

fn handle(app: Arc<App>, mut request: Request) -> Result<()> {
    let host = header(&request, "Host").unwrap_or_default();
    if host != app.origin.trim_start_matches("http://") {
        return send_error(request, 403, "Nieprawidłowy host lokalny.");
    }
    if let Some(origin) = header(&request, "Origin") {
        if origin != app.origin {
            return send_error(request, 403, "Żądania z innych witryn są zablokowane.");
        }
    }
    if header(&request, "Sec-Fetch-Site").is_some_and(|s| s == "cross-site" || s == "same-site") {
        return send_error(request, 403, "Dostęp jest dostępny tylko z okna Mytify.");
    }
    let parsed = url::Url::parse(&format!("{}{}", app.origin, request.url()))?;
    let path = parsed.path().to_string();
    let method = request.method().clone();
    if path == "/api/session" && method == Method::Get {
        return send_json(
            request,
            200,
            json!({"version":"0.9.0","token":app.token,"base":app.origin,"canPick":cfg!(windows),"dataDirectory":app.catalog.root.to_string_lossy(),"protocols":crate::sources::protocols()}),
        );
    }
    if path.starts_with("/api/") {
        let token = header(&request, "X-Mytify-Token")
            .or_else(|| {
                parsed
                    .query_pairs()
                    .find(|(k, _)| k == "token")
                    .map(|(_, v)| v.into_owned())
            })
            .unwrap_or_default();
        if !token_equal(&token, &app.token) {
            return send_error(request, 403, "Sesja wygasła. Otwórz Mytify ponownie.");
        }
        if path == "/api/transfer" && method == Method::Post {
            let result = read_json(&mut request).and_then(|v| app.transfer.command(v));
            // A playlist kept offline downloads the tracks added to it.
            let _ = app.downloads.refresh_kept(&app.transfer.playlist_entries());
            return match result {
                Ok(v) => send_json(request, 200, v),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/ingest" && method == Method::Post {
            let result = read_json(&mut request).and_then(|v| app.ingest.command(v));
            return match result {
                Ok(v) => send_json(request, 200, v),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/metadata/disc" && method == Method::Post {
            let result = read_json(&mut request)
                .and_then(|v| app.metadata.disc(v["id"].as_str().unwrap_or("")));
            return match result {
                Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                Err(e) => send_error(request, 502, e),
            };
        }
        if path == "/api/player/state" && method == Method::Get {
            return send_json(
                request,
                200,
                app.network.state(serde_json::to_value(app.player.state())?),
            );
        }
        if path == "/api/player/idle" && method == Method::Get {
            return send_json(request, 200, json!({ "idleMs": system_idle_ms() }));
        }
        if path == "/api/player/levels" && method == Method::Get {
            return send_json(request, 200, json!({ "bands": app.player.levels() }));
        }
        if path == "/api/shop/search" && method == Method::Get {
            let query: HashMap<_, _> = parsed.query_pairs().into_owned().collect();
            let q = query.get("q").cloned().unwrap_or_default();
            let country = query.get("country").cloned().unwrap_or_default();
            return match app.shop.search(&q, &country) {
                Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                Err(e) => send_error(request, 502, format!("{e:#}")),
            };
        }
        if path == "/api/radio/search" && method == Method::Get {
            let query: HashMap<_, _> = parsed.query_pairs().into_owned().collect();
            return match app.radio.search(&query) {
                Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                Err(e) => send_error(request, 502, format!("{e:#}")),
            };
        }
        if path == "/api/radio/click" && method == Method::Post {
            let id = read_json(&mut request)?["id"].as_str().unwrap_or("").to_string();
            // Counting a listen is a courtesy to the directory; playback never waits on it failing.
            let url = app.radio.click(&id).unwrap_or(None);
            return send_json(request, 200, json!({ "url": url }));
        }
        if path == "/api/radio/probe" && method == Method::Post {
            let url = read_json(&mut request)?["url"].as_str().unwrap_or("").trim().to_string();
            return match crate::radio::probe(&url) {
                Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                Err(e) => send_error(request, 400, format!("{e:#}")),
            };
        }
        if path == "/api/radio/logo" && method == Method::Get {
            let url = parsed.query_pairs().find(|(k, _)| k == "u").map(|(_, v)| v.into_owned()).unwrap_or_default();
            return match app.radio.logo(&url) {
                Ok((kind, bytes)) => {
                    let mut headers = common_headers(&kind);
                    headers.retain(|h| !h.field.equiv("Cache-Control"));
                    headers.push(Header::from_bytes("Cache-Control", "private, max-age=86400").unwrap());
                    let len = bytes.len();
                    request.respond(Response::new(StatusCode(200), headers, Cursor::new(bytes.to_vec()), Some(len), None))?;
                    Ok(())
                }
                Err(e) => send_error(request, 404, e),
            };
        }
        if path == "/api/player/devices" && method == Method::Get {
            return match app.player.devices() {
                Ok(mut v) => {
                    for t in crate::network::discover() {
                        v.push(crate::audio::device(&t.id, &t.name));
                    }
                    send_json(request, 200, serde_json::to_value(v)?)
                }
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/player/command" && method == Method::Post {
            let action = read_json(&mut request);
            let result = action.and_then(|v| {
                let action = v["action"].as_str().unwrap_or("");
                if action == "pin" {
                    let pin = v["value"].as_str().unwrap_or("");
                    if pin.len() != 4 || !pin.bytes().all(|b| b.is_ascii_digit()) {
                        bail!("PIN musi mieć 4 cyfry")
                    };
                    crate::network::queue_air(1, pin.into());
                    return Ok(());
                }
                if action == "device" {
                    let id = v["id"].as_str().unwrap_or("");
                    if let Some(t) = crate::network::target(id).filter(|t| t.kind == "dlna") {
                        let state = app.network.state(serde_json::to_value(app.player.state())?);
                        app.player.command(crate::audio::Action::Pause)?;
                        app.network.deselect();
                        return app.network.select(t, &state);
                    }
                    let old = app.network.state(serde_json::to_value(app.player.state())?);
                    let was_remote = app.network.active();
                    app.network.deselect();
                    app.player.command(serde_json::from_value(v)?)?;
                    if was_remote && old["radio"].is_object() {
                        let r = &old["radio"];
                        let text = |k: &str| r[k].as_str().unwrap_or("").to_string();
                        app.player.command(crate::audio::Action::Radio {
                            id: text("id"),
                            url: text("url"),
                            name: text("name"),
                            logo: text("logo"),
                            codec: String::new(),
                            bitrate: 0,
                            hls: false,
                            stations: serde_json::from_value(r["stations"].clone()).unwrap_or_default(),
                        })?;
                        if old["playing"] != true {
                            app.player.command(crate::audio::Action::Pause)?;
                        }
                    } else if was_remote {
                        if let (Ok(ids), Some(i)) = (
                            serde_json::from_value::<Vec<String>>(old["queueIds"].clone()),
                            old["index"].as_u64(),
                        ) {
                            if !ids.is_empty() {
                                app.player.command(crate::audio::Action::Restore {
                                    ids,
                                    index: i as usize,
                                    position_ms: old["positionMs"].as_u64().unwrap_or(0),
                                    playing: old["playing"] == true,
                                })?;
                            }
                        }
                    }
                    return Ok(());
                }
                if app.network.active() {
                    app.network.command(&v)
                } else {
                    app.player.command(serde_json::from_value(v)?)
                }
            });
            return match result {
                Ok(()) => send_json(
                    request,
                    200,
                    app.network.state(serde_json::to_value(app.player.state())?),
                ),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/metadata/search" && method == Method::Get {
            let query: HashMap<_, _> = parsed.query_pairs().into_owned().collect();
            let result = app.metadata.search(
                query.get("album").map(String::as_str).unwrap_or(""),
                query.get("artist").map(String::as_str).unwrap_or(""),
            );
            return match result {
                Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                Err(e) => send_error(request, 502, e),
            };
        }
        if let Some(id) = path.strip_prefix("/api/metadata/release/") {
            if method == Method::Get {
                return match app.metadata.release(id) {
                    Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                    Err(e) => send_error(request, 502, e),
                };
            }
        }
        if let Some(id) = path.strip_prefix("/api/metadata/discogs/") {
            if method == Method::Get {
                let id = url::form_urlencoded::parse(id.as_bytes()).map(|(k, _)| k).collect::<String>();
                return match app.metadata.discogs(&id) {
                    Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                    Err(e) => send_error(request, 502, e),
                };
            }
        }
        if let Some(id) = path.strip_prefix("/api/metadata/cover/") {
            if method == Method::Get {
                return match app.metadata.cover(id) {
                    Ok(hash) => {
                        let uri = hash
                            .as_ref()
                            .map(|h| format!("{}/api/artwork/{h}?token={}", app.origin, app.token));
                        send_json(request, 200, json!({"hash":hash,"uri":uri}))
                    }
                    Err(e) => send_error(request, 502, e),
                };
            }
        }
        if path == "/api/metadata/cover-file" && method == Method::Post {
            let mut bytes = Vec::new();
            request
                .as_reader()
                .take(8 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
            return match app.metadata.store_cover(&bytes) {
                Ok(hash) => {
                    let uri = format!("{}/api/artwork/{hash}?token={}", app.origin, app.token);
                    send_json(request, 200, json!({"hash":hash,"uri":uri}))
                }
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/metadata/edits" && method == Method::Post {
            let edits = read_json(&mut request)
                .and_then(|v| Ok(serde_json::from_value::<Vec<crate::metadata::Edit>>(v)?));
            return match edits.and_then(|edits| app.catalog.edit_metadata(edits)) {
                Ok(()) => send_json(request, 200, json!({"ok":true})),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/metadata/reset" && method == Method::Post {
            let ids =
                read_json(&mut request).and_then(|v| Ok(serde_json::from_value::<Vec<String>>(v)?));
            return match ids.and_then(|ids| app.catalog.reset_metadata(&ids)) {
                Ok(()) => send_json(request, 200, json!({"ok":true})),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/library" && method == Method::Get {
            return match encode_tracks(&app) {
                Ok(v) => send_json(request, 200, v),
                Err(e) => send_error(request, 500, e),
            };
        }
        if path == "/api/sources" && method == Method::Get {
            return match app.catalog.sources() {
                Ok(v) => send_json(request, 200, serde_json::to_value(v)?),
                Err(e) => send_error(request, 500, e),
            };
        }
        if path == "/api/search" && method == Method::Get {
            let q = parsed
                .query_pairs()
                .find(|(k, _)| k == "q")
                .map(|(_, v)| v.into_owned())
                .unwrap_or_default();
            return match app.catalog.search_ids(&q) {
                Ok(ids) => send_json(request, 200, json!(ids)),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/pick" && method == Method::Post {
            let args = match read_json(&mut request) {
                Ok(v) => v,
                Err(e) => return send_error(request, 400, e),
            };
            let folder = args["folder"].as_bool().unwrap_or(false);
            #[cfg(windows)]
            let paths: Vec<String> = if folder {
                rfd::FileDialog::new()
                    .set_title("Wybierz folder z muzyką")
                    .pick_folder()
                    .into_iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect()
            } else {
                rfd::FileDialog::new()
                    .set_title("Wybierz pliki muzyczne")
                    .add_filter("Muzyka", AUDIO_EXTENSIONS)
                    .pick_files()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect()
            };
            #[cfg(not(windows))]
            {
                let _ = folder;
                return send_error(
                    request,
                    501,
                    "Systemowy wybór plików w tej paczce jest dostępny na Windows.",
                );
            }
            #[cfg(windows)]
            return send_json(request, 200, json!({"paths":paths}));
        }
        if path == "/api/relink" && method == Method::Post {
            if app.busy.load(Ordering::Acquire) {
                return send_error(request, 409, "Zaczekaj na zakończenie skanowania.");
            }
            let args = match read_json(&mut request) {
                Ok(v) => v,
                Err(e) => return send_error(request, 400, e),
            };
            let id = args["id"].as_str().unwrap_or("");
            let target = PathBuf::from(args["path"].as_str().unwrap_or(""));
            return match app.catalog.relink_source(id, &target) {
                Ok(_) => send_json(request, 200, json!({"ok":true})),
                Err(e) => send_error(request, 400, e),
            };
        }
        if path == "/api/scan" && method == Method::Post {
            let args = match read_json(&mut request)
                .and_then(|v| Ok(serde_json::from_value::<ScanRequest>(v)?))
            {
                Ok(v) => v,
                Err(e) => return send_error(request, 400, e),
            };
            return match start_job(&app, args) {
                Ok(id) => send_json(request, 200, json!({"job":id})),
                Err(e) => send_error(request, 409, e),
            };
        }
        if let Some(id) = path.strip_prefix("/api/jobs/") {
            if method == Method::Get {
                let job = app.jobs.lock().unwrap().get(id).cloned();
                return match job {
                    Some(job) => send_json(request, 200, serde_json::to_value(job)?),
                    None => send_error(request, 404, "Nie znaleziono zadania."),
                };
            }
            if method == Method::Delete {
                if let Some(cancel) = app.cancellation.lock().unwrap().get(id) {
                    cancel.store(true, Ordering::Release);
                }
                return send_json(request, 200, json!({"ok":true}));
            }
        }
        if let Some(id) = path.strip_prefix("/api/like/") {
            if method == Method::Post {
                let args = match read_json(&mut request) {
                    Ok(v) => v,
                    Err(e) => return send_error(request, 400, e),
                };
                return match app
                    .catalog
                    .like(id, args["liked"].as_bool().unwrap_or(false))
                {
                    Ok(_) => {
                        // Music servers get the change in the background; offline it waits.
                        flush_servers(&app);
                        send_json(request, 200, json!({"ok":true}))
                    }
                    Err(e) => send_error(request, 400, e),
                };
            }
        }
        if path == "/api/downloads" && method == Method::Get {
            return match app.downloads.status() {
                Ok(status) => {
                    let mut v = serde_json::to_value(status)?;
                    v["kept"] = json!(app.downloads.kept_playlists().unwrap_or_default());
                    send_json(request, 200, v)
                }
                Err(e) => send_error(request, 400, e),
            };
        }
        if let Some(action) = path.strip_prefix("/api/downloads/") {
            if method != Method::Post {
                return send_error(request, 405, "Nieobsługiwana metoda.");
            }
            let args = match read_json(&mut request) {
                Ok(v) => v,
                Err(e) => return send_error(request, 400, e),
            };
            let ids: Vec<String> = args["ids"]
                .as_array()
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).take(20000).collect())
                .unwrap_or_default();
            let result = match action {
                "estimate" => app.downloads.estimate(&ids).and_then(|e| Ok(serde_json::to_value(e)?)),
                "add" => app.downloads.add(&ids, "user").map(|n| json!({"queued":n})),
                "pause" => {
                    app.downloads.pause(args["paused"].as_bool().unwrap_or(false));
                    Ok(json!({"ok":true}))
                }
                "cancel" => app.downloads.cancel(&ids).map(|_| json!({"ok":true})),
                "remove" => app.downloads.remove(&ids).map(|_| json!({"ok":true})),
                "keep" => {
                    let playlist = args["playlist"].as_str().unwrap_or("").to_string();
                    let tracks = app
                        .transfer
                        .playlist_entries()
                        .into_iter()
                        .find(|p| p.0 == playlist)
                        .map(|p| p.2)
                        .unwrap_or_default();
                    app.downloads
                        .keep_playlist(&playlist, args["keep"].as_bool().unwrap_or(false), &tracks)
                        .map(|_| json!({"ok":true}))
                }
                _ => return send_error(request, 404, "Nieznana operacja."),
            };
            return match result {
                Ok(v) => send_json(request, 200, v),
                Err(e) => send_error(request, 400, e),
            };
        }
        if let Some(id) = path.strip_prefix("/api/played/") {
            if method == Method::Post {
                let catalog = app.catalog.clone();
                let id = id.to_owned();
                thread::spawn(move || {
                    let _ = catalog.played(&id);
                });
                return send_json(request, 200, json!({"ok":true}));
            }
        }
        if let Some(id) = path.strip_prefix("/api/tracks/") {
            if method == Method::Delete {
                return match app.catalog.forget_track(id) {
                    Ok(_) => send_json(request, 200, json!({"ok":true})),
                    Err(e) => send_error(request, 400, e),
                };
            }
        }
        if path == "/api/sources/test" || path == "/api/sources/browse" || path == "/api/sources/save" {
            if method != Method::Post {
                return send_error(request, 405, "Nieobsługiwana metoda.");
            }
            let args = match read_json(&mut request) {
                Ok(v) => v,
                Err(e) => return send_error(request, 400, e),
            };
            let id = args["id"].as_str().filter(|s| !s.is_empty()).map(str::to_owned);
            let config: crate::sources::NetworkConfig =
                match serde_json::from_value(args["config"].clone()) {
                    Ok(c) => c,
                    Err(_) => return send_error(request, 400, "Nieprawidłowe ustawienia źródła."),
                };
            // Network calls can take a while; this request has its own thread.
            let result = match path.as_str() {
                "/api/sources/test" if config.protocol == "subsonic" => {
                    crate::sources::describe(id.as_deref(), &config)
                        .map(|message| json!({"ok":true,"folders":[],"message":message}))
                }
                "/api/sources/test" => crate::sources::test(id.as_deref(), &config)
                    .map(|folders| json!({"ok":true,"folders":folders})),
                "/api/sources/browse" => crate::sources::browse(
                    id.as_deref(),
                    &config,
                    args["path"].as_str().unwrap_or(""),
                )
                .map(|folders| json!({"folders":folders})),
                _ => {
                    if app.busy.load(Ordering::Acquire) && id.is_some() {
                        return send_error(request, 409, "Zaczekaj na zakończenie skanowania.");
                    }
                    app.catalog
                        .save_network_source(id.as_deref(), &config)
                        .map(|id| json!({"id":id}))
                }
            };
            return match result {
                Ok(v) => send_json(request, 200, v),
                Err(e) => send_error(request, 400, e),
            };
        }
        if let Some(id) = path
            .strip_prefix("/api/sources/")
            .and_then(|p| p.strip_suffix("/settings"))
        {
            if method == Method::Get {
                return match app.catalog.network_settings(id) {
                    Ok(Some(c)) => {
                        let has_password = crate::secrets::load(id).ok().flatten().is_some_and(|p| !p.is_empty());
                        let mut v = serde_json::to_value(c)?;
                        v["hasPassword"] = json!(has_password);
                        send_json(request, 200, v)
                    }
                    Ok(None) => send_error(request, 404, "To źródło nie ma ustawień sieciowych."),
                    Err(e) => send_error(request, 400, e),
                };
            }
        }
        if let Some(id) = path.strip_prefix("/api/sources/") {
            if method == Method::Delete {
                if app.busy.load(Ordering::Acquire) {
                    return send_error(request, 409, "Zaczekaj na zakończenie skanowania.");
                }
                return match app.catalog.forget_source(id) {
                    Ok(_) => send_json(request, 200, json!({"ok":true})),
                    Err(e) => send_error(request, 400, e),
                };
            }
        }
        if let Some(id) = path.strip_prefix("/api/audio/") {
            if method == Method::Get || method == Method::Head {
                return match app.catalog.audio_path(id) {
                    Ok(file) => send_file(request, file, true),
                    // WebDAV tracks are streamed through, with ranges.
                    Err(_) => match app.catalog.open_audio(id) {
                        Ok(input) => send_input(request, input),
                        Err(e) => send_error(request, 404, e),
                    },
                };
            }
        }
        if let Some(id) = path.strip_prefix("/api/artwork/") {
            if method == Method::Get || method == Method::Head {
                return match app.catalog.artwork_path(id) {
                    Ok(file) => send_file(request, file, false),
                    Err(e) => send_error(request, 404, e),
                };
            }
        }
        if path == "/api/migrate-v01" && method == Method::Post {
            return migrate(app, request);
        }
        return send_error(request, 404, "Nie ma takiej funkcji.");
    }
    if method != Method::Get && method != Method::Head {
        return send_error(request, 405, "Niedozwolona metoda.");
    }
    let relative = if path == "/" {
        "index.html"
    } else {
        path.trim_start_matches('/')
    };
    if relative.split('/').any(|p| p == "..") || relative.contains('\\') {
        return send_error(request, 403, "Nieprawidłowa ścieżka.");
    }
    #[cfg(feature = "embed-ui")]
    if let Some(file) = UI.get_file(relative) {
        let bytes = file.contents();
        let size = bytes.len();
        let response = Response::new(
            StatusCode(200),
            common_headers(mime(relative)),
            Cursor::new(bytes),
            Some(size),
            None,
        );
        request.respond(response)?;
        return Ok(());
    }
    if let Some(root) = &app.ui_dir {
        let target = root.join(relative);
        if let (Ok(canonical), Ok(root)) = (fs::canonicalize(&target), fs::canonicalize(root)) {
            if canonical.starts_with(root) && canonical.is_file() {
                return send_file(request, canonical, false);
            }
        }
    }
    send_error(request, 404, "Brakuje plików interfejsu Mytify.")
}

fn mime(path: &str) -> &'static str {
    match path
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "wasm" => "application/wasm",
        "css" => "text/css",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "m4a" | "mp4" => "audio/mp4",
        "aac" => "audio/aac",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "opus" => "audio/ogg",
        "aif" | "aiff" => "audio/aiff",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        _ => "application/octet-stream",
    }
}
pub fn parse_range(value: &str, length: u64) -> Option<(u64, u64)> {
    if length == 0 {
        return None;
    }
    let range = value.strip_prefix("bytes=")?;
    if range.contains(',') {
        return None;
    }
    let (left, right) = range.split_once('-')?;
    if left.is_empty() {
        let suffix: u64 = right.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((length.saturating_sub(suffix), length - 1));
    }
    let start: u64 = left.parse().ok()?;
    let end = if right.is_empty() {
        length - 1
    } else {
        right.parse::<u64>().ok()?.min(length - 1)
    };
    if start > end || start >= length {
        return None;
    }
    Some((start, end))
}
fn send_file(request: Request, path: PathBuf, ranges: bool) -> Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut file = File::open(&path)?;
    let length = file.metadata()?.len();
    let mut headers = common_headers(mime(&path.to_string_lossy()));
    // Artwork cache files have no extension; inspect only their signature.
    if path.parent().is_some_and(|p| p.ends_with("artwork")) {
        let mut signature = [0u8; 12];
        let count = file.read(&mut signature)?;
        file.seek(SeekFrom::Start(0))?;
        let kind = if count >= 8 && &signature[..8] == b"\x89PNG\r\n\x1a\n" {
            "image/png"
        } else if count >= 3 && &signature[..3] == b"\xff\xd8\xff" {
            "image/jpeg"
        } else {
            "application/octet-stream"
        };
        headers[0] = Header::from_bytes("Content-Type", kind).unwrap();
    }
    let mut start = 0;
    let mut end = length.saturating_sub(1);
    let mut status = 200;
    if ranges {
        headers.push(Header::from_bytes("Accept-Ranges", "bytes").unwrap());
        if let Some(value) = header(&request, "Range") {
            if let Some((a, b)) = parse_range(&value, length) {
                start = a;
                end = b;
                status = 206;
                headers.push(
                    Header::from_bytes("Content-Range", format!("bytes {a}-{b}/{length}")).unwrap(),
                );
            } else {
                headers.push(
                    Header::from_bytes("Content-Range", format!("bytes */{length}")).unwrap(),
                );
                request.respond(Response::new(
                    StatusCode(416),
                    headers,
                    Cursor::new(Vec::<u8>::new()),
                    Some(0),
                    None,
                ))?;
                return Ok(());
            }
        }
    }
    let count = if length == 0 { 0 } else { end - start + 1 };
    file.seek(SeekFrom::Start(start))?;
    request.respond(Response::new(
        StatusCode(status),
        headers,
        file.take(count),
        Some(count as usize),
        None,
    ))?;
    Ok(())
}

fn send_input(request: Request, mut input: crate::remote_scan::AudioInput) -> Result<()> {
    use std::io::{Seek, SeekFrom};
    let length = input.len;
    let mut headers = common_headers(mime(&input.name));
    headers.push(Header::from_bytes("Accept-Ranges", "bytes").unwrap());
    let (mut start, mut end, mut status) = (0, length.saturating_sub(1), 200);
    if let Some(value) = header(&request, "Range") {
        match parse_range(&value, length) {
            Some((a, b)) => {
                (start, end, status) = (a, b, 206);
                headers.push(Header::from_bytes("Content-Range", format!("bytes {a}-{b}/{length}")).unwrap());
            }
            None => {
                headers.push(Header::from_bytes("Content-Range", format!("bytes */{length}")).unwrap());
                request.respond(Response::new(StatusCode(416), headers, Cursor::new(Vec::<u8>::new()), Some(0), None))?;
                return Ok(());
            }
        }
    }
    let count = if length == 0 { 0 } else { end - start + 1 };
    input.reader.seek(SeekFrom::Start(start))?;
    request.respond(Response::new(StatusCode(status), headers, input.reader.take(count), Some(count as usize), None))?;
    Ok(())
}

fn migrate(app: Arc<App>, mut request: Request) -> Result<()> {
    if app
        .busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed)
        .is_err()
    {
        return send_error(request, 409, "Trwa już skanowanie biblioteki.");
    }
    let result = (|| -> Result<Report> {
        let hash = header(&request, "X-Mytify-Hash").unwrap_or_default();
        if hash.len() != 64 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
            bail!("Nieprawidłowa suma kontrolna.");
        }
        let name = header(&request, "X-Mytify-Filename").unwrap_or_else(|| "audio.flac".into());
        let decoded = url::form_urlencoded::parse(format!("name={name}").as_bytes())
            .next()
            .map(|(_, v)| v.into_owned())
            .unwrap_or(name);
        let extension = std::path::Path::new(&decoded)
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        if !AUDIO_EXTENSIONS.contains(&extension.as_str()) {
            bail!("Nieobsługiwany format pliku.");
        }
        let destination = app
            .catalog
            .root
            .join("imported-v01")
            .join(format!("{hash}.{extension}"));
        let temporary = destination.with_extension("partial");
        const LIMIT: u64 = 8 * 1024 * 1024 * 1024;
        if request.body_length().is_some_and(|n| n as u64 > LIMIT) {
            bail!("Plik przekracza limit przenoszenia 8 GB.");
        }
        let mut file = File::create(&temporary)?;
        let count = std::io::copy(&mut request.as_reader().take(LIMIT + 1), &mut file)?;
        file.sync_all()?;
        drop(file);
        if count > LIMIT {
            let _ = fs::remove_file(&temporary);
            bail!("Plik jest zbyt duży.");
        }
        if crate::catalog::hash_file(&temporary)? != hash {
            let _ = fs::remove_file(&temporary);
            bail!("Przeniesiony plik ma inną sumę kontrolną.");
        }
        if destination.exists() {
            fs::remove_file(&temporary)?;
        } else {
            fs::rename(&temporary, &destination)?;
        }
        app.catalog.migrate_file(
            &destination,
            &decoded,
            &hash,
            header(&request, "X-Mytify-Liked").as_deref() == Some("true"),
        )
    })();
    app.busy.store(false, Ordering::Release);
    match result {
        Ok(report) => send_json(request, 200, serde_json::to_value(report)?),
        Err(error) => send_error(request, 400, error),
    }
}

/// Time since the last keyboard or mouse input anywhere in the session (screensaver).
fn system_idle_ms() -> Option<u64> {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::SystemInformation::GetTickCount;
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
        let mut info = LASTINPUTINFO {
            cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        if GetLastInputInfo(&mut info) != 0 {
            return Some(GetTickCount().wrapping_sub(info.dwTime) as u64);
        }
    }
    None
}
