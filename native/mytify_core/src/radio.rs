//! Internet radio: the Radio Browser directory, playlist files and the HTTP stream
//! with ICY metadata. Decoding lives in `audio::live`.
use anyhow::{anyhow, bail, Context, Result};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::{HashMap, VecDeque},
    io::Read,
    sync::{Arc, Mutex},
    time::Duration,
};

pub const USER_AGENT: &str = concat!("Mytify/", env!("CARGO_PKG_VERSION"), " (github.com/m6a6t6i-hue/Mytify)");
/// Used only when the server list itself cannot be fetched.
const FALLBACK: [&str; 4] = [
    "de1.api.radio-browser.info",
    "de2.api.radio-browser.info",
    "fi1.api.radio-browser.info",
    "nl1.api.radio-browser.info",
];

#[derive(Clone, Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Station {
    pub id: String,
    pub name: String,
    pub url: String,
    pub logo: String,
    pub tags: Vec<String>,
    pub country: String,
    pub codec: String,
    pub bitrate: u32,
    pub hls: bool,
}

pub fn station(v: &Value) -> Option<Station> {
    let uuid = v["stationuuid"].as_str()?.trim();
    if uuid.is_empty() || uuid.len() > 64 {
        return None;
    }
    let url = [v["url_resolved"].as_str(), v["url"].as_str()]
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|u| u.starts_with("http://") || u.starts_with("https://"))?;
    let logo = v["favicon"].as_str().unwrap_or("").trim();
    Some(Station {
        id: format!("radio:{uuid}"),
        name: v["name"].as_str().unwrap_or("").trim().to_string(),
        url: url.to_string(),
        logo: if logo.starts_with("https://") || logo.starts_with("http://") {
            logo.to_string()
        } else {
            String::new()
        },
        tags: v["tags"]
            .as_str()
            .unwrap_or("")
            .split(',')
            .map(|t| t.trim().to_lowercase())
            .filter(|t| !t.is_empty())
            .take(6)
            .collect(),
        country: v["countrycode"].as_str().unwrap_or("").to_string(),
        codec: v["codec"].as_str().unwrap_or("").to_string(),
        bitrate: v["bitrate"].as_u64().unwrap_or(0) as u32,
        hls: v["hls"].as_i64() == Some(1) || v["hls"].as_bool() == Some(true),
    })
}

fn client(timeout: Duration) -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(Duration::from_secs(8))
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()?)
}

fn read_limited(r: impl Read, limit: u64) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    r.take(limit + 1).read_to_end(&mut out)?;
    if out.len() as u64 > limit {
        bail!("Odpowiedź jest za duża.");
    }
    Ok(out)
}

/// The directory: picks a server, falls back to the next one, remembers the one that worked.
pub struct Directory {
    servers: Mutex<VecDeque<String>>,
    logos: Mutex<HashMap<String, (String, Arc<Vec<u8>>)>>,
}
impl Default for Directory {
    fn default() -> Self {
        Self::new()
    }
}
impl Directory {
    pub fn new() -> Self {
        Self {
            servers: Mutex::new(VecDeque::new()),
            logos: Mutex::new(HashMap::new()),
        }
    }
    fn servers(&self) -> Vec<String> {
        let known: Vec<String> = self.servers.lock().unwrap().iter().cloned().collect();
        if !known.is_empty() {
            return known;
        }
        let mut list: Vec<String> = client(Duration::from_secs(8))
            .and_then(|c| {
                let r = c.get("https://all.api.radio-browser.info/json/servers").send()?;
                Ok(serde_json::from_slice::<Value>(&read_limited(r, 256 * 1024)?)?)
            })
            .ok()
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|s| s["name"].as_str())
            .filter(|n| n.ends_with(".radio-browser.info"))
            .map(str::to_string)
            .collect();
        list.sort();
        list.dedup();
        if list.is_empty() {
            list = FALLBACK.iter().map(|s| s.to_string()).collect();
        }
        // Spread the load as the directory asks: start from a random server.
        let start = crate::catalog::getrandom_bytes()
            .map(|b| b[0] as usize % list.len())
            .unwrap_or(0);
        list.rotate_left(start);
        *self.servers.lock().unwrap() = list.iter().cloned().collect();
        list
    }
    fn get(&self, path: &str) -> Result<Value> {
        let c = client(Duration::from_secs(12))?;
        let mut last = anyhow!("Katalog stacji jest niedostępny.");
        for server in self.servers() {
            let result = c
                .get(format!("https://{server}{path}"))
                .send()
                .map_err(anyhow::Error::from)
                .and_then(|r| {
                    if !r.status().is_success() {
                        bail!("HTTP {}", r.status().as_u16());
                    }
                    Ok(serde_json::from_slice::<Value>(&read_limited(r, 4 * 1024 * 1024)?)?)
                });
            match result {
                Ok(v) => {
                    let mut s = self.servers.lock().unwrap();
                    if let Some(i) = s.iter().position(|x| x == &server) {
                        let first = s.remove(i).unwrap();
                        s.push_front(first);
                    }
                    return Ok(v);
                }
                Err(e) => last = e,
            }
        }
        Err(last.context("Katalog stacji radiowych nie odpowiada. Sprawdź internet"))
    }
    /// name, tag, country (two letters), order (popular|name), limit, offset.
    pub fn search(&self, q: &HashMap<String, String>) -> Result<Vec<Station>> {
        let mut query = url::form_urlencoded::Serializer::new(String::new());
        for key in ["name", "tag"] {
            if let Some(v) = q.get(key).map(|s| s.trim()).filter(|s| !s.is_empty()) {
                query.append_pair(key, &v.chars().take(100).collect::<String>());
            }
        }
        if let Some(c) = q.get("country").filter(|c| c.len() == 2 && c.bytes().all(|b| b.is_ascii_alphabetic())) {
            query.append_pair("countrycode", &c.to_uppercase());
        }
        if q.get("order").map(String::as_str) == Some("name") {
            query.append_pair("order", "name");
        } else {
            query.append_pair("order", "clickcount").append_pair("reverse", "true");
        }
        let limit = q.get("limit").and_then(|l| l.parse::<u32>().ok()).unwrap_or(40).clamp(1, 100);
        let offset = q.get("offset").and_then(|l| l.parse::<u32>().ok()).unwrap_or(0).min(10000);
        query
            .append_pair("hidebroken", "true")
            .append_pair("limit", &limit.to_string())
            .append_pair("offset", &offset.to_string());
        let v = self.get(&format!("/json/stations/search?{}", query.finish()))?;
        Ok(v.as_array().map(|a| a.iter().filter_map(station).collect()).unwrap_or_default())
    }
    /// Counts the listen in the directory (as it asks clients to) and returns the current address.
    pub fn click(&self, id: &str) -> Result<Option<String>> {
        let uuid = id.strip_prefix("radio:").unwrap_or(id);
        if uuid.is_empty() || uuid.len() > 64 || !uuid.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
            return Ok(None);
        }
        let v = self.get(&format!("/json/url/{uuid}"))?;
        Ok(v["url"].as_str().filter(|u| u.starts_with("http")).map(str::to_string))
    }
    /// Station logos come through here: the window cannot load images from other sites itself.
    pub fn logo(&self, url: &str) -> Result<(String, Arc<Vec<u8>>)> {
        if let Some(hit) = self.logos.lock().unwrap().get(url) {
            return Ok(hit.clone());
        }
        let parsed = url::Url::parse(url)?;
        if !matches!(parsed.scheme(), "http" | "https") {
            bail!("Nieprawidłowy adres logo.");
        }
        let r = client(Duration::from_secs(8))?.get(parsed).send()?;
        if !r.status().is_success() {
            bail!("Logo niedostępne (HTTP {}).", r.status().as_u16());
        }
        let kind = r
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_lowercase();
        let bytes = read_limited(r, 512 * 1024)?;
        let kind = match (kind.as_str(), &bytes[..bytes.len().min(8)]) {
            (_, [0x89, b'P', b'N', b'G', ..]) => "image/png",
            (_, [0xFF, 0xD8, ..]) => "image/jpeg",
            (_, [b'G', b'I', b'F', ..]) => "image/gif",
            (_, [b'R', b'I', b'F', b'F', ..]) => "image/webp",
            (_, [0, 0, 1, 0, ..]) => "image/x-icon",
            _ => bail!("To nie jest obraz."),
        };
        let hit = (kind.to_string(), Arc::new(bytes));
        let mut logos = self.logos.lock().unwrap();
        if logos.len() > 300 {
            logos.clear();
        }
        logos.insert(url.to_string(), hit.clone());
        Ok(hit)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Mp3,
    Aac,
    Ogg,
    Flac,
    Playlist,
    Unknown,
}
impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Mp3 => "MP3",
            Kind::Aac => "AAC",
            Kind::Ogg => "OGG",
            Kind::Flac => "FLAC",
            Kind::Playlist | Kind::Unknown => "",
        }
    }
}
pub fn kind_of(content_type: &str, url: &str) -> Kind {
    let ct = content_type.split(';').next().unwrap_or("").trim().to_lowercase();
    match ct.as_str() {
        "audio/mpeg" | "audio/mp3" | "audio/mpeg3" | "audio/x-mpeg" | "audio/mpg" => Kind::Mp3,
        "audio/aac" | "audio/aacp" | "audio/x-aac" | "audio/x-aacp" | "audio/aac-adts" | "audio/mp4a-latm" => Kind::Aac,
        "application/ogg" | "audio/ogg" | "audio/vorbis" | "audio/x-ogg" => Kind::Ogg,
        "audio/flac" | "audio/x-flac" => Kind::Flac,
        "audio/x-scpls" | "application/pls+xml" | "audio/x-mpegurl" | "audio/mpegurl" | "application/x-mpegurl"
        | "application/vnd.apple.mpegurl" | "video/x-ms-asf" | "audio/x-ms-wax" | "application/xspf+xml" => Kind::Playlist,
        _ => {
            let path = url.split(['?', '#']).next().unwrap_or("").to_lowercase();
            if [".pls", ".m3u", ".m3u8", ".asx", ".xspf"].iter().any(|e| path.ends_with(e)) {
                Kind::Playlist
            } else if path.ends_with(".mp3") {
                Kind::Mp3
            } else if path.ends_with(".aac") || path.ends_with(".aacp") {
                Kind::Aac
            } else if path.ends_with(".ogg") || path.ends_with(".oga") {
                Kind::Ogg
            } else {
                Kind::Unknown
            }
        }
    }
}
/// Recognises the stream from its first bytes when the server does not say what it sends.
pub fn sniff(head: &[u8]) -> Kind {
    if head.starts_with(b"OggS") {
        return Kind::Ogg;
    }
    if head.starts_with(b"fLaC") {
        return Kind::Flac;
    }
    if head.starts_with(b"ID3") {
        return Kind::Mp3;
    }
    let text = String::from_utf8_lossy(&head[..head.len().min(64)]).trim_start().to_lowercase();
    if text.starts_with("#extm3u") || text.starts_with("[playlist]") || text.starts_with("http") {
        return Kind::Playlist;
    }
    for w in head.windows(4) {
        if w[0] != 0xFF {
            continue;
        }
        if w[1] & 0xF6 == 0xF0 && (w[2] >> 2) & 0x0F < 13 {
            return Kind::Aac;
        }
        if w[1] & 0xE0 == 0xE0 && (w[1] >> 1) & 3 == 1 && w[2] >> 4 != 15 && w[2] >> 4 != 0 {
            return Kind::Mp3;
        }
    }
    Kind::Unknown
}

pub enum Entry {
    Stream(String),
    Hls,
}
/// First stream address in a PLS, M3U, ASX or XSPF playlist; HLS is reported as such.
pub fn parse_playlist(text: &str, base: &str) -> Option<Entry> {
    if text.contains("#EXT-X-") {
        return Some(Entry::Hls);
    }
    let absolute = |s: &str| -> Option<String> {
        let s = s.trim().trim_matches('"');
        let u = url::Url::parse(base).ok()?.join(s).ok()?;
        matches!(u.scheme(), "http" | "https").then(|| u.to_string())
    };
    for line in text.lines() {
        let line = line.trim();
        if let Some((key, value)) = line.split_once('=') {
            if key.trim().to_lowercase().starts_with("file") {
                if let Some(u) = absolute(value) {
                    return Some(Entry::Stream(u));
                }
            }
        }
    }
    let lower = text.to_lowercase();
    for tag in ["href=\"", "<location>"] {
        if let Some(i) = lower.find(tag) {
            let rest = &text[i + tag.len()..];
            let end = rest.find(['"', '<']).unwrap_or(rest.len());
            if let Some(u) = absolute(&rest[..end]) {
                return Some(Entry::Stream(u));
            }
        }
    }
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with('[') && !l.starts_with('<'))
        .find_map(absolute)
        .map(Entry::Stream)
}

pub const HLS_UNSUPPORTED: &str = "Ta stacja nadaje w formacie HLS, który na PC jeszcze nie jest obsługiwany.";

/// Title and station name read from the stream, shared with the player state.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveMeta {
    pub title: Option<String>,
    pub station: Option<String>,
    pub codec: String,
    pub bitrate: u32,
    pub reconnecting: bool,
}

/// Strips ICY metadata blocks out of the audio and keeps the latest StreamTitle.
pub struct IcyReader<R: Read> {
    inner: R,
    interval: usize,
    left: usize,
    meta: Arc<Mutex<LiveMeta>>,
}
impl<R: Read> IcyReader<R> {
    pub fn new(inner: R, interval: usize, meta: Arc<Mutex<LiveMeta>>) -> Self {
        Self { inner, interval, left: interval, meta }
    }
    fn metadata(&mut self) -> std::io::Result<()> {
        let mut len = [0u8; 1];
        self.inner.read_exact(&mut len)?;
        let mut block = vec![0u8; len[0] as usize * 16];
        self.inner.read_exact(&mut block)?;
        if let Some(title) = stream_title(&block) {
            self.meta.lock().unwrap().title = title;
        }
        Ok(())
    }
}
impl<R: Read> Read for IcyReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.interval == 0 {
            return self.inner.read(buf);
        }
        if self.left == 0 {
            self.metadata()?;
            self.left = self.interval;
        }
        let n = buf.len().min(self.left);
        let read = self.inner.read(&mut buf[..n])?;
        self.left -= read;
        Ok(read)
    }
}
/// `Some(None)` clears the title (empty StreamTitle), `None` means the block had none.
pub fn stream_title(block: &[u8]) -> Option<Option<String>> {
    let end = block.iter().position(|b| *b == 0).unwrap_or(block.len());
    let block = &block[..end];
    if block.is_empty() {
        return None;
    }
    let text = match std::str::from_utf8(block) {
        Ok(s) => s.to_string(),
        Err(_) => block.iter().map(|&b| b as char).collect(), // Latin-1
    };
    let start = text.find("StreamTitle='")? + "StreamTitle='".len();
    let rest = &text[start..];
    let value = rest.find("';").map(|i| &rest[..i]).unwrap_or(rest.trim_end_matches('\''));
    let value: String = value.chars().filter(|c| !c.is_control()).collect::<String>().trim().to_string();
    let value = value.trim_matches(['-', ' ']).to_string();
    Some(if value.is_empty() { None } else { Some(value.chars().take(300).collect()) })
}

pub struct Opened {
    pub reader: Box<dyn Read + Send>,
    pub kind: Kind,
}
fn header(r: &reqwest::blocking::Response, name: &str) -> Option<String> {
    r.headers().get(name).and_then(|v| v.to_str().ok()).map(|s| s.trim().to_string())
}
/// Connects to a station, following playlists. The reader returns audio only.
pub fn open(url: &str, meta: &Arc<Mutex<LiveMeta>>) -> Result<Opened> {
    let mut url = url.to_string();
    for _ in 0..4 {
        let parsed = url::Url::parse(&url).context("Nieprawidłowy adres stacji")?;
        if !matches!(parsed.scheme(), "http" | "https") {
            bail!("Adres stacji musi zaczynać się od http:// lub https://");
        }
        // A stalled station must not hang forever; the limit applies to each read.
        let r = client(Duration::from_secs(15))?
            .get(parsed)
            .header("Icy-MetaData", "1")
            .send()
            .context("Nie można połączyć się ze stacją")?;
        if !r.status().is_success() {
            bail!("Stacja odpowiedziała błędem HTTP {}.", r.status().as_u16());
        }
        let content_type = header(&r, "content-type").unwrap_or_default();
        let final_url = r.url().to_string();
        let mut kind = kind_of(&content_type, &final_url);
        let interval = header(&r, "icy-metaint").and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
        {
            let mut m = meta.lock().unwrap();
            if let Some(name) = header(&r, "icy-name").filter(|n| !n.is_empty() && n.len() < 200) {
                m.station = Some(name);
            }
            m.bitrate = header(&r, "icy-br")
                .and_then(|v| v.split(',').next().and_then(|b| b.trim().parse().ok()))
                .unwrap_or(0);
        }
        if kind == Kind::Playlist {
            let text = String::from_utf8_lossy(&read_limited(r, 256 * 1024)?).to_string();
            match parse_playlist(&text, &final_url) {
                Some(Entry::Stream(next)) => {
                    url = next;
                    continue;
                }
                Some(Entry::Hls) => bail!(HLS_UNSUPPORTED),
                None => bail!("Lista stacji nie zawiera adresu strumienia."),
            }
        }
        if content_type.starts_with("text/html") {
            bail!("Pod tym adresem jest strona internetowa, a nie strumień radia.");
        }
        let mut reader = IcyReader::new(r, interval, meta.clone());
        let mut head = vec![0u8; 8192];
        let mut got = 0;
        while got < head.len() {
            let n = reader.read(&mut head[got..])?;
            if n == 0 {
                break;
            }
            got += n;
        }
        head.truncate(got);
        if got == 0 {
            bail!("Stacja nie przesyła dźwięku.");
        }
        if kind == Kind::Unknown {
            kind = sniff(&head);
        }
        if kind == Kind::Playlist {
            let mut rest = head.clone();
            reader.take(256 * 1024).read_to_end(&mut rest)?;
            match parse_playlist(&String::from_utf8_lossy(&rest), &final_url) {
                Some(Entry::Stream(next)) => {
                    url = next;
                    continue;
                }
                Some(Entry::Hls) => bail!(HLS_UNSUPPORTED),
                None => bail!("Lista stacji nie zawiera adresu strumienia."),
            }
        }
        if kind == Kind::Unknown {
            bail!("Nieznany format strumienia ({}).", if content_type.is_empty() { "brak typu" } else { &content_type });
        }
        meta.lock().unwrap().codec = kind.name().into();
        return Ok(Opened {
            reader: Box::new(std::io::Cursor::new(head).chain(reader)),
            kind,
        });
    }
    bail!("Za dużo przekierowań list stacji.")
}

/// Follows .pls/.m3u/.asx files to the stream address, for receivers that only take streams.
/// HLS addresses are returned as they are: some receivers play them.
pub fn resolve_playlist(url: &str) -> Result<String> {
    let mut url = url.to_string();
    for _ in 0..4 {
        if !url.starts_with("http://") && !url.starts_with("https://") {
            bail!("Adres stacji musi zaczynać się od http:// lub https://");
        }
        let path = url.split(['?', '#']).next().unwrap_or("").to_lowercase();
        if path.ends_with(".m3u8") || kind_of("", &url) != Kind::Playlist {
            return Ok(url);
        }
        let r = client(Duration::from_secs(10))?.get(&url).send()?;
        let base = r.url().to_string();
        let text = String::from_utf8_lossy(&read_limited(r, 256 * 1024)?).to_string();
        match parse_playlist(&text, &base) {
            Some(Entry::Stream(next)) => url = next,
            Some(Entry::Hls) => return Ok(url),
            None => bail!("Lista stacji nie zawiera adresu strumienia."),
        }
    }
    bail!("Za dużo przekierowań list stacji.")
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Probe {
    pub url: String,
    pub name: Option<String>,
    pub codec: String,
    pub hls: bool,
}
/// Checks an address the user typed (or a playlist) before it is saved as a station.
pub fn probe(url: &str) -> Result<Probe> {
    let meta = Arc::new(Mutex::new(LiveMeta::default()));
    match open(url, &meta) {
        Ok(o) => {
            drop(o.reader);
            let m = meta.lock().unwrap();
            Ok(Probe { url: url.into(), name: m.station.clone(), codec: m.codec.clone(), hls: false })
        }
        Err(e) if e.to_string() == HLS_UNSUPPORTED => Ok(Probe { url: url.into(), name: None, codec: "HLS".into(), hls: true }),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directory_rows() {
        let v: Value = serde_json::from_str(
            r#"{"stationuuid":"9617a958-0601-11e8-ae97-52543be04c81","name":" Jazz FM ","url":"http://x/a.pls",
            "url_resolved":"https://s.example/jazz","favicon":"javascript:alert(1)","tags":"Jazz, smooth jazz,,","countrycode":"PL",
            "codec":"AAC+","bitrate":64,"hls":0}"#,
        )
        .unwrap();
        let s = station(&v).unwrap();
        assert_eq!(s.id, "radio:9617a958-0601-11e8-ae97-52543be04c81");
        assert_eq!(s.name, "Jazz FM");
        assert_eq!(s.url, "https://s.example/jazz");
        assert_eq!(s.logo, "");
        assert_eq!(s.tags, vec!["jazz", "smooth jazz"]);
        assert!(!s.hls);
        assert!(station(&serde_json::json!({"stationuuid":"a","url":"ftp://x"})).is_none());
    }

    #[test]
    fn playlists() {
        let pls = "[playlist]\nNumberOfEntries=2\nFile1=http://a.example:8000/live\nTitle1=A\nFile2=http://b/live\n";
        assert!(matches!(parse_playlist(pls, "http://x/"), Some(Entry::Stream(u)) if u == "http://a.example:8000/live"));
        let m3u = "#EXTM3U\n#EXTINF:-1,Radio\nhttps://c.example/stream.mp3\n";
        assert!(matches!(parse_playlist(m3u, "http://x/"), Some(Entry::Stream(u)) if u == "https://c.example/stream.mp3"));
        let relative = "stream/aac\n";
        assert!(matches!(parse_playlist(relative, "http://x.example/list.m3u"), Some(Entry::Stream(u)) if u == "http://x.example/stream/aac"));
        let hls = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nchunks.m3u8\n";
        assert!(matches!(parse_playlist(hls, "http://x/"), Some(Entry::Hls)));
        let asx = "<asx><entry><ref href=\"http://d.example/live\"/></entry></asx>";
        assert!(matches!(parse_playlist(asx, "http://x/"), Some(Entry::Stream(u)) if u == "http://d.example/live"));
        assert!(parse_playlist("<html>nope</html>", "http://x/").is_none());
    }

    #[test]
    fn kinds() {
        assert_eq!(kind_of("audio/mpeg", ""), Kind::Mp3);
        assert_eq!(kind_of("audio/aacp; charset=x", ""), Kind::Aac);
        assert_eq!(kind_of("application/octet-stream", "http://x/a.pls?x=1"), Kind::Playlist);
        assert_eq!(kind_of("", "http://x/live"), Kind::Unknown);
        assert_eq!(sniff(&[0, 1, 0xFF, 0xF1, 0x50, 0x80, 0, 0]), Kind::Aac);
        assert_eq!(sniff(&[0, 0xFF, 0xFB, 0x90, 0x64, 0]), Kind::Mp3);
        assert_eq!(sniff(b"OggS\0\x02"), Kind::Ogg);
        assert_eq!(sniff(b"[playlist]\nFile1=http://x"), Kind::Playlist);
    }

    #[test]
    fn icy_titles_are_stripped_from_audio() {
        let mut stream = Vec::new();
        let meta_block = |t: &str| {
            let mut m = format!("StreamTitle='{t}';StreamUrl='';").into_bytes();
            let len = m.len().div_ceil(16);
            m.resize(len * 16, 0);
            let mut b = vec![len as u8];
            b.extend(m);
            b
        };
        stream.extend([1u8; 8]);
        stream.extend(meta_block("Artysta - Tytuł 'Live'"));
        stream.extend([2u8; 8]);
        stream.push(0); // no metadata this time
        stream.extend([3u8; 4]);
        let meta = Arc::new(Mutex::new(LiveMeta::default()));
        let mut r = IcyReader::new(std::io::Cursor::new(stream), 8, meta.clone());
        let mut audio = Vec::new();
        r.read_to_end(&mut audio).unwrap();
        assert_eq!(audio, [[1u8; 8].as_slice(), &[2u8; 8], &[3u8; 4]].concat());
        assert_eq!(meta.lock().unwrap().title.as_deref(), Some("Artysta - Tytuł 'Live'"));
        assert_eq!(stream_title(b"StreamTitle='';\0\0"), Some(None));
        assert_eq!(stream_title(b"StreamTitle='Caf\xe9 - X';"), Some(Some("Café - X".into())));
    }
}
