//! Opt-in LAN TLS transfer; the one-use QR carries the exact certificate pin.
use crate::catalog::{getrandom_bytes, hex, Catalog};
use anyhow::{anyhow, bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File},
    io::{BufRead, BufReader, Cursor, Read, Seek, SeekFrom, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn random() -> Result<String> {
    Ok(format!(
        "{}{}",
        hex(getrandom_bytes()?),
        hex(getrandom_bytes()?)
    ))
}
fn hash(b: &[u8]) -> String {
    hex(Sha256::digest(b))
}
fn equal(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0, |x, (a, b)| x | (a ^ b)) == 0
}
fn id(v: &str) -> bool {
    v.len() == 64
        && v.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
#[derive(Serialize, Deserialize, Clone)]
struct Peer {
    id: String,
    name: String,
    token_hash: String,
    created: u64,
}
#[derive(Serialize, Deserialize)]
struct Saved {
    cert: String,
    key: String,
    peers: Vec<Peer>,
    #[serde(default)]
    playlists: Vec<Value>,
}
struct Live {
    stop: Arc<AtomicBool>,
    port: u16,
    secret: String,
    expires: u64,
    host: String,
    qr: String,
}
pub struct Transfer {
    catalog: Arc<Catalog>,
    saved: Mutex<Saved>,
    live: Mutex<Option<Live>>,
    clients: AtomicUsize,
}
impl Transfer {
    pub fn new(catalog: Arc<Catalog>) -> Result<Arc<Self>> {
        let path = catalog.root.join("transfer-identity.json");
        let saved = if path.exists() {
            serde_json::from_slice(&fs::read(path)?)?
        } else {
            let key = rcgen::generate_simple_self_signed(vec!["mytify.local".into()])?;
            Saved {
                cert: B64.encode(key.cert.der()),
                key: B64.encode(key.signing_key.serialize_der()),
                peers: vec![],
                playlists: vec![],
            }
        };
        let out = Arc::new(Self {
            catalog,
            saved: Mutex::new(saved),
            live: Mutex::new(None),
            clients: AtomicUsize::new(0),
        });
        out.persist(&out.saved.lock().unwrap())?;
        Ok(out)
    }
    fn persist(&self, s: &Saved) -> Result<()> {
        let p = self.catalog.root.join("transfer-identity.json");
        let tmp = p.with_extension("tmp");
        // Windows: FlushFileBuffers wymaga uchwytu z prawem zapisu. sync_all na uchwycie
        // z File::open (tylko odczyt) zwraca ERROR_ACCESS_DENIED (os error 5).
        {
            let mut file = File::create(&tmp)
                .with_context(|| format!("Zapis tożsamości transferu: {}", tmp.display()))?;
            file.write_all(&serde_json::to_vec(s)?)?;
            file.sync_all()
                .with_context(|| format!("Synchronizacja tożsamości transferu: {}", tmp.display()))?;
        }
        fs::rename(&tmp, &p)
            .with_context(|| format!("Podmiana pliku tożsamości transferu: {}", p.display()))?;
        Ok(())
    }
    pub fn fingerprint(&self) -> String {
        hash(&B64.decode(&self.saved.lock().unwrap().cert).unwrap())
    }
    fn addresses() -> Vec<String> {
        let mut a: Vec<_> = if_addrs::get_if_addrs()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|a| match a.ip() {
                std::net::IpAddr::V4(v) if v.is_private() => Some(v.to_string()),
                _ => None,
            })
            .collect();
        a.sort();
        a.dedup();
        if cfg!(debug_assertions) && a.is_empty() {
            a.push("127.0.0.1".into());
        }
        a
    }
    fn link(&self, l: &Live) -> String {
        format!(
            "mytify://pair?v=1&host={}&port={}&fingerprint={}&secret={}",
            l.host,
            l.port,
            self.fingerprint(),
            l.secret
        )
    }
    fn qr(&self, l: &Live) -> Result<String> {
        let code = qrcode::QrCode::new(self.link(l))?;
        let img = code
            .render::<image::Luma<u8>>()
            .min_dimensions(480, 480)
            .build();
        let mut b = Cursor::new(Vec::new());
        image::DynamicImage::ImageLuma8(img).write_to(&mut b, image::ImageFormat::Png)?;
        Ok(B64.encode(b.into_inner()))
    }
    fn status(&self) -> Value {
        let live = self.live.lock().unwrap();
        let s = self.saved.lock().unwrap();
        json!({"enabled":live.is_some(),"addresses":Self::addresses(),"port":live.as_ref().map(|l|l.port),"pairUri":live.as_ref().filter(|l|now()<l.expires&&!l.secret.is_empty()).map(|l|format!("mytify://pair?v=1&host={}&port={}&fingerprint={}&secret={}",l.host,l.port,hash(&B64.decode(&s.cert).unwrap()),l.secret)),"qr":live.as_ref().filter(|l|now()<l.expires&&!l.secret.is_empty()).map(|l|&l.qr),"expires":live.as_ref().map(|l|l.expires),"peers":s.peers.iter().map(|p|json!({"id":p.id,"name":p.name,"created":p.created})).collect::<Vec<_>>()})
    }
    pub fn command(self: &Arc<Self>, v: Value) -> Result<Value> {
        match v["action"].as_str().unwrap_or("status") {
            "status" => {}
            "start" => {
                self.stop();
                let addresses = Self::addresses();
                let host = v["host"]
                    .as_str()
                    .map(str::to_owned)
                    .or_else(|| addresses.first().cloned())
                    .ok_or_else(|| {
                        anyhow!("Brak adresu sieci lokalnej. Połącz PC z Wi-Fi lub Ethernet.")
                    })?;
                ensure!(addresses.contains(&host), "Wybierz adres tego komputera");
                let port = v["port"].as_u64().unwrap_or(47479);
                ensure!(port <= 65535, "Nieprawidłowy port");
                let listener = TcpListener::bind(("0.0.0.0", port as u16))
                    .map_err(|e| anyhow!("Nie można otworzyć transferu: {e}"))?;
                listener.set_nonblocking(true)?;
                let port = listener.local_addr()?.port();
                let stop = Arc::new(AtomicBool::new(false));
                let mut live = Live {
                    stop: stop.clone(),
                    port,
                    secret: random()?,
                    expires: now() + 120,
                    host,
                    qr: String::new(),
                };
                live.qr = self.qr(&live)?;
                let saved = self.saved.lock().unwrap();
                let cert = rustls::pki_types::CertificateDer::from(B64.decode(&saved.cert)?);
                let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
                    rustls::pki_types::PrivatePkcs8KeyDer::from(B64.decode(&saved.key)?),
                );
                drop(saved);
                let config = Arc::new(
                    rustls::ServerConfig::builder_with_provider(Arc::new(
                        rustls::crypto::ring::default_provider(),
                    ))
                    .with_safe_default_protocol_versions()?
                    .with_no_client_auth()
                    .with_single_cert(vec![cert], key)?,
                );
                *self.live.lock().unwrap() = Some(live);
                let weak = Arc::downgrade(self);
                thread::spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        match listener.accept() {
                            Ok((socket, peer)) => {
                                let Some(hub) = weak.upgrade() else { break };
                                let allowed = match peer.ip() {
                                    std::net::IpAddr::V4(ip) => ip.is_private() || ip.is_loopback(),
                                    _ => false,
                                };
                                if !allowed {
                                    continue;
                                }
                                if hub.clients.fetch_add(1, Ordering::AcqRel) >= 4 {
                                    hub.clients.fetch_sub(1, Ordering::AcqRel);
                                    continue;
                                }
                                let config = config.clone();
                                let stop = stop.clone();
                                thread::spawn(move || {
                                    let _ = hub.serve(socket, config, &stop);
                                    hub.clients.fetch_sub(1, Ordering::AcqRel);
                                });
                            }
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                thread::sleep(Duration::from_millis(40))
                            }
                            Err(_) => break,
                        }
                    }
                });
            }
            "renew" => {
                let mut lock = self.live.lock().unwrap();
                let l = lock.as_mut().ok_or_else(|| anyhow!("Włącz transfer"))?;
                if let Some(h) = v["host"].as_str() {
                    ensure!(
                        Self::addresses().contains(&h.to_string()),
                        "Nieprawidłowy adres"
                    );
                    l.host = h.into()
                }
                l.secret = random()?;
                l.expires = now() + 120;
                l.qr = self.qr(l)?;
            }
            "stop" => self.stop(),
            "revoke" => {
                let mut s = self.saved.lock().unwrap();
                s.peers.retain(|p| Some(p.id.as_str()) != v["id"].as_str());
                self.persist(&s)?;
            }
            "playlistList" => return Ok(json!(self.saved.lock().unwrap().playlists)),
            "playlistSave" => {
                let name = v["name"].as_str().unwrap_or("").trim();
                ensure!(
                    !name.is_empty() && name.chars().count() <= 100,
                    "Nazwa playlisty: 1–100 znaków"
                );
                let ids: Vec<String> = serde_json::from_value(v["ids"].clone())?;
                ensure!(
                    ids.len() <= 10000
                        && ids.iter().all(|t| id(t))
                        && ids.iter().collect::<HashSet<_>>().len() == ids.len(),
                    "Nieprawidłowe utwory"
                );
                let available: HashSet<_> =
                    self.catalog.tracks()?.into_iter().map(|t| t.id).collect();
                ensure!(
                    ids.iter().all(|t| available.contains(t)),
                    "Utwór nie istnieje"
                );
                let mut s = self.saved.lock().unwrap();
                ensure!(s.playlists.len() < 1000, "Za dużo playlist");
                let key = if let Some(k) = v["id"].as_str() {
                    ensure!(
                        s.playlists.iter().any(|p| p["id"] == k),
                        "Playlista nie istnieje"
                    );
                    k.to_owned()
                } else {
                    random()?
                };
                s.playlists.retain(|p| p["id"] != key);
                s.playlists.push(json!({"id":key,"name":name,"ids":ids}));
                self.persist(&s)?;
                return Ok(json!({"id":key}));
            }
            "playlistDelete" => {
                let mut s = self.saved.lock().unwrap();
                s.playlists.retain(|p| p["id"] != v["id"]);
                self.persist(&s)?;
                return Ok(json!({"ok":true}));
            }
            _ => bail!("Nieznana operacja transferu"),
        };
        Ok(self.status())
    }
    pub fn stop(&self) {
        if let Some(l) = self.live.lock().unwrap().take() {
            l.stop.store(true, Ordering::Release)
        }
    }
    fn authorized(&self, token: &str) -> bool {
        let h = hash(token.as_bytes());
        self.saved
            .lock()
            .unwrap()
            .peers
            .iter()
            .any(|p| equal(&p.token_hash, &h))
    }
    fn manifest(&self) -> Result<Value> {
        let mut tracks = self.catalog.tracks()?;
        tracks.retain(|t| t.available);
        ensure!(
            tracks.len() <= 10000,
            "Maks. 10000 utworów w udostępnionej bibliotece"
        );
        let items: Vec<_> = tracks
            .into_iter()
            .map(|mut t| {
                t.title = t.title.chars().take(512).collect();
                t.artist = t.artist.chars().take(512).collect();
                t.album = t.album.chars().take(512).collect();
                t.album_artist = t.album_artist.chars().take(512).collect();
                t.file_name = std::path::PathBuf::from(&t.file_name)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .chars()
                    .take(256)
                    .collect();
                serde_json::to_value(t).unwrap()
            })
            .collect();
        Ok(
            json!({"v":1,"identity":self.fingerprint(),"name":std::env::var("COMPUTERNAME").unwrap_or_else(|_|"Mytify PC".into()),"tracks":items,"playlists":self.saved.lock().unwrap().playlists}),
        )
    }
    fn serve(
        &self,
        socket: TcpStream,
        config: Arc<rustls::ServerConfig>,
        stop: &AtomicBool,
    ) -> Result<()> {
        // Windows: sockets accepted from a non-blocking listener inherit non-blocking mode,
        // so the first TLS read hit WouldBlock and the phone saw os error 10053.
        socket.set_nonblocking(false)?;
        socket.set_read_timeout(Some(Duration::from_secs(15)))?;
        socket.set_write_timeout(Some(Duration::from_secs(15)))?;
        let conn = rustls::ServerConnection::new(config)?;
        let mut stream = rustls::StreamOwned::new(conn, socket);
        let mut reader = BufReader::new(&mut stream);
        let mut line = String::new();
        Read::by_ref(&mut reader).take(4097).read_line(&mut line)?;
        ensure!(line.len() <= 4096, "Żądanie za duże");
        let parts: Vec<_> = line.split_whitespace().collect();
        ensure!(
            parts.len() == 3 && parts[2] == "HTTP/1.1",
            "Nieprawidłowe HTTP"
        );
        let method = parts[0].to_owned();
        let path = parts[1].to_owned();
        let mut headers = HashMap::new();
        let mut total = line.len();
        loop {
            line.clear();
            Read::by_ref(&mut reader).take(16385).read_line(&mut line)?;
            total += line.len();
            ensure!(total <= 16384, "Nagłówki za duże");
            if line == "\r\n" {
                break;
            }
            ensure!(!line.is_empty() && line.ends_with("\r\n"), "Niepełne HTTP");
            let (k, v) = line.split_once(':').ok_or_else(|| anyhow!("Nagłówek"))?;
            ensure!(
                headers
                    .insert(k.to_ascii_lowercase(), v.trim().to_owned())
                    .is_none(),
                "Powtórzony nagłówek"
            );
        }
        if stop.load(Ordering::Acquire) {
            return Ok(());
        }
        let length = headers
            .get("content-length")
            .map(|n| n.parse::<usize>())
            .transpose()?
            .unwrap_or(0);
        ensure!(
            length <= 4096 && !headers.contains_key("transfer-encoding"),
            "Nieprawidłowe żądanie"
        );
        let mut body = vec![0; length];
        reader.read_exact(&mut body)?;
        drop(reader);
        if headers.contains_key("origin") || headers.contains_key("referer") {
            return respond(&mut stream, 403, &[], b"", None);
        }
        if method == "POST" && path == "/pair" {
            let v: Value = serde_json::from_slice(&body)?;
            let name = v["name"]
                .as_str()
                .unwrap_or("Telefon")
                .chars()
                .take(80)
                .collect::<String>();
            let mut l = self.live.lock().unwrap();
            let valid = l.as_ref().is_some_and(|l| {
                !l.secret.is_empty()
                    && now() < l.expires
                    && equal(&l.secret, v["secret"].as_str().unwrap_or(""))
            });
            if !valid {
                return respond(&mut stream, 403, &[], b"", None);
            }
            let mut s = self.saved.lock().unwrap();
            ensure!(s.peers.len() < 32, "Za dużo sparowanych telefonów");
            let token = random()?;
            let peer = Peer {
                id: random()?,
                name,
                token_hash: hash(token.as_bytes()),
                created: now(),
            };
            let result = json!({"identity":hash(&B64.decode(&s.cert)?),"token":token,"id":peer.id,"name":std::env::var("COMPUTERNAME").unwrap_or_else(|_|"Mytify PC".into())});
            s.peers.push(peer);
            self.persist(&s)?;
            if let Some(l) = l.as_mut() {
                l.secret.clear();
                l.qr.clear()
            }
            return respond(&mut stream, 200, &[], &serde_json::to_vec(&result)?, None);
        }
        let token = headers
            .get("authorization")
            .and_then(|s| s.strip_prefix("Bearer "))
            .unwrap_or("");
        if !self.authorized(token) {
            return respond(&mut stream, 401, &[], b"", None);
        }
        if method == "GET" && path == "/manifest" {
            let b = serde_json::to_vec(&self.manifest()?)?;
            ensure!(b.len() <= 8 * 1024 * 1024, "Manifest za duży");
            return respond(&mut stream, 200, &[], &b, None);
        }
        let file = if method == "GET" && path.starts_with("/file/") {
            let key = &path[6..];
            if !id(key) {
                return respond(&mut stream, 404, &[], b"", None);
            }
            self.catalog.audio_path(key).ok().map(|p| (p, false))
        } else if method == "GET" && path.starts_with("/cover/") {
            let key = &path[7..];
            if !id(key) {
                return respond(&mut stream, 404, &[], b"", None);
            }
            let allowed = self
                .catalog
                .tracks()?
                .iter()
                .any(|t| t.cover.as_deref() == Some(key));
            if allowed {
                self.catalog.artwork_path(key).ok().map(|p| (p, true))
            } else {
                None
            }
        } else {
            None
        };
        let Some((p, cover)) = file else {
            return respond(&mut stream, 404, &[], b"", None);
        };
        let mut file = File::open(p)?;
        let size = file.metadata()?.len();
        if cover && size > 8 * 1024 * 1024 {
            return respond(&mut stream, 413, &[], b"", None);
        }
        let offset = if let Some(range) = headers.get("range") {
            match range
                .strip_prefix("bytes=")
                .and_then(|s| s.strip_suffix('-'))
                .and_then(|s| s.parse::<u64>().ok())
            {
                Some(n) if n < size => n,
                _ => return respond(&mut stream, 416, &[], b"", None),
            }
        } else {
            0
        };
        file.seek(SeekFrom::Start(offset))?;
        let extra = if headers.contains_key("range") {
            vec![(
                "Content-Range",
                format!("bytes {}-{}/{}", offset, size - 1, size),
            )]
        } else {
            vec![]
        };
        respond(
            &mut stream,
            if extra.is_empty() { 200 } else { 206 },
            &extra,
            &[],
            Some(size - offset),
        )?;
        let mut left = size - offset;
        let mut buf = [0u8; 65536];
        while left > 0 {
            ensure!(
                !stop.load(Ordering::Acquire) && self.authorized(token),
                "Transfer zatrzymany"
            );
            let n = file.read(&mut buf[..left.min(65536) as usize])?;
            ensure!(n > 0, "Plik zmienił się podczas transferu");
            stream.write_all(&buf[..n])?;
            left -= n as u64;
        }
        stream.flush()?;
        Ok(())
    }
}
fn respond(
    w: &mut impl Write,
    status: u16,
    extra: &[(&str, String)],
    body: &[u8],
    length: Option<u64>,
) -> Result<()> {
    write!(w,"HTTP/1.1 {} OK\r\nContent-Length: {}\r\nConnection: close\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n",status,length.unwrap_or(body.len()as u64))?;
    for (k, v) in extra {
        write!(w, "{k}: {v}\r\n")?
    }
    w.write_all(b"\r\n")?;
    w.write_all(body)?;
    w.flush()?;
    Ok(())
}
impl Drop for Transfer {
    fn drop(&mut self) {
        self.stop()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (
        tempfile::TempDir,
        tempfile::TempDir,
        Arc<Catalog>,
        Arc<Transfer>,
    ) {
        let data = tempfile::tempdir().unwrap();
        let source = tempfile::tempdir().unwrap();
        fs::copy(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../test/fixtures/sample.flac"),
            source.path().join("song.flac"),
        )
        .unwrap();
        let c = Arc::new(Catalog::open(data.path()).unwrap());
        c.scan(
            crate::catalog::ScanRequest {
                paths: vec![source.path().to_string_lossy().into()],
                folder: true,
                ..Default::default()
            },
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap();
        let t = Transfer::new(c.clone()).unwrap();
        (data, source, c, t)
    }
    fn start(t: &Arc<Transfer>) -> (reqwest::blocking::Client, String, String) {
        let s = t.command(json!({"action":"start","port":0})).unwrap();
        let port = s["port"].as_u64().unwrap() as u16;
        let der = B64.decode(&t.saved.lock().unwrap().cert).unwrap();
        let client = reqwest::blocking::Client::builder()
            .no_proxy()
            .add_root_certificate(reqwest::Certificate::from_der(&der).unwrap())
            .resolve("mytify.local", ([127, 0, 0, 1], port).into())
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        let uri = url::Url::parse(s["pairUri"].as_str().unwrap()).unwrap();
        let secret = uri
            .query_pairs()
            .find(|(k, _)| k == "secret")
            .unwrap()
            .1
            .to_string();
        (client, format!("https://mytify.local:{port}"), secret)
    }
    #[test]
    fn tls_pairing_one_use_range_and_private_catalog() {
        let (_d, _s, c, t) = fixture();
        let (client, base, secret) = start(&t);
        assert_eq!(
            client
                .get(format!("{base}/manifest"))
                .send()
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            client
                .post(format!("{base}/pair"))
                .json(&json!({"secret":"bad"}))
                .send()
                .unwrap()
                .status(),
            403
        );
        let p: Value = client
            .post(format!("{base}/pair"))
            .json(&json!({"secret":secret,"name":"Test phone"}))
            .send()
            .unwrap()
            .json()
            .unwrap();
        let token = p["token"].as_str().unwrap();
        assert!(id(token));
        assert_eq!(p["identity"], t.fingerprint());
        assert_eq!(
            client
                .post(format!("{base}/pair"))
                .json(&json!({"secret":secret}))
                .send()
                .unwrap()
                .status(),
            403
        );
        let m: Value = client
            .get(format!("{base}/manifest"))
            .bearer_auth(token)
            .send()
            .unwrap()
            .json()
            .unwrap();
        assert_eq!(m["tracks"].as_array().unwrap().len(), 1);
        assert!(!m
            .to_string()
            .contains(&c.root.to_string_lossy().to_string()));
        let track = &c.tracks().unwrap()[0];
        let bytes = fs::read(c.audio_path(&track.id).unwrap()).unwrap();
        let r = client
            .get(format!("{base}/file/{}", track.id))
            .bearer_auth(token)
            .header("Range", "bytes=123-")
            .send()
            .unwrap();
        assert_eq!(r.status(), 206);
        assert_eq!(
            r.headers()["content-range"],
            format!("bytes 123-{}/{}", bytes.len() - 1, bytes.len())
        );
        assert_eq!(r.bytes().unwrap().as_ref(), &bytes[123..]);
        assert_eq!(
            client
                .get(format!("{base}/file/{}", track.id))
                .bearer_auth(token)
                .header("Range", "bytes=999999999-")
                .send()
                .unwrap()
                .status(),
            416
        );
        assert_eq!(
            client
                .get(format!("{base}/file/{}", "0".repeat(64)))
                .bearer_auth(token)
                .send()
                .unwrap()
                .status(),
            404
        );
        assert_eq!(
            client
                .get(format!("{base}/manifest"))
                .bearer_auth(token)
                .header("Origin", "https://evil.example")
                .send()
                .unwrap()
                .status(),
            403
        );
        let art = track.cover.as_ref().unwrap();
        assert_eq!(
            client
                .get(format!("{base}/cover/{art}"))
                .bearer_auth(token)
                .send()
                .unwrap()
                .bytes()
                .unwrap()
                .as_ref(),
            fs::read(c.artwork_path(art).unwrap()).unwrap()
        );
        t.command(json!({"action":"revoke","id":p["id"]})).unwrap();
        assert_eq!(
            client
                .get(format!("{base}/manifest"))
                .bearer_auth(token)
                .send()
                .unwrap()
                .status(),
            401
        );
        t.stop();
    }
    #[test]
    fn expired_qr_and_untrusted_certificate_are_rejected() {
        let (_d, _s, _c, t) = fixture();
        let (client, base, secret) = start(&t);
        t.live.lock().unwrap().as_mut().unwrap().expires = 0;
        assert_eq!(
            client
                .post(format!("{base}/pair"))
                .json(&json!({"secret":secret}))
                .send()
                .unwrap()
                .status(),
            403
        );
        let port = t.live.lock().unwrap().as_ref().unwrap().port;
        let untrusted = reqwest::blocking::Client::builder()
            .no_proxy()
            .resolve("mytify.local", ([127, 0, 0, 1], port).into())
            .build()
            .unwrap();
        assert!(untrusted.get(format!("{base}/manifest")).send().is_err());
        t.stop();
    }
    #[test]
    fn credentials_persist_across_host_restart() {
        let (_d, _s, c, t) = fixture();
        let (client, base, secret) = start(&t);
        let p: Value = client
            .post(format!("{base}/pair"))
            .json(&json!({"secret":secret}))
            .send()
            .unwrap()
            .json()
            .unwrap();
        let pin = t.fingerprint();
        t.stop();
        let next = Transfer::new(c).unwrap();
        assert_eq!(pin, next.fingerprint());
        let (client, base, _) = start(&next);
        assert_eq!(
            client
                .get(format!("{base}/manifest"))
                .bearer_auth(p["token"].as_str().unwrap())
                .send()
                .unwrap()
                .status(),
            200
        );
        let saved = fs::read_to_string(next.catalog.root.join("transfer-identity.json")).unwrap();
        assert!(!saved.contains(p["token"].as_str().unwrap()));
        next.stop();
    }
    #[test]
    fn playlists_validate_order_and_persist() {
        let (_d, _s, c, t) = fixture();
        let id = &c.tracks().unwrap()[0].id;
        let p = t
            .command(json!({"action":"playlistSave","name":"Na drogę","ids":[id]}))
            .unwrap();
        assert!(t
            .command(json!({"action":"playlistSave","name":"Bad","ids":["0".repeat(64)]}))
            .is_err());
        assert!(t
            .command(json!({"action":"playlistSave","name":"Bad","ids":[id,id]}))
            .is_err());
        let next = Transfer::new(c).unwrap();
        let a = next.command(json!({"action":"playlistList"})).unwrap();
        assert_eq!(a[0]["ids"], json!([id]));
        next.command(json!({"action":"playlistDelete","id":p["id"]}))
            .unwrap();
        assert_eq!(
            next.command(json!({"action":"playlistList"})).unwrap(),
            json!([])
        );
    }
}
