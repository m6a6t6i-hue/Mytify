//! WebDAV over HTTPS: folder listing (PROPFIND) and ranged reads. TLS certificates are
//! always verified with the system trust store; credentials never follow a redirect to
//! another host.

use anyhow::{anyhow, bail, Result};
use reqwest::{
    blocking::{Client, Response},
    header::{HeaderValue, ACCEPT_RANGES, CONTENT_RANGE, ETAG, RANGE},
    redirect, Method, StatusCode,
};
use std::{
    collections::HashMap,
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
use url::Url;

#[derive(Clone, Debug)]
pub struct Entry {
    /// Path on the server, percent-encoded exactly as the server reported it.
    pub href: String,
    pub name: String,
    pub dir: bool,
    pub size: u64,
    /// ETag or Last-Modified, whichever the server gives. Detects changed files.
    pub version: String,
}

pub struct Dav {
    client: Client,
    base: Url,
    user: String,
    password: String,
}

/// Readable reason for a failed request. No raw errors on the main screens.
fn friendly(error: &reqwest::Error) -> String {
    let mut chain = format!("{error}");
    let mut source = std::error::Error::source(error);
    while let Some(s) = source {
        chain.push(' ');
        chain.push_str(&s.to_string());
        source = s.source();
    }
    let lower = chain.to_lowercase();
    if lower.contains("certificate") || lower.contains("unknownissuer") || lower.contains("invalid peer") {
        "Certyfikat serwera nie jest zaufany. Mytify nie łączy się z serwerem bez ważnego certyfikatu HTTPS.".into()
    } else if error.is_timeout() {
        "Serwer nie odpowiada.".into()
    } else if lower.contains("dns") || lower.contains("resolve") || lower.contains("lookup") {
        "Nie znaleziono serwera. Sprawdź adres.".into()
    } else if error.is_connect() {
        "Serwer jest nieosiągalny.".into()
    } else if error.is_redirect() {
        "Serwer przekierowuje na inny adres. Wpisz docelowy adres serwera.".into()
    } else {
        "Połączenie z serwerem nie powiodło się.".into()
    }
}

fn status_message(status: StatusCode) -> String {
    match status.as_u16() {
        401 => "Nieprawidłowy użytkownik lub hasło.".into(),
        403 => "Brak dostępu do tego folderu.".into(),
        404 => "Folder lub plik nie istnieje.".into(),
        405 | 501 => "Pod tym adresem nie ma serwera WebDAV.".into(),
        301 | 302 | 303 | 307 | 308 => "Serwer przekierowuje na inny adres. Wpisz docelowy adres serwera.".into(),
        507 => "Serwer zgłasza brak miejsca.".into(),
        s if s >= 500 => "Błąd serwera. Spróbuj później.".into(),
        s => format!("Serwer odrzucił żądanie (HTTP {s})."),
    }
}

/// Checks and normalises the server address: HTTPS only, no credentials in the URL.
pub fn clean_url(raw: &str) -> Result<Url> {
    let raw = raw.trim();
    if raw.is_empty() {
        bail!("Podaj adres serwera WebDAV.");
    }
    let with_scheme = if raw.contains("://") { raw.to_string() } else { format!("https://{raw}") };
    let mut url = Url::parse(&with_scheme).map_err(|_| anyhow!("Adres serwera jest nieprawidłowy."))?;
    if url.scheme() != "https" {
        bail!("WebDAV wymaga połączenia HTTPS (adres zaczyna się od https://).");
    }
    if url.host_str().is_none_or(str::is_empty) {
        bail!("Adres serwera jest nieprawidłowy.");
    }
    if !url.username().is_empty() || url.password().is_some() {
        bail!("Nie wpisuj loginu ani hasła w adresie. Użyj pól poniżej.");
    }
    url.set_query(None);
    url.set_fragment(None);
    if !url.path().ends_with('/') {
        let path = format!("{}/", url.path());
        url.set_path(&path);
    }
    Ok(url)
}

/// Percent-decoded last segment, for names shown in the UI.
pub fn decoded_name(href: &str) -> String {
    let last = href.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    url::form_urlencoded::parse(format!("n={}", last.replace('+', "%2B")).as_bytes())
        .next()
        .map(|(_, v)| v.into_owned())
        .unwrap_or_else(|| last.to_string())
}

impl Dav {
    pub fn new(base: Url, user: &str, password: &str) -> Result<Self> {
        let origin = base.origin();
        let client = Client::builder()
            .https_only(true)
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(60))
            // Same-origin redirects only: credentials never reach another host.
            .redirect(redirect::Policy::custom(move |attempt| {
                if attempt.previous().len() >= 5 || attempt.url().origin() != origin {
                    attempt.stop()
                } else {
                    attempt.follow()
                }
            }))
            .user_agent("Mytify")
            .build()?;
        Ok(Self {
            client,
            base,
            user: user.to_string(),
            password: password.to_string(),
        })
    }

    pub fn base(&self) -> &Url {
        &self.base
    }

    fn send(&self, method: Method, url: &Url, prepare: impl FnOnce(reqwest::blocking::RequestBuilder) -> reqwest::blocking::RequestBuilder) -> Result<Response> {
        if url.origin() != self.base.origin() {
            bail!("Serwer wskazał plik na innym serwerze.");
        }
        let mut request = self.client.request(method, url.clone());
        if !self.user.is_empty() {
            request = request.basic_auth(&self.user, Some(&self.password));
        }
        prepare(request).send().map_err(|e| anyhow!(friendly(&e)))
    }

    /// Absolute URL of a server path. Refuses anything outside the chosen folder.
    pub fn url(&self, href: &str) -> Result<Url> {
        let url = self.base.join(href).map_err(|_| anyhow!("Nieprawidłowa ścieżka na serwerze."))?;
        if url.origin() != self.base.origin() || !url.path().starts_with(self.base.path()) {
            bail!("Ścieżka wychodzi poza wybrany folder.");
        }
        Ok(url)
    }

    /// One folder level (PROPFIND Depth 1). Deep listings are often disabled on servers.
    pub fn list(&self, folder: &Url) -> Result<Vec<Entry>> {
        let body = r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>"#;
        let response = self.send(Method::from_bytes(b"PROPFIND")?, folder, |r| {
            r.header("Depth", "1")
                .header("Content-Type", "application/xml; charset=utf-8")
                .body(body)
        })?;
        let status = response.status();
        if status != StatusCode::MULTI_STATUS {
            bail!(status_message(status));
        }
        let text = response.text()?;
        parse_multistatus(&text, folder)
    }

    /// Bytes [start, start+len). Returns the data and whether the server honoured the range.
    pub fn read(&self, url: &Url, start: u64, len: u64, version: &str) -> Result<(Response, bool)> {
        let response = self.send(Method::GET, url, |r| {
            r.header(RANGE, format!("bytes={}-{}", start, start + len.max(1) - 1))
        })?;
        let status = response.status();
        if !(status == StatusCode::PARTIAL_CONTENT || status == StatusCode::OK) {
            bail!(status_message(status));
        }
        check_version(&response, version)?;
        let ranged = status == StatusCode::PARTIAL_CONTENT
            && response
                .headers()
                .get(CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .is_some_and(|v| v.starts_with(&format!("bytes {start}-")));
        Ok((response, ranged))
    }

    /// Whole file as a stream (downloads, servers without Range).
    pub fn get(&self, url: &Url, version: &str) -> Result<Response> {
        let response = self.send(Method::GET, url, |r| r)?;
        if !response.status().is_success() {
            bail!(status_message(response.status()));
        }
        check_version(&response, version)?;
        Ok(response)
    }

    pub fn supports_ranges(response: &Response) -> bool {
        response.headers().get(ACCEPT_RANGES) == Some(&HeaderValue::from_static("bytes"))
    }
}

/// A file that changed on the server since the scan must not be mixed with old data.
fn check_version(response: &Response, version: &str) -> Result<()> {
    if let Some(etag) = response.headers().get(ETAG).and_then(|v| v.to_str().ok()) {
        if version.starts_with('"') || version.starts_with("W/") {
            if strip_weak(etag) != strip_weak(version) {
                bail!("Plik na serwerze zmienił się. Wykonaj ponowny skan źródła.");
            }
        }
    }
    Ok(())
}

fn strip_weak(tag: &str) -> &str {
    tag.trim_start_matches("W/")
}

pub fn parse_multistatus(text: &str, folder: &Url) -> Result<Vec<Entry>> {
    let doc = roxmltree::Document::parse(text).map_err(|_| anyhow!("Serwer zwrócił nieprawidłową odpowiedź WebDAV."))?;
    const DAV: &str = "DAV:";
    let mut out = Vec::new();
    for response in doc.descendants().filter(|n| n.has_tag_name((DAV, "response"))) {
        let Some(href) = response
            .children()
            .find(|n| n.has_tag_name((DAV, "href")))
            .and_then(|n| n.text())
        else {
            continue;
        };
        let Ok(url) = folder.join(href.trim()) else { continue };
        // Only entries inside the listed folder, on the same server.
        if url.origin() != folder.origin() || !url.path().starts_with(folder.path()) {
            continue;
        }
        if url.path().trim_end_matches('/') == folder.path().trim_end_matches('/') {
            continue;
        }
        let ok_prop = response
            .children()
            .filter(|n| n.has_tag_name((DAV, "propstat")))
            .find(|p| {
                p.children()
                    .find(|n| n.has_tag_name((DAV, "status")))
                    .and_then(|n| n.text())
                    .is_none_or(|s| s.contains(" 200"))
            })
            .and_then(|p| p.children().find(|n| n.has_tag_name((DAV, "prop"))));
        let Some(prop) = ok_prop else { continue };
        let text = |name: &str| {
            prop.children()
                .find(|n| n.has_tag_name((DAV, name)))
                .and_then(|n| n.text())
                .map(|s| s.trim().to_string())
                .unwrap_or_default()
        };
        let dir = prop
            .children()
            .find(|n| n.has_tag_name((DAV, "resourcetype")))
            .is_some_and(|r| r.children().any(|n| n.has_tag_name((DAV, "collection"))));
        let etag = text("getetag");
        let version = if etag.is_empty() { text("getlastmodified") } else { etag };
        out.push(Entry {
            name: decoded_name(url.path()),
            href: url.path().to_string(),
            dir,
            size: text("getcontentlength").parse().unwrap_or(0),
            version,
        });
    }
    Ok(out)
}

/// Read + Seek over HTTP ranges with read-ahead. When the server ignores Range, the
/// file is downloaded once to a private cache file (a slower, controlled fallback).
pub struct RemoteReader {
    dav: Arc<Dav>,
    url: Url,
    size: u64,
    version: String,
    pos: u64,
    block: Vec<u8>,
    block_start: u64,
    whole: Option<File>,
    cache: PathBuf,
}

const BLOCK: u64 = 512 * 1024;

impl RemoteReader {
    pub fn new(dav: Arc<Dav>, url: Url, size: u64, version: String, cache: PathBuf) -> Self {
        Self {
            dav,
            url,
            size,
            version,
            pos: 0,
            block: Vec::new(),
            block_start: 0,
            whole: None,
            cache,
        }
    }

    pub fn len(&self) -> u64 {
        self.size
    }

    pub fn is_empty(&self) -> bool {
        self.size == 0
    }

    fn fill(&mut self) -> io::Result<()> {
        let want = BLOCK.min(self.size - self.pos);
        let to_io = |e: anyhow::Error| io::Error::other(e.to_string());
        let (mut response, ranged) = self.dav.read(&self.url, self.pos, want, &self.version).map_err(to_io)?;
        if ranged {
            let mut data = Vec::with_capacity(want as usize);
            response.read_to_end(&mut data)?;
            self.block = data;
            self.block_start = self.pos;
            return Ok(());
        }
        // No Range support: keep one complete copy instead of re-downloading on every seek.
        std::fs::create_dir_all(self.cache.parent().unwrap_or(&self.cache))?;
        let partial = self.cache.with_extension("partial");
        let mut out = File::create(&partial)?;
        let copied = io::copy(&mut response, &mut out)?;
        out.sync_all()?;
        drop(out);
        if copied != self.size {
            let _ = std::fs::remove_file(&partial);
            return Err(io::Error::other("Plik na serwerze ma inny rozmiar niż przy skanowaniu."));
        }
        std::fs::rename(&partial, &self.cache)?;
        self.whole = Some(File::open(&self.cache)?);
        Ok(())
    }
}

impl Drop for RemoteReader {
    fn drop(&mut self) {
        if self.whole.take().is_some() {
            let _ = std::fs::remove_file(&self.cache);
        }
    }
}

impl Read for RemoteReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.size || buf.is_empty() {
            return Ok(0);
        }
        if let Some(file) = self.whole.as_mut() {
            file.seek(SeekFrom::Start(self.pos))?;
            let n = file.read(buf)?;
            self.pos += n as u64;
            return Ok(n);
        }
        let inside = self.pos >= self.block_start && self.pos < self.block_start + self.block.len() as u64;
        if !inside {
            self.fill()?;
            if let Some(file) = self.whole.as_mut() {
                file.seek(SeekFrom::Start(self.pos))?;
                let n = file.read(buf)?;
                self.pos += n as u64;
                return Ok(n);
            }
            if self.block.is_empty() {
                return Ok(0);
            }
        }
        let offset = (self.pos - self.block_start) as usize;
        let n = buf.len().min(self.block.len() - offset);
        buf[..n].copy_from_slice(&self.block[offset..offset + n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for RemoteReader {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let next = match to {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(n) => self.size as i128 + n as i128,
            SeekFrom::Current(n) => self.pos as i128 + n as i128,
        };
        if next < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "seek before start"));
        }
        self.pos = (next as u64).min(self.size);
        Ok(self.pos)
    }
}

impl symphonia::core::io::MediaSource for RemoteReader {
    fn is_seekable(&self) -> bool {
        true
    }
    fn byte_len(&self) -> Option<u64> {
        Some(self.size)
    }
}

fn clients() -> &'static Mutex<HashMap<String, Arc<Dav>>> {
    static CLIENTS: OnceLock<Mutex<HashMap<String, Arc<Dav>>>> = OnceLock::new();
    CLIENTS.get_or_init(Default::default)
}

/// Clients per source, so a listing or a playback does not set up TLS from scratch.
pub fn client(id: &str, make: impl FnOnce() -> Result<Dav>) -> Result<Arc<Dav>> {
    if let Some(c) = clients().lock().unwrap().get(id) {
        return Ok(c.clone());
    }
    let c = Arc::new(make()?);
    clients().lock().unwrap().insert(id.to_string(), c.clone());
    Ok(c)
}

/// After editing or removing a source the next use logs in with the new settings.
pub fn forget_client(id: &str) {
    clients().lock().unwrap().remove(id);
}

/// Writes a whole remote file to `target` (via a temporary file) and returns its size.
pub fn download(dav: &Dav, url: &Url, version: &str, target: &std::path::Path) -> Result<u64> {
    let mut response = dav.get(url, version)?;
    let partial = target.with_extension("partial");
    let mut out = File::create(&partial)?;
    let n = io::copy(&mut response, &mut out)?;
    out.flush()?;
    out.sync_all()?;
    drop(out);
    std::fs::rename(&partial, target)?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_urls() {
        assert_eq!(clean_url("nas.example.com:5006/music").unwrap().as_str(), "https://nas.example.com:5006/music/");
        assert!(clean_url("http://nas/music").is_err());
        assert!(clean_url("https://mat:haslo@nas/music").is_err());
        assert_eq!(clean_url("https://nas/Muzyka Polska/").unwrap().path(), "/Muzyka%20Polska/");
    }

    #[test]
    fn parses_listing_with_polish_names_and_ignores_outsiders() {
        let folder = Url::parse("https://nas/dav/music/").unwrap();
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/dav/music/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/dav/music/Za%C5%BC%C3%B3%C5%82%C4%87%20g%C4%99%C5%9Bl%C4%85/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>https://nas/dav/music/01%20Utw%C3%B3r.flac</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength><d:getetag>"abc"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>https://evil.example/x.flac</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/dav/other/x.flac</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>"#;
        let entries = parse_multistatus(xml, &folder).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries[0].dir);
        assert_eq!(entries[0].name, "Zażółć gęślą");
        assert_eq!(entries[1].name, "01 Utwór.flac");
        assert_eq!(entries[1].size, 1234);
        assert_eq!(entries[1].version, "\"abc\"");
        assert_eq!(entries[1].href, "/dav/music/01%20Utw%C3%B3r.flac");
    }
}
