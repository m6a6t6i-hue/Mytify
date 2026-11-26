use crate::catalog::{getrandom_bytes, hex, Catalog};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    io::{Read, Seek, SeekFrom},
    net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};
#[derive(Clone, Default, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub kind: String,
    #[serde(default)]
    pub control: String,
    #[serde(default)]
    pub rendering: String,
    #[serde(default)]
    pub service: String,
    #[serde(default)]
    pub auth: i32,
    #[serde(default)]
    pub ap2: bool,
}
impl Target {
    pub fn key(&self) -> String {
        hex(Sha256::digest(self.id.as_bytes()))
    }
}
static TARGETS: OnceLock<Mutex<HashMap<String, Target>>> = OnceLock::new();
static AIR_STATUS: OnceLock<Mutex<(i32, String, VecDeque<(i32, String)>)>> = OnceLock::new();
fn registry() -> &'static Mutex<HashMap<String, Target>> {
    TARGETS.get_or_init(Default::default)
}
fn air() -> &'static Mutex<(i32, String, VecDeque<(i32, String)>)> {
    AIR_STATUS.get_or_init(Default::default)
}
pub fn airplay_commands() -> Vec<(i32, String)> {
    air().lock().unwrap().2.drain(..).collect()
}
pub fn airplay_status(s: i32, e: String) {
    let mut a = air().lock().unwrap();
    a.0 = s;
    a.1 = e;
}
pub fn queue_air(kind: i32, text: String) {
    let mut a = air().lock().unwrap();
    if a.2.len() < 32 {
        a.2.push_back((kind, text));
    }
}
pub fn target(id: &str) -> Option<Target> {
    registry().lock().unwrap().get(id).cloned()
}
pub fn credential_root() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Mytify")
        .join("network-private")
}
pub fn write_credentials(root: &Path, key: &str, s: &str) -> Result<()> {
    std::fs::create_dir_all(root)?;
    let tmp = root.join(format!("{key}.partial"));
    std::fs::write(&tmp, s)?;
    let dest = root.join(format!("{key}.json"));
    if dest.exists() {
        std::fs::remove_file(&dest)?;
    }
    std::fs::rename(tmp, dest)?;
    Ok(())
}
pub fn sender_identity(root: &Path) -> String {
    let _ = std::fs::create_dir_all(root);
    let path = root.join("identity");
    if let Ok(s) = std::fs::read_to_string(&path) {
        if s.len() == 17 {
            return s;
        }
    }
    let mut bytes = getrandom_bytes().unwrap_or([1u8; 16]);
    bytes[0] = (bytes[0] | 2) & 254;
    let s = bytes[..6]
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":");
    let _ = std::fs::write(path, &s);
    s
}
fn lan(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => v.is_private() || v.is_link_local(),
        _ => false,
    }
}
fn client() -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}
fn local_url(s: &str, expected: Option<&str>) -> Result<url::Url> {
    let u = url::Url::parse(s)?;
    let h = u.host_str().ok_or_else(|| anyhow!("Brak adresu"))?;
    let ip: IpAddr = h.parse()?;
    if u.scheme() != "http"
        || !lan(ip)
        || expected.is_some_and(|e| e != h)
        || !u.username().is_empty()
        || u.password().is_some()
    {
        bail!("Nieprawidłowy adres odbiornika w sieci lokalnej")
    };
    Ok(u)
}
fn read_response(r: reqwest::blocking::Response) -> Result<String> {
    let r = r.error_for_status()?;
    let mut b = Vec::new();
    r.take(1024 * 1024 + 1).read_to_end(&mut b)?;
    if b.len() > 1024 * 1024 {
        bail!("Zbyt duża odpowiedź urządzenia")
    };
    Ok(String::from_utf8(b)?)
}
fn xml(s: &str, key: &str) -> Option<String> {
    let d = roxmltree::Document::parse(s).ok()?;
    d.descendants()
        .find(|n| n.has_tag_name(key))
        .and_then(|n| n.text())
        .map(str::to_owned)
}
pub fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn describe(location: &str) -> Result<Target> {
    let base = local_url(location, None)?;
    let text = read_response(client()?.get(base.clone()).send()?)?;
    let doc = roxmltree::Document::parse(&text)?;
    let service_base = xml(&text, "URLBase")
        .filter(|s| !s.is_empty())
        .map(|s| local_url(&s, base.host_str()))
        .transpose()?
        .unwrap_or_else(|| base.clone());
    let mut control = String::new();
    let mut rendering = String::new();
    let mut service = String::new();
    for n in doc.descendants().filter(|n| n.has_tag_name("service")) {
        let get = |k| {
            n.children()
                .find(|c| c.has_tag_name(k))
                .and_then(|c| c.text())
                .unwrap_or("")
        };
        let st = get("serviceType");
        let cu = service_base.join(get("controlURL"))?;
        local_url(cu.as_str(), base.host_str())?;
        if st.starts_with("urn:schemas-upnp-org:service:AVTransport:") {
            control = cu.to_string();
            service = st.into()
        }
        if st.starts_with("urn:schemas-upnp-org:service:RenderingControl:") {
            rendering = cu.to_string();
        }
    }
    if control.is_empty() {
        bail!("Urządzenie nie udostępnia sterowania DLNA")
    }
    Ok(Target {
        id: format!(
            "dlna:{}",
            xml(&text, "UDN").unwrap_or_else(|| base.to_string())
        ),
        name: format!(
            "{} · {}",
            xml(&text, "friendlyName").unwrap_or_else(|| "Odbiornik".into()),
            if xml(&text, "manufacturer")
                .unwrap_or_default()
                .to_lowercase()
                .contains("yamaha")
            {
                "Yamaha / MusicCast (DLNA)"
            } else {
                "DLNA"
            }
        ),
        host: base.host_str().unwrap().into(),
        port: base.port_or_known_default().unwrap(),
        kind: "dlna".into(),
        control,
        rendering,
        service,
        ..Default::default()
    })
}
pub fn discover() -> Vec<Target> {
    let (tx, rx) = std::sync::mpsc::channel();
    let a = tx.clone();
    std::thread::spawn(move || {
        if let Ok(s) = UdpSocket::bind("0.0.0.0:0") {
            let _ = s.set_read_timeout(Some(Duration::from_millis(200)));
            let msg="M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
            let _ = s.send_to(msg.as_bytes(), "239.255.255.250:1900");
            let end = Instant::now() + Duration::from_secs(2);
            let mut seen = HashSet::new();
            let mut b = [0u8; 8192];
            while Instant::now() < end {
                if let Ok((n, peer)) = s.recv_from(&mut b) {
                    if !lan(peer.ip()) {
                        continue;
                    }
                    let text = String::from_utf8_lossy(&b[..n]);
                    if let Some(loc) = text.lines().find_map(|l| {
                        l.split_once(':')
                            .filter(|(k, _)| k.eq_ignore_ascii_case("location"))
                            .map(|(_, v)| v.trim().to_owned())
                    }) {
                        if seen.len() < 32 && seen.insert(loc.clone()) {
                            let t = a.clone();
                            std::thread::spawn(move || {
                                if let Ok(v) = describe(&loc) {
                                    let _ = t.send(v);
                                }
                            });
                        }
                    }
                }
            }
        }
    });
    std::thread::spawn(move || {
        if let Ok(d) = mdns_sd::ServiceDaemon::new() {
            for ty in ["_raop._tcp.local.", "_airplay._tcp.local."] {
                if let Ok(r) = d.browse(ty) {
                    let tx = tx.clone();
                    std::thread::spawn(move || {
                        let end = Instant::now() + Duration::from_secs(3);
                        while Instant::now() < end {
                            if let Ok(mdns_sd::ServiceEvent::ServiceResolved(s)) =
                                r.recv_timeout(Duration::from_millis(100))
                            {
                                let Some(ip) = s.addresses.iter().find_map(|a| {
                                    a.to_ip_addr()
                                        .to_string()
                                        .parse::<IpAddr>()
                                        .ok()
                                        .filter(|i| lan(*i))
                                }) else {
                                    continue;
                                };
                                let prop =
                                    |k| s.txt_properties.get_property_val_str(k).unwrap_or("");
                                let model = prop("am");
                                let ap2 = ty.starts_with("_airplay") || prop("pk").len() > 8;
                                let auth = if prop("pw") == "true" {
                                    1
                                } else if ap2 {
                                    if model.starts_with("AppleTV") {
                                        5
                                    } else {
                                        4
                                    }
                                } else if model.starts_with("AirPort") {
                                    2
                                } else {
                                    0
                                };
                                let instance = s.fullname.split("._").next().unwrap_or("");
                                let id = airplay_device_id(instance, prop("deviceid"))
                                    .unwrap_or_else(|| s.fullname.clone());
                                let _ = tx.send(Target {
                                    id: format!("airplay:{id}"),
                                    // Which mDNS record it came from: one receiver shows up as
                                    // both, streaming uses the RAOP one.
                                    service: if ty.starts_with("_raop") { "raop" } else { "airplay" }.into(),
                                    name: format!(
                                        "{} · AirPlay{}",
                                        s.fullname
                                            .split("._")
                                            .next()
                                            .unwrap_or("AirPlay")
                                            .split('@')
                                            .next_back()
                                            .unwrap_or("AirPlay"),
                                        if ap2 { " 2" } else { "" }
                                    ),
                                    host: ip.to_string(),
                                    port: s.port,
                                    kind: "airplay".into(),
                                    auth,
                                    ap2,
                                    ..Default::default()
                                });
                            }
                        }
                    });
                }
            }
            std::thread::sleep(Duration::from_secs(3));
            let _ = d.shutdown();
        }
    });
    let until = Instant::now() + Duration::from_secs(4);
    let mut found: HashMap<String, Target> = HashMap::new();
    while Instant::now() < until {
        if let Ok(t) = rx.recv_timeout(Duration::from_millis(100)) {
            let keep = matches!(found.get(&t.id), Some(old) if old.kind == "airplay" && old.service == "raop" && t.service != "raop");
            if !keep {
                found.insert(t.id.clone(), t);
            }
        }
    }
    let mut reg = registry().lock().unwrap();
    *reg = found;
    let mut out = reg.values().cloned().collect::<Vec<_>>();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}
/// One id per AirPlay receiver: "deviceid" from _airplay, or the MAC before '@' in the
/// _raop instance name ("A0B1C2D3E4F5@Salon"), both as "A0:B1:C2:D3:E4:F5".
pub fn airplay_device_id(instance: &str, deviceid: &str) -> Option<String> {
    let raw = if deviceid.is_empty() {
        instance.split_once('@')?.0.to_owned()
    } else {
        deviceid.to_owned()
    };
    let hex: String = raw.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 12 {
        return (!deviceid.is_empty()).then(|| deviceid.to_uppercase());
    }
    let hex = hex.to_uppercase();
    Some((0..6).map(|i| &hex[i * 2..i * 2 + 2]).collect::<Vec<_>>().join(":"))
}

pub fn soap(t: &Target, action: &str, args: &[(&str, String)], render: bool) -> Result<String> {
    let st = if render {
        "urn:schemas-upnp-org:service:RenderingControl:1"
    } else {
        &t.service
    };
    let endpoint = if render { &t.rendering } else { &t.control };
    if endpoint.is_empty() {
        bail!("Odbiornik nie udostępnia tej funkcji")
    };
    local_url(endpoint, Some(&t.host))?;
    let body=format!("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{action} xmlns:u=\"{st}\"><InstanceID>0</InstanceID>{}</u:{action}></s:Body></s:Envelope>",args.iter().map(|(k,v)|format!("<{k}>{}</{k}>",escape(v))).collect::<String>());
    read_response(
        client()?
            .post(endpoint)
            .header("Content-Type", "text/xml; charset=\"utf-8\"")
            .header("SOAPACTION", format!("\"{st}#{action}\""))
            .body(body)
            .send()?,
    )
    .map_err(|e| {
        anyhow!("Odbiornik nie wykonał {action}: {e}. Sprawdź DMC Control i zgodność formatu.")
    })
}
#[derive(Default)]
struct Remote {
    target: Option<Target>,
    ids: Vec<String>,
    index: usize,
    position: u64,
    duration: u64,
    playing: bool,
    repeat: bool,
    shuffled: bool,
    volume: f64,
    volume_known: bool,
    seen_playing: bool,
    error: Option<String>,
    serial: u64,
    revision: u64,
    token: String,
    allowed: HashSet<String>,
    /// A station sent to the receiver: {id, url, name, logo}.
    radio: Option<Value>,
}
type Control = Arc<dyn Fn(&Target, &str, &[(&str, String)], bool) -> Result<String> + Send + Sync>;
pub struct Network {
    control: Control,
    data: Arc<Mutex<Remote>>,
    io: Arc<Mutex<()>>,
    catalog: Arc<Catalog>,
    port: Arc<std::sync::atomic::AtomicU16>,
}
impl Network {
    fn soap(&self, t: &Target, a: &str, v: &[(&str, String)], r: bool) -> Result<String> {
        (self.control)(t, a, v, r)
    }
    pub fn new(catalog: Arc<Catalog>) -> Result<Self> {
        Self::with_control(catalog, Arc::new(soap))
    }
    fn with_control(catalog: Arc<Catalog>, control: Control) -> Result<Self> {
        let data = Arc::new(Mutex::new(Remote::default()));
        let port = Arc::new(std::sync::atomic::AtomicU16::new(0));
        let s = Self {
            control,
            data,
            io: Arc::new(Mutex::new(())),
            catalog,
            port,
        };
        let clone = s.clone_handle();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(800));
            let _ = clone.poll();
        });
        Ok(s)
    }
    fn clone_handle(&self) -> Self {
        Self {
            control: self.control.clone(),
            data: self.data.clone(),
            io: self.io.clone(),
            catalog: self.catalog.clone(),
            port: self.port.clone(),
        }
    }
    // Open the LAN file endpoint only after the user selects a DLNA receiver.
    fn ensure_server(&self) -> Result<()> {
        use std::sync::atomic::Ordering;
        if self.port.load(Ordering::Acquire) != 0 {
            return Ok(());
        }
        let server = Arc::new(
            tiny_http::Server::http(("0.0.0.0", 0))
                .map_err(|e| anyhow!("Serwer odbiornika: {e}"))?,
        );
        self.port.store(
            server.server_addr().to_ip().unwrap().port(),
            Ordering::Release,
        );
        let data = self.data.clone();
        let catalog = self.catalog.clone();
        std::thread::spawn(move || {
            let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            for r in server.incoming_requests() {
                if active.fetch_add(1, Ordering::AcqRel) >= 8 {
                    active.fetch_sub(1, Ordering::AcqRel);
                    let _ = r.respond(tiny_http::Response::empty(503));
                    continue;
                }
                let data = data.clone();
                let catalog = catalog.clone();
                let active = active.clone();
                std::thread::spawn(move || {
                    let _ = stream(r, &data, &catalog);
                    active.fetch_sub(1, Ordering::AcqRel);
                });
            }
        });
        Ok(())
    }
    pub fn active(&self) -> bool {
        self.data.lock().unwrap().target.is_some()
    }
    pub fn state(&self, local: Value) -> Value {
        let d = self.data.lock().unwrap();
        if let Some(t) = &d.target {
            let radio = d.radio.as_ref().map(|r| json!({"id":r["id"],"name":r["name"],"url":r["url"],"logo":r["logo"],"title":null,"station":null,"codec":"","bitrate":0,"reconnecting":false}));
            let mut v = json!({"available":true,"playing":d.playing,"completed":false,"buffering":false,"queueIds":d.ids,"currentId":d.ids.get(d.index),"index":d.index,"positionMs":d.position,"durationMs":d.duration,"volume":d.volume,"volumeAvailable":d.volume_known,"repeat":d.repeat,"shuffled":d.shuffled,"selectedDevice":t.id,"source":null,"output":{"name":t.name,"backend":"DLNA · oryginalny plik","sampleRate":0,"sampleFormat":"Format pliku","channels":2,"testSink":false},"error":d.error,"errorSerial":d.serial,"revision":d.revision,"underrunFrames":0,"renderedFrames":0});
            v["radio"] = radio.unwrap_or(Value::Null);
            v
        } else {
            let mut v = local;
            if v["selectedDevice"]
                .as_str()
                .is_some_and(|s| s.starts_with("airplay:"))
            {
                let a = air().lock().unwrap();
                v["pairingRequired"] = json!(a.0 == 2);
                v["buffering"] = json!(a.0 == 0);
                if a.0 == 3 {
                    v["error"] = json!(a.1);
                }
            }
            v
        }
    }
    pub fn deselect(&self) {
        let _g = self.io.lock().unwrap();
        let target = self.data.lock().unwrap().target.take();
        if let Some(t) = target {
            let _ = self.soap(&t, "Stop", &[], false);
        }
        let mut d = self.data.lock().unwrap();
        d.allowed.clear();
        d.token.clear();
        d.playing = false;
    }
    pub fn select(&self, t: Target, local: &Value) -> Result<()> {
        let _g = self.io.lock().unwrap();
        self.ensure_server()?;
        let vol = self
            .soap(&t, "GetVolume", &[("Channel", "Master".into())], true)
            .ok()
            .and_then(|s| xml(&s, "CurrentVolume"))
            .and_then(|s| {
                s.parse::<f64>()
                    .ok()
                    .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
            });
        let mut d = self.data.lock().unwrap();
        *d = Remote {
            target: Some(t),
            ids: serde_json::from_value(local["queueIds"].clone())?,
            index: local["index"].as_u64().unwrap_or(0) as usize,
            position: local["positionMs"].as_u64().unwrap_or(0),
            volume: vol.unwrap_or(0.),
            volume_known: vol.is_some(),
            token: hex(getrandom_bytes()?),
            ..Default::default()
        };
        let has_queue = !d.ids.is_empty();
        if local["radio"].is_object() {
            d.radio = Some(local["radio"].clone());
        }
        drop(d);
        if has_queue {
            self.load_current(
                local["playing"] == true,
                local["positionMs"].as_u64().unwrap_or(0),
            )?;
        }
        Ok(())
    }
    /// The receiver fetches the station itself; playlists are opened here first.
    fn load_radio(&self, play: bool) -> Result<()> {
        let (t, r) = {
            let d = self.data.lock().unwrap();
            (
                d.target.clone().ok_or_else(|| anyhow!("Brak odbiornika"))?,
                d.radio.clone().ok_or_else(|| anyhow!("Brak stacji"))?,
            )
        };
        let url = crate::radio::resolve_playlist(r["url"].as_str().unwrap_or(""))?;
        let name = r["name"].as_str().unwrap_or("");
        let didl = format!("<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"radio\" parentID=\"0\" restricted=\"1\"><dc:title>{}</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class><res protocolInfo=\"http-get:*:*:*\">{}</res></item></DIDL-Lite>", escape(name), escape(&url));
        {
            let mut d = self.data.lock().unwrap();
            d.allowed.clear();
            d.seen_playing = false;
            d.duration = 0;
            d.position = 0;
        }
        self.soap(&t, "SetAVTransportURI", &[("CurrentURI", url), ("CurrentURIMetaData", didl)], false)?;
        if play {
            self.soap(&t, "Play", &[("Speed", "1".into())], false)?;
        }
        Ok(())
    }
    fn load_current(&self, play: bool, pos: u64) -> Result<()> {
        if self.data.lock().unwrap().radio.is_some() {
            return self.load_radio(play);
        }
        let (t, id, token) = {
            let d = self.data.lock().unwrap();
            (
                d.target.clone().ok_or_else(|| anyhow!("Brak odbiornika"))?,
                d.ids
                    .get(d.index)
                    .cloned()
                    .ok_or_else(|| anyhow!("Pusta kolejka"))?,
                d.token.clone(),
            )
        };
        self.catalog.check_playable(&id)?;
        let path = PathBuf::from(
            self.catalog
                .tracks()?
                .into_iter()
                .find(|v| v.id == id)
                .map(|t| t.file_name)
                .unwrap_or_default(),
        );
        let track = self
            .catalog
            .tracks()?
            .into_iter()
            .find(|v| v.id == id)
            .ok_or_else(|| anyhow!("Brak utworu"))?;
        let ip: IpAddr = t.host.parse()?;
        let route = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
        route.connect(SocketAddr::new(ip, t.port))?;
        let host = route.local_addr()?.ip();
        let uri = format!(
            "http://{host}:{}/{token}/{id}",
            self.port.load(std::sync::atomic::Ordering::Acquire)
        );
        let mime = mime(&path);
        let didl=format!("<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"{id}\" parentID=\"0\" restricted=\"1\"><dc:title>{}</dc:title><upnp:artist>{}</upnp:artist><upnp:album>{}</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo=\"http-get:*:{mime}:*\">{}</res></item></DIDL-Lite>",escape(&track.title),escape(&track.artist),escape(&track.album),escape(&uri));
        {
            let mut d = self.data.lock().unwrap();
            d.allowed = HashSet::from([id]);
            d.seen_playing = false;
            d.duration = track.duration_ms.max(0) as u64;
        }
        self.soap(
            &t,
            "SetAVTransportURI",
            &[("CurrentURI", uri), ("CurrentURIMetaData", didl)],
            false,
        )?;
        if play {
            self.soap(&t, "Play", &[("Speed", "1".into())], false)?;
        }
        if pos > 0 {
            self.soap(
                &t,
                "Seek",
                &[("Unit", "REL_TIME".into()), ("Target", clock(pos))],
                false,
            )?;
        }
        self.data.lock().unwrap().position = pos;
        Ok(())
    }
    pub fn command(&self, v: &Value) -> Result<()> {
        let _g = self.io.lock().unwrap();
        let t = self
            .data
            .lock()
            .unwrap()
            .target
            .clone()
            .ok_or_else(|| anyhow!("Brak odbiornika"))?;
        let result = (|| {
            let action = v["action"].as_str().unwrap_or("");
            if self.data.lock().unwrap().radio.is_some() && matches!(action, "seek" | "next" | "previous" | "jump" | "shuffle") {
                return Ok(());
            }
            match action {
                "radio" => {
                    let text = |k: &str| v[k].as_str().unwrap_or("").to_string();
                    let (id, url) = (text("id"), text("url"));
                    if !id.starts_with("radio:") || !(url.starts_with("http://") || url.starts_with("https://")) {
                        bail!("Nieprawidłowa stacja")
                    }
                    let mut d = self.data.lock().unwrap();
                    d.radio = Some(json!({"id":id,"url":url,"name":text("name"),"logo":text("logo")}));
                    d.ids = vec![id];
                    d.index = 0;
                    drop(d);
                    self.load_radio(true)?;
                }
                "load" => {
                    let ids: Vec<String> = serde_json::from_value(v["ids"].clone())?;
                    let i = v["index"].as_u64().unwrap_or(0) as usize;
                    if ids.is_empty() || ids.len() > 10000 || i >= ids.len() {
                        bail!("Nieprawidłowa kolejka")
                    };
                    for id in &ids {
                        self.catalog.check_playable(id)?;
                    }
                    let mut d = self.data.lock().unwrap();
                    d.ids = ids;
                    d.index = i;
                    d.radio = None;
                    drop(d);
                    self.load_current(true, 0)?;
                }
                "play" => {
                    if self.data.lock().unwrap().allowed.is_empty() {
                        let pos = self.data.lock().unwrap().position;
                        self.load_current(true, pos)?;
                    } else {
                        self.soap(&t, "Play", &[("Speed", "1".into())], false)?;
                    }
                }
                "pause" => {
                    self.soap(&t, "Pause", &[], false)?;
                }
                "stop" => {
                    self.soap(&t, "Stop", &[], false)?;
                    let mut d = self.data.lock().unwrap();
                    d.ids.clear();
                    d.radio = None;
                    d.allowed.clear();
                    d.playing = false;
                }
                "seek" => {
                    let pos = v["positionMs"]
                        .as_u64()
                        .ok_or_else(|| anyhow!("Błędna pozycja"))?;
                    self.soap(
                        &t,
                        "Seek",
                        &[("Unit", "REL_TIME".into()), ("Target", clock(pos))],
                        false,
                    )?;
                }
                "next" | "previous" | "jump" => {
                    let mut d = self.data.lock().unwrap();
                    let action = v["action"].as_str().unwrap();
                    if d.ids.is_empty() {
                        return Ok(());
                    }
                    let i = if action == "jump" {
                        d.ids
                            .iter()
                            .position(|x| Some(x.as_str()) == v["id"].as_str())
                            .ok_or_else(|| anyhow!("Brak utworu w kolejce"))?
                    } else if action == "previous" {
                        if d.position > 3000 {
                            d.index
                        } else {
                            d.index.saturating_sub(1)
                        }
                    } else if d.index + 1 < d.ids.len() {
                        d.index + 1
                    } else if d.repeat {
                        0
                    } else {
                        drop(d);
                        self.soap(&t, "Stop", &[], false)?;
                        return Ok(());
                    };
                    d.index = i;
                    drop(d);
                    self.load_current(true, 0)?;
                }
                "volume" => {
                    let value = v["value"]
                        .as_f64()
                        .filter(|x| x.is_finite() && (0.0..=100.0).contains(x))
                        .ok_or_else(|| anyhow!("Błędna głośność"))?;
                    self.soap(
                        &t,
                        "SetVolume",
                        &[
                            ("Channel", "Master".into()),
                            ("DesiredVolume", format!("{value:.0}")),
                        ],
                        true,
                    )?;
                    self.data.lock().unwrap().volume = value;
                }
                "repeat" => self.data.lock().unwrap().repeat = v["value"] == true,
                "shuffle" => {
                    if v["value"] == true {
                        bail!("Losowanie kolejki DLNA nie jest jeszcze obsługiwane")
                    }
                    self.data.lock().unwrap().shuffled = false;
                }
                "receiverPower" => {
                    let url = format!(
                        "http://{}/YamahaExtendedControl/v1/main/setPower?power=on",
                        t.host
                    );
                    read_response(client()?.get(url).send()?)?;
                }
                _ => bail!("Nieobsługiwane polecenie odbiornika"),
            };
            Ok(())
        })();
        let mut d = self.data.lock().unwrap();
        d.revision += 1;
        if let Err(e) = &result {
            d.error = Some(e.to_string());
            d.serial += 1
        } else {
            d.error = None
        }
        result
    }
    fn poll(&self) -> Result<()> {
        if !self.active() {
            return Ok(());
        }
        let _g = self.io.lock().unwrap();
        let t = self.data.lock().unwrap().target.clone().unwrap();
        let result = (|| {
            let transport = self.soap(&t, "GetTransportInfo", &[], false)?;
            let pos = self.soap(&t, "GetPositionInfo", &[], false)?;
            let volume = self
                .soap(&t, "GetVolume", &[("Channel", "Master".into())], true)
                .ok()
                .and_then(|s| xml(&s, "CurrentVolume"))
                .and_then(|s| {
                    s.parse::<f64>()
                        .ok()
                        .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
                });
            Ok::<_, anyhow::Error>((
                xml(&transport, "CurrentTransportState").unwrap_or_default(),
                parse_clock(&xml(&pos, "RelTime").unwrap_or_default()),
                volume,
            ))
        })();
        match result {
            Ok((state, pos, volume)) => {
                {
                    let mut d = self.data.lock().unwrap();
                    d.volume_known = volume.is_some();
                    if let Some(v) = volume {
                        d.volume = v;
                    }
                }
                let mut d = self.data.lock().unwrap();
                let previous = d.position;
                d.position = pos;
                d.playing = state == "PLAYING";
                let advance = state == "STOPPED"
                    && d.seen_playing
                    && d.duration > 0
                    && pos.max(previous) >= d.duration.saturating_sub(2000);
                d.seen_playing |= d.playing;
                if advance {
                    d.seen_playing = false;
                    if d.index + 1 < d.ids.len() {
                        d.index += 1;
                        drop(d);
                        self.load_current(true, 0)?;
                    } else if d.repeat && !d.ids.is_empty() {
                        d.index = 0;
                        drop(d);
                        self.load_current(true, 0)?;
                    }
                }
            }
            Err(e) => {
                let mut d = self.data.lock().unwrap();
                if d.error.is_none() {
                    d.serial += 1
                }
                d.error = Some(format!("Utracono łączność z odbiornikiem: {e}"));
                d.playing = false;
                d.volume_known = false;
            }
        }
        Ok(())
    }
}
fn clock(ms: u64) -> String {
    let s = ms / 1000;
    format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
}
fn parse_clock(s: &str) -> u64 {
    let p = s
        .split(':')
        .filter_map(|s| s.parse::<f64>().ok())
        .collect::<Vec<_>>();
    if p.len() != 3 {
        return 0;
    }
    ((p[0] * 3600. + p[1] * 60. + p[2]) * 1000.).max(0.) as u64
}
fn mime(p: &Path) -> &'static str {
    match p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "m4a" | "mp4" => "audio/mp4",
        "aac" => "audio/aac",
        "aif" | "aiff" => "audio/aiff",
        "ogg" | "opus" => "audio/ogg",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    }
}
pub fn range(value: &str, len: u64) -> Result<(u64, u64)> {
    let s = value
        .strip_prefix("bytes=")
        .ok_or_else(|| anyhow!("Zakres"))?;
    if len == 0 || s.contains(',') {
        bail!("Zakres")
    };
    let (a, b) = s.split_once('-').ok_or_else(|| anyhow!("Zakres"))?;
    let (start, end) = if a.is_empty() {
        let n = b.parse::<u64>()?;
        if n == 0 {
            bail!("Zakres")
        };
        (len.saturating_sub(n), len - 1)
    } else {
        (
            a.parse()?,
            if b.is_empty() {
                len - 1
            } else {
                b.parse::<u64>()?.min(len - 1)
            },
        )
    };
    if start > end || start >= len {
        bail!("Zakres")
    };
    Ok((start, end))
}
fn stream(r: tiny_http::Request, data: &Mutex<Remote>, catalog: &Catalog) -> Result<()> {
    let auth = {
        let d = data.lock().unwrap();
        let parts = r.url().split('/').collect::<Vec<_>>();
        parts.len() == 3
            && parts[1] == d.token
            && d.allowed.contains(parts[2])
            && r.remote_addr().is_some_and(|a| {
                d.target
                    .as_ref()
                    .is_some_and(|t| t.host == a.ip().to_string())
            })
    };
    if !auth || !matches!(r.method(), tiny_http::Method::Get | tiny_http::Method::Head) {
        r.respond(tiny_http::Response::empty(403))?;
        return Ok(());
    }
    let id = r.url().rsplit('/').next().unwrap();
    let input = catalog.open_audio(id)?;
    let path = PathBuf::from(&input.name);
    let len = input.len;
    let mut f = input.reader;
    let header = r
        .headers()
        .iter()
        .find(|h| h.field.equiv("Range"))
        .map(|h| h.value.as_str());
    let (start, end, code) = if let Some(h) = header {
        match range(h, len) {
            Ok((a, b)) => (a, b, 206),
            Err(_) => {
                r.respond(tiny_http::Response::empty(416))?;
                return Ok(());
            }
        }
    } else {
        (0, len.saturating_sub(1), 200)
    };
    f.seek(SeekFrom::Start(start))?;
    let count = if len == 0 { 0 } else { end - start + 1 };
    let mut headers = vec![
        tiny_http::Header::from_bytes("Content-Type", mime(&path)).unwrap(),
        tiny_http::Header::from_bytes("Accept-Ranges", "bytes").unwrap(),
        tiny_http::Header::from_bytes("transferMode.dlna.org", "Streaming").unwrap(),
    ];
    if code == 206 {
        headers.push(
            tiny_http::Header::from_bytes("Content-Range", format!("bytes {start}-{end}/{len}"))
                .unwrap(),
        )
    };
    r.respond(tiny_http::Response::new(
        tiny_http::StatusCode(code),
        headers,
        f.take(count),
        Some(count as usize),
        None,
    ))?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranges() {
        assert_eq!(range("bytes=5-99", 10).unwrap(), (5, 9));
        assert_eq!(range("bytes=-3", 10).unwrap(), (7, 9));
        assert!(range("bytes=10-", 10).is_err());
        assert!(range("bytes=0-1,4-5", 10).is_err());
    }
    #[test]
    fn xml_and_urls() {
        assert_eq!(escape("a<&\""), "a&lt;&amp;&quot;");
        assert!(local_url("http://8.8.8.8/device", None).is_err());
        assert!(local_url("http://127.0.0.1/device", None).is_err());
        assert!(local_url("http://192.168.1.2/device", Some("192.168.1.3")).is_err());
        assert_eq!(parse_clock("01:02:03"), 3723000);
    }
}
#[cfg(test)]
mod receiver_integration {
    use super::*;
    #[test]
    fn stations_go_to_the_receiver_as_they_are() {
        let sent = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
        let control: Control = {
            let sent = sent.clone();
            Arc::new(move |_, action, args, _| {
                let uri = args.iter().find(|(k, _)| *k == "CurrentURI").map(|a| a.1.clone()).unwrap_or_default();
                sent.lock().unwrap().push((action.to_owned(), uri));
                Ok(String::new())
            })
        };
        let temp = tempfile::tempdir().unwrap();
        let catalog = Arc::new(Catalog::open(temp.path().join("catalog")).unwrap());
        let network = Network::with_control(catalog, control).unwrap();
        let t = Target { id: "dlna:fake".into(), name: "R".into(), host: "127.0.0.1".into(), port: 7000, kind: "dlna".into(), ..Default::default() };
        let radio = json!({"id":"radio:abc","url":"https://s.example/live.aac","name":"Jazz & Co","logo":""});
        network
            .select(t, &json!({"queueIds":["radio:abc"],"index":0,"positionMs":0,"playing":true,"radio":radio}))
            .unwrap();
        assert!(sent.lock().unwrap().contains(&("SetAVTransportURI".into(), "https://s.example/live.aac".into())));
        assert!(sent.lock().unwrap().iter().any(|a| a.0 == "Play"));
        let state = network.state(json!({}));
        assert_eq!(state["radio"]["id"], "radio:abc");
        assert_eq!(state["durationMs"], 0);
        sent.lock().unwrap().clear();
        network.command(&json!({"action":"seek","positionMs":5000})).unwrap();
        network.command(&json!({"action":"next"})).unwrap();
        assert!(sent.lock().unwrap().is_empty());
        network.command(&json!({"action":"radio","id":"radio:def","url":"http://other.example/mp3","name":"B"})).unwrap();
        assert!(sent.lock().unwrap().contains(&("SetAVTransportURI".into(), "http://other.example/mp3".into())));
        assert!(network.command(&json!({"action":"radio","id":"x","url":"http://a"})).is_err());
        network.command(&json!({"action":"stop"})).unwrap();
        assert!(network.state(json!({}))["radio"].is_null());
    }
    #[test]
    fn receiver_selection_preserves_volume_and_streams_exact_range() {
        let actions = Arc::new(Mutex::new(Vec::new()));
        let received = Arc::new(Mutex::new(String::new()));
        let control: Control = {
            let actions = actions.clone();
            let received = received.clone();
            Arc::new(move |_, action, args, _| {
                actions.lock().unwrap().push(action.to_owned());
                if action == "SetAVTransportURI" {
                    *received.lock().unwrap() = args
                        .iter()
                        .find(|(k, _)| *k == "CurrentURI")
                        .unwrap()
                        .1
                        .clone();
                }
                Ok(match action {
                    "GetVolume" => "<CurrentVolume>33</CurrentVolume>",
                    "GetTransportInfo" => {
                        "<CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>"
                    }
                    "GetPositionInfo" => "<RelTime>0:00:07</RelTime>",
                    _ => "",
                }
                .to_owned())
            })
        };
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("track.wav");
        let mut wav = crate::ingest::wav::Wav::create(&path, 44100, 2, 16).unwrap();
        wav.write(&vec![0; 44100 * 4]).unwrap();
        wav.finish().unwrap();
        drop(wav);
        let catalog = Arc::new(Catalog::open(temp.path().join("catalog")).unwrap());
        catalog
            .scan(
                crate::catalog::ScanRequest {
                    paths: vec![path.to_string_lossy().into_owned()],
                    ..Default::default()
                },
                &std::sync::atomic::AtomicBool::new(false),
                |_| {},
            )
            .unwrap();
        let id = catalog.tracks().unwrap()[0].id.clone();
        let network = Network::with_control(catalog, control).unwrap();
        assert_eq!(network.port.load(std::sync::atomic::Ordering::Acquire), 0);
        let t = Target {
            id: "dlna:fake".into(),
            name: "Controlled receiver".into(),
            host: "127.0.0.1".into(),
            port: 7000,
            kind: "dlna".into(),
            ..Default::default()
        };
        network
            .select(
                t,
                &json!({"queueIds":[id],"index":0,"positionMs":0,"playing":true}),
            )
            .unwrap();
        network.poll().unwrap();
        let state = network.state(json!({}));
        assert_eq!(state["volume"], 33.0);
        assert_eq!(state["positionMs"], 7000);
        assert_eq!(state["playing"], false);
        assert!(!actions.lock().unwrap().iter().any(|a| a == "SetVolume"));
        let uri = received.lock().unwrap().clone();
        let response = client()
            .unwrap()
            .get(&uri)
            .header("Range", "bytes=4-12")
            .send()
            .unwrap();
        assert_eq!(response.status(), 206);
        assert_eq!(
            response.bytes().unwrap().as_ref(),
            &std::fs::read(&path).unwrap()[4..13]
        );
        let forbidden = uri.replace(&id, &"0".repeat(64));
        assert_eq!(
            client().unwrap().get(forbidden).send().unwrap().status(),
            403
        );
        network.deselect();
    }
}

#[cfg(test)]
mod airplay_id_tests {
    use super::airplay_device_id;
    #[test]
    fn raop_and_airplay_records_of_one_receiver_match() {
        let raop = airplay_device_id("00A0DEDA4A79@RX-V481 DA4A79", "");
        let air = airplay_device_id("RX-V481 DA4A79", "00:a0:de:da:4a:79");
        assert_eq!(raop.as_deref(), Some("00:A0:DE:DA:4A:79"));
        assert_eq!(raop, air);
        assert_eq!(airplay_device_id("Kuchnia", ""), None);
    }
}
