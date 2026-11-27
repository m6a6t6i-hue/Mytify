//! Album covers from public store catalogues (iTunes Search, Deezer), used when the
//! Cover Art Archive has no image or does not answer. Only these hosts and their image
//! servers are contacted; nothing but the artist and album name is sent.
use serde_json::Value;
use std::{io::Read, time::Duration};
use url::Url;

const LIMIT: u64 = 8 * 1024 * 1024;

fn client() -> Option<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .user_agent("Mytify (local music library)")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .ok()
}

fn get(client: &reqwest::blocking::Client, url: &Url) -> Option<Vec<u8>> {
    let r = client.get(url.clone()).send().ok()?;
    if !r.status().is_success() || r.content_length().is_some_and(|n| n > LIMIT) {
        return None;
    }
    let mut bytes = Vec::new();
    r.take(LIMIT + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= LIMIT).then_some(bytes)
}

fn image_host(url: &Url) -> bool {
    let host = url.host_str().unwrap_or("");
    url.scheme() == "https" && (host.ends_with(".mzstatic.com") || host.ends_with(".dzcdn.net"))
}

/// Lower-case letters and digits only, for comparing names across catalogues.
pub fn key(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// Album title without edition notes ("(Deluxe Edition)", "- Remastered 2011").
pub fn plain_title(title: &str) -> String {
    const NOTES: [&str; 8] = ["deluxe", "edition", "remaster", "expanded", "anniversary", "bonus", "version", "edycja"];
    let mut t = title.to_string();
    if let Some(open) = t.rfind(['(', '[']) {
        if NOTES.iter().any(|n| t[open..].to_lowercase().contains(n)) {
            t.truncate(open);
        }
    }
    if let Some(dash) = t.rfind(" - ") {
        if NOTES.iter().any(|n| t[dash..].to_lowercase().contains(n)) {
            t.truncate(dash);
        }
    }
    let t = t.trim();
    if t.is_empty() { title.trim().to_string() } else { t.to_string() }
}

/// Whether a catalogue entry is this album: same artist, same title (editions aside).
fn same(artist: &str, album: &str, their_artist: &str, their_album: &str) -> bool {
    let (a, b) = (key(artist), key(their_artist));
    let artist_ok = !a.is_empty() && (b.contains(&a) || a.contains(&b));
    let (x, y) = (key(&plain_title(album)), key(&plain_title(their_album)));
    artist_ok && !x.is_empty() && (x == y || y.starts_with(&x) || x.starts_with(&y))
}

/// Picks the artwork address from an iTunes Search answer, enlarged to 1200 px.
pub fn itunes_pick(v: &Value, artist: &str, album: &str) -> Option<Url> {
    let hit = v["results"].as_array()?.iter().find(|r| {
        same(artist, album, r["artistName"].as_str().unwrap_or(""), r["collectionName"].as_str().unwrap_or(""))
    })?;
    let small = hit["artworkUrl100"].as_str()?;
    let url = Url::parse(&small.replace("100x100bb", "1200x1200bb")).ok()?;
    image_host(&url).then_some(url)
}

/// Picks the largest cover from a Deezer album search answer.
pub fn deezer_pick(v: &Value, artist: &str, album: &str) -> Option<Url> {
    let hit = v["data"].as_array()?.iter().find(|r| {
        same(artist, album, r["artist"]["name"].as_str().unwrap_or(""), r["title"].as_str().unwrap_or(""))
    })?;
    let url = Url::parse(hit["cover_xl"].as_str().or(hit["cover_big"].as_str())?).ok()?;
    image_host(&url).then_some(url)
}

/// Cover image bytes for an album, from iTunes and then Deezer.
pub fn find(artist: &str, album: &str) -> Option<Vec<u8>> {
    if artist.trim().is_empty() || album.trim().is_empty() {
        return None;
    }
    let client = client()?;
    let term = format!("{} {}", artist.trim(), plain_title(album));
    let mut itunes = Url::parse("https://itunes.apple.com/search").ok()?;
    itunes.query_pairs_mut().append_pair("term", &term).append_pair("entity", "album").append_pair("limit", "15");
    if let Some(url) = get(&client, &itunes).and_then(|b| serde_json::from_slice::<Value>(&b).ok()).and_then(|v| itunes_pick(&v, artist, album)) {
        if let Some(bytes) = get(&client, &url) {
            return Some(bytes);
        }
    }
    let mut deezer = Url::parse("https://api.deezer.com/search/album").ok()?;
    deezer.query_pairs_mut().append_pair("q", &term).append_pair("limit", "15");
    let url = get(&client, &deezer).and_then(|b| serde_json::from_slice::<Value>(&b).ok()).and_then(|v| deezer_pick(&v, artist, album))?;
    get(&client, &url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn titles_and_matching() {
        assert_eq!(plain_title("Queen of Time (Deluxe Edition)"), "Queen of Time");
        assert_eq!(plain_title("Abbey Road - Remastered 2019"), "Abbey Road");
        assert_eq!(plain_title("Help!"), "Help!");
        let itunes = json!({"results": [
            {"artistName": "Other", "collectionName": "Queen of Time", "artworkUrl100": "https://is1-ssl.mzstatic.com/x/100x100bb.jpg"},
            {"artistName": "Amorphis", "collectionName": "Queen of Time (Deluxe Edition)", "artworkUrl100": "https://is1-ssl.mzstatic.com/a/100x100bb.jpg"}
        ]});
        assert_eq!(itunes_pick(&itunes, "Amorphis", "Queen of Time").unwrap().as_str(), "https://is1-ssl.mzstatic.com/a/1200x1200bb.jpg");
        let evil = json!({"results": [{"artistName": "Amorphis", "collectionName": "Queen of Time", "artworkUrl100": "https://evil.example/100x100bb.jpg"}]});
        assert!(itunes_pick(&evil, "Amorphis", "Queen of Time").is_none());
        let deezer = json!({"data": [{"title": "Queen of Time", "artist": {"name": "Amorphis"}, "cover_xl": "https://cdn-images.dzcdn.net/images/cover/x/1000x1000.jpg"}]});
        assert!(deezer_pick(&deezer, "Amorphis", "Queen of Time (Deluxe Edition)").is_some());
        assert!(deezer_pick(&deezer, "Metallica", "Queen of Time").is_none());
    }
}
