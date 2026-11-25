//! OpenSubsonic / Subsonic API client (Navidrome is the main target, nothing here depends
//! on it). The library comes from the server's own index, not from rescanning its folders.

use anyhow::{anyhow, bail, Result};
use md5::{Digest, Md5};
use reqwest::{
    blocking::{Client, Response},
    header::{CONTENT_RANGE, RANGE},
    redirect, StatusCode,
};
use serde_json::Value;
use std::{sync::Arc, time::Duration};
use url::Url;

#[derive(Clone, Debug, Default)]
pub struct Song {
    pub id: String,
    pub title: String,
    pub album: String,
    pub artist: String,
    pub album_artist: String,
    pub track: u32,
    pub disc: u32,
    pub duration_ms: i64,
    pub size: i64,
    pub suffix: String,
    pub bit_rate: u32,
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub cover: Option<String>,
    pub starred: bool,
    pub path: String,
}

impl Song {
    pub fn parse(v: &Value) -> Option<Song> {
        let s = |k: &str| v[k].as_str().unwrap_or("").trim().to_string();
        let n = |k: &str| v[k].as_u64().unwrap_or(0);
        let id = s("id");
        if id.is_empty() || v["isDir"].as_bool() == Some(true) || v["isVideo"].as_bool() == Some(true) {
            return None;
        }
        // OpenSubsonic: displayAlbumArtist / albumArtists; classic servers: none.
        let album_artist = match s("displayAlbumArtist") {
            a if !a.is_empty() => a,
            _ => v["albumArtists"]
                .as_array()
                .and_then(|a| a.first())
                .and_then(|a| a["name"].as_str())
                .unwrap_or("")
                .to_string(),
        };
        Some(Song {
            title: s("title"),
            album: s("album"),
            artist: s("artist"),
            album_artist,
            track: n("track") as u32,
            disc: n("discNumber") as u32,
            duration_ms: n("duration") as i64 * 1000,
            size: n("size") as i64,
            suffix: s("suffix").to_lowercase(),
            bit_rate: n("bitRate") as u32,
            sample_rate: n("samplingRate") as u32,
            bit_depth: n("bitDepth").min(64) as u8,
            cover: Some(s("coverArt")).filter(|c| !c.is_empty()),
            starred: v.get("starred").is_some_and(|x| !x.is_null()),
            path: s("path"),
            id,
        })
    }

    /// Format label from what the server reports. No invented quality data.
    pub fn format(&self) -> &'static str {
        match self.suffix.as_str() {
            "flac" => "FLAC",
            "mp3" => "MP3",
            "m4a" | "mp4" | "alac" => "M4A",
            "aac" => "AAC",
            "wav" => "WAV",
            "aif" | "aiff" => "AIFF",
            "opus" => "OPUS",
            "ogg" | "oga" => "OGG",
            _ => "AUDIO",
        }
    }

    /// Lossy formats have no PCM bit depth, whatever a server reports.
    pub fn bit_depth(&self) -> u8 {
        match self.suffix.as_str() {
            "flac" | "wav" | "aif" | "aiff" | "alac" | "m4a" | "ape" | "wv" => self.bit_depth,
            _ => 0,
        }
    }

    /// What decides whether the server's file changed (no ETag in the API).
    pub fn version(&self) -> String {
        format!("{}|{}|{}", self.size, self.duration_ms, self.suffix)
    }

    pub fn file_name(&self) -> String {
        let from_path = self.path.rsplit('/').next().unwrap_or("").to_string();
        if !from_path.is_empty() {
            from_path
        } else if self.suffix.is_empty() {
            self.title.clone()
        } else {
            format!("{}.{}", self.title, self.suffix)
        }
    }
}

#[derive(Clone, Debug)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub changed: String,
    pub owner: String,
    pub songs: Vec<Song>,
}

pub struct Subsonic {
    client: Client,
    base: Url,
    user: String,
    password: String,
}

pub fn clean_url(raw: &str) -> Result<Url> {
    let raw = raw.trim();
    if raw.is_empty() {
        bail!("Podaj adres serwera.");
    }
    let with_scheme = if raw.contains("://") { raw.to_string() } else { format!("https://{raw}") };
    let mut url = Url::parse(&with_scheme).map_err(|_| anyhow!("Adres serwera jest nieprawidłowy."))?;
    if !matches!(url.scheme(), "https" | "http") || url.host_str().is_none_or(str::is_empty) {
        bail!("Adres serwera jest nieprawidłowy.");
    }
    if !url.username().is_empty() || url.password().is_some() {
        bail!("Nie wpisuj loginu ani hasła w adresie. Użyj pól poniżej.");
    }
    url.set_query(None);
    url.set_fragment(None);
    // A pasted ".../rest/" or ".../app/" still means the server root.
    let mut path = url.path().trim_end_matches('/').to_string();
    for suffix in ["/rest", "/app"] {
        if path.ends_with(suffix) {
            path.truncate(path.len() - suffix.len());
        }
    }
    url.set_path(&format!("{path}/"));
    Ok(url)
}

fn api_error(code: i64, message: &str) -> String {
    match code {
        40 => "Nieprawidłowy użytkownik lub hasło.".into(),
        41 => "Serwer nie obsługuje logowania tokenem. Połącz się przez HTTPS.".into(),
        50 => "To konto nie ma uprawnień do tej operacji.".into(),
        70 => "Nie znaleziono na serwerze.".into(),
        20 | 30 => "Ta wersja serwera nie jest obsługiwana.".into(),
        _ if message.is_empty() => "Serwer odrzucił żądanie.".into(),
        _ => format!("Serwer odrzucił żądanie: {}", message.chars().take(120).collect::<String>()),
    }
}

fn http_error(e: &reqwest::Error) -> String {
    let mut chain = format!("{e}");
    let mut source = std::error::Error::source(e);
    while let Some(s) = source {
        chain.push(' ');
        chain.push_str(&s.to_string());
        source = s.source();
    }
    let lower = chain.to_lowercase();
    if lower.contains("certificate") || lower.contains("unknownissuer") {
        "Certyfikat serwera nie jest zaufany. Mytify nie łączy się z serwerem bez ważnego certyfikatu HTTPS.".into()
    } else if e.is_timeout() {
        "Serwer nie odpowiada.".into()
    } else if lower.contains("dns") || lower.contains("resolve") || lower.contains("lookup") {
        "Nie znaleziono serwera. Sprawdź adres.".into()
    } else if e.is_connect() {
        "Serwer jest nieosiągalny.".into()
    } else {
        "Połączenie z serwerem nie powiodło się.".into()
    }
}

impl Subsonic {
    pub fn new(base: Url, user: &str, password: &str) -> Result<Self> {
        let origin = base.origin();
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(90))
            // Same-origin redirects only: the login never reaches another host.
            .redirect(redirect::Policy::custom(move |a| {
                if a.previous().len() >= 5 || a.url().origin() != origin {
                    a.stop()
                } else {
                    a.follow()
                }
            }))
            .user_agent("Mytify")
            .build()?;
        Ok(Self {
            client,
            base,
            user: user.into(),
            password: password.into(),
        })
    }

    pub fn base(&self) -> &Url {
        &self.base
    }

    /// Request URL with token authentication (md5(password + salt)), never the password.
    fn url(&self, endpoint: &str, extra: &[(&str, String)]) -> Result<Url> {
        let mut url = self.base.join(&format!("rest/{endpoint}"))?;
        let salt = crate::catalog::hex(crate::catalog::getrandom_bytes()?);
        let token = crate::catalog::hex(Md5::digest(format!("{}{salt}", self.password).as_bytes()));
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("u", &self.user)
                .append_pair("t", &token)
                .append_pair("s", &salt)
                .append_pair("v", "1.16.1")
                .append_pair("c", "Mytify")
                .append_pair("f", "json");
            for (k, v) in extra {
                q.append_pair(k, v);
            }
        }
        Ok(url)
    }

    pub fn call(&self, endpoint: &str, extra: &[(&str, String)]) -> Result<Value> {
        let response = self
            .client
            .get(self.url(endpoint, extra)?)
            .send()
            .map_err(|e| anyhow!(http_error(&e)))?;
        let status = response.status();
        if status == StatusCode::UNAUTHORIZED {
            bail!("Nieprawidłowy użytkownik lub hasło.");
        }
        if !status.is_success() {
            bail!(if status == StatusCode::NOT_FOUND {
                "Pod tym adresem nie ma serwera Subsonic.".to_string()
            } else {
                format!("Serwer odrzucił żądanie (HTTP {}).", status.as_u16())
            });
        }
        let value: Value = response
            .json()
            .map_err(|_| anyhow!("Pod tym adresem nie ma serwera Subsonic."))?;
        let r = &value["subsonic-response"];
        if r.is_null() {
            bail!("Pod tym adresem nie ma serwera Subsonic.");
        }
        if r["status"] != "ok" {
            bail!(api_error(
                r["error"]["code"].as_i64().unwrap_or(0),
                r["error"]["message"].as_str().unwrap_or("")
            ));
        }
        Ok(r.clone())
    }

    /// Logs in. Returns a readable server description and the OpenSubsonic extensions.
    pub fn ping(&self) -> Result<(String, Vec<String>)> {
        let r = self.call("ping", &[])?;
        let name = match (r["type"].as_str(), r["serverVersion"].as_str()) {
            (Some(t), Some(v)) => format!("{t} {v}"),
            (Some(t), None) => t.to_string(),
            _ => format!("Subsonic API {}", r["version"].as_str().unwrap_or("")),
        };
        let extensions = if r["openSubsonic"].as_bool() == Some(true) {
            self.call("getOpenSubsonicExtensions", &[])
                .ok()
                .and_then(|v| v["openSubsonicExtensions"].as_array().cloned())
                .unwrap_or_default()
                .iter()
                .filter_map(|e| e["name"].as_str().map(str::to_owned))
                .collect()
        } else {
            vec![]
        };
        Ok((name, extensions))
    }

    /// One page of all songs (search3 with an empty query, meant for offline sync).
    pub fn songs(&self, offset: usize, count: usize) -> Result<Vec<Song>> {
        let r = self.call(
            "search3",
            &[
                ("query", String::new()),
                ("artistCount", "0".into()),
                ("albumCount", "0".into()),
                ("songCount", count.to_string()),
                ("songOffset", offset.to_string()),
            ],
        )?;
        Ok(r["searchResult3"]["song"]
            .as_array()
            .map(|a| a.iter().filter_map(Song::parse).collect())
            .unwrap_or_default())
    }

    /// Fallback for servers whose search3 does not list everything: album by album.
    pub fn songs_by_albums(&self, mut each: impl FnMut(Vec<Song>) -> Result<()>) -> Result<()> {
        let mut offset = 0;
        loop {
            let r = self.call(
                "getAlbumList2",
                &[("type", "alphabeticalByName".into()), ("size", "500".into()), ("offset", offset.to_string())],
            )?;
            let albums = r["albumList2"]["album"].as_array().cloned().unwrap_or_default();
            if albums.is_empty() {
                return Ok(());
            }
            for a in &albums {
                if let Some(id) = a["id"].as_str() {
                    let album = self.call("getAlbum", &[("id", id.into())])?;
                    each(album["album"]["song"].as_array().map(|s| s.iter().filter_map(Song::parse).collect()).unwrap_or_default())?;
                }
            }
            offset += albums.len();
        }
    }

    pub fn cover(&self, id: &str, size: u32) -> Result<Vec<u8>> {
        let response = self
            .client
            .get(self.url("getCoverArt", &[("id", id.into()), ("size", size.to_string())])?)
            .send()
            .map_err(|e| anyhow!(http_error(&e)))?;
        let kind = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        if !response.status().is_success() || !kind.starts_with("image/") {
            bail!("Brak okładki.");
        }
        let bytes = response.bytes().map_err(|e| anyhow!(http_error(&e)))?;
        if bytes.len() > 8 * 1024 * 1024 {
            bail!("Okładka jest za duża.");
        }
        Ok(bytes.to_vec())
    }

    pub fn star(&self, id: &str, starred: bool) -> Result<()> {
        self.call(if starred { "star" } else { "unstar" }, &[("id", id.into())]).map(|_| ())
    }

    pub fn scrobble(&self, id: &str, time_ms: i64) -> Result<()> {
        self.call("scrobble", &[("id", id.into()), ("time", time_ms.to_string()), ("submission", "true".into())])
            .map(|_| ())
    }

    pub fn playlists(&self) -> Result<Vec<Playlist>> {
        let r = self.call("getPlaylists", &[])?;
        let mut out = Vec::new();
        for p in r["playlists"]["playlist"].as_array().cloned().unwrap_or_default() {
            let Some(id) = p["id"].as_str() else { continue };
            let full = self.call("getPlaylist", &[("id", id.into())])?;
            let full = &full["playlist"];
            out.push(Playlist {
                id: id.into(),
                name: full["name"].as_str().unwrap_or("Playlista").into(),
                changed: full["changed"].as_str().unwrap_or("").into(),
                owner: full["owner"].as_str().unwrap_or("").into(),
                songs: full["entry"].as_array().map(|a| a.iter().filter_map(Song::parse).collect()).unwrap_or_default(),
            });
        }
        Ok(out)
    }

    /// Creates a playlist, or replaces the songs of an existing one (Subsonic createPlaylist).
    pub fn save_playlist(&self, id: Option<&str>, name: &str, songs: &[String]) -> Result<String> {
        let mut extra: Vec<(&str, String)> = match id {
            Some(id) => vec![("playlistId", id.into())],
            None => vec![("name", name.into())],
        };
        extra.extend(songs.iter().map(|s| ("songId", s.clone())));
        let r = self.call("createPlaylist", &extra)?;
        if let Some(id) = id {
            if !name.is_empty() {
                self.call("updatePlaylist", &[("playlistId", id.into()), ("name", name.into())])?;
            }
            return Ok(id.into());
        }
        r["playlist"]["id"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| anyhow!("Serwer nie zwrócił playlisty."))
    }

    /// Range read of a song: original file, or the server's conversion when chosen.
    pub fn stream(&self, id: &str, start: u64, len: u64, transcode: Option<&(String, u32)>) -> Result<(Response, bool)> {
        let mut extra = vec![("id", id.to_string())];
        match transcode {
            Some((format, bitrate)) => {
                extra.push(("format", format.clone()));
                extra.push(("maxBitRate", bitrate.to_string()));
            }
            None => extra.push(("format", "raw".into())),
        }
        let response = self
            .client
            .get(self.url("stream", &extra)?)
            .header(RANGE, format!("bytes={}-{}", start, start + len.max(1) - 1))
            .send()
            .map_err(|e| anyhow!(http_error(&e)))?;
        let status = response.status();
        if !(status == StatusCode::OK || status == StatusCode::PARTIAL_CONTENT) {
            bail!("Serwer nie udostępnił utworu (HTTP {}).", status.as_u16());
        }
        if response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|t| t.contains("json") || t.contains("xml"))
        {
            bail!("Serwer nie udostępnił utworu.");
        }
        let ranged = status == StatusCode::PARTIAL_CONTENT
            && response
                .headers()
                .get(CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .is_some_and(|v| v.starts_with(&format!("bytes {start}-")));
        Ok((response, ranged))
    }

    /// Whole original file (download API), for offline copies.
    pub fn download(&self, id: &str) -> Result<Response> {
        let response = self
            .client
            .get(self.url("download", &[("id", id.into())])?)
            .send()
            .map_err(|e| anyhow!(http_error(&e)))?;
        if !response.status().is_success() {
            bail!("Serwer nie udostępnił pliku (HTTP {}).", response.status().as_u16());
        }
        Ok(response)
    }
}

/// One song as a seekable source for the player.
pub struct SongStream {
    pub client: Arc<Subsonic>,
    pub id: String,
    pub transcode: Option<(String, u32)>,
}

impl crate::webdav::RangeSource for SongStream {
    fn read_range(&self, start: u64, len: u64) -> Result<(Response, bool)> {
        self.client.stream(&self.id, start, len, self.transcode.as_ref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cleans_server_addresses() {
        assert_eq!(clean_url("music.example.com").unwrap().as_str(), "https://music.example.com/");
        assert_eq!(clean_url("http://192.168.1.5:4533/app/").unwrap().as_str(), "http://192.168.1.5:4533/");
        assert_eq!(clean_url("https://nas/navidrome/rest").unwrap().as_str(), "https://nas/navidrome/");
        assert!(clean_url("ftp://nas").is_err());
        assert!(clean_url("https://u:p@nas").is_err());
    }

    #[test]
    fn parses_songs_without_inventing_quality() {
        let mp3 = Song::parse(&json!({"id":"1","title":"Światło","suffix":"mp3","bitDepth":16,"samplingRate":44100,"duration":200,"size":123,"starred":"2024-01-01T00:00:00Z","path":"A/B/01 Światło.mp3"})).unwrap();
        assert_eq!(mp3.bit_depth(), 0);
        assert!(mp3.starred);
        assert_eq!(mp3.duration_ms, 200_000);
        assert_eq!(mp3.file_name(), "01 Światło.mp3");
        let flac = Song::parse(&json!({"id":"2","title":"X","suffix":"flac","bitDepth":24,"displayAlbumArtist":"Ktoś"})).unwrap();
        assert_eq!(flac.bit_depth(), 24);
        assert_eq!(flac.album_artist, "Ktoś");
        assert!(!flac.starred);
        assert!(Song::parse(&json!({"id":"3","isDir":true})).is_none());
    }
}
