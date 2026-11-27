//! Album description from a Spotify link, for recordings made from an app: only what
//! the public pages show anyone without an account (name, artist, year, tracks and
//! their lengths, cover). No API key, no sign-in. The app then looks the album up in
//! MusicBrainz for full tags; the lengths place the cuts between tracks.
use anyhow::{anyhow, bail, Result};
use serde::Serialize;
use serde_json::Value;
use std::time::Duration;

#[derive(Debug, Default, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Song {
    pub title: String,
    pub artist: String,
    pub duration_ms: u64,
}

#[derive(Debug, Default, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    /// "1997" or "1997-05-21".
    pub date: String,
    /// From the album page, also when the track list could not be read.
    pub track_count: usize,
    pub tracks: Vec<Song>,
    #[serde(skip)]
    pub cover_url: Option<String>,
}

/// Album id from an album link (open.spotify.com/album/…, …/intl-pl/album/…, spotify:album:…).
pub fn album_id(link: &str) -> Option<String> {
    let link = link.trim();
    let id = if let Some(rest) = link.strip_prefix("spotify:album:") {
        rest.to_string()
    } else {
        let url = url::Url::parse(link).ok()?;
        if url.scheme() != "https" || url.host_str() != Some("open.spotify.com") {
            return None;
        }
        let parts: Vec<_> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
        let at = parts.iter().position(|p| *p == "album")?;
        parts.get(at + 1)?.to_string()
    };
    (id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric())).then_some(id)
}

fn client() -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Mytify")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()?)
}

fn page(client: &reqwest::blocking::Client, url: &str) -> Result<String> {
    let r = client.get(url).header("Accept-Language", "en").send().map_err(|_| anyhow!("Spotify nie odpowiada. Sprawdź internet."))?;
    if r.status().as_u16() == 404 {
        bail!("Spotify nie zna tego albumu. Sprawdź link.")
    }
    if !r.status().is_success() {
        bail!("Spotify odpowiedział błędem HTTP {}.", r.status().as_u16())
    }
    let bytes = r.bytes()?;
    if bytes.len() > 4 * 1024 * 1024 {
        bail!("Strona albumu jest za duża.")
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Reads the album behind a link: the embed player's data first (it has the lengths),
/// the album page's description as a fallback and for what the first one lacks.
pub fn album(link: &str) -> Result<Album> {
    let id = album_id(link).ok_or_else(|| anyhow!("To nie jest link do albumu w Spotify (open.spotify.com/album/…)."))?;
    let client = client()?;
    let mut album = page(&client, &format!("https://open.spotify.com/embed/album/{id}"))
        .ok()
        .and_then(|html| parse_embed(&html))
        .unwrap_or_default();
    if album.title.is_empty() || album.artist.is_empty() || album.date.is_empty() || album.tracks.is_empty() || album.cover_url.is_none() {
        if let Ok(html) = page(&client, &format!("https://open.spotify.com/album/{id}")) {
            let p = parse_page(&html);
            for (mine, theirs) in [(&mut album.title, p.title), (&mut album.artist, p.artist), (&mut album.date, p.date)] {
                if mine.is_empty() {
                    *mine = theirs;
                }
            }
            if album.track_count == 0 {
                album.track_count = p.track_count;
            }
            if album.cover_url.is_none() {
                album.cover_url = p.cover_url;
            }
        }
    }
    if album.cover_url.is_none() {
        // oEmbed always names the cover.
        let link = format!("https://open.spotify.com/album/{id}");
        if let Ok(r) = client.get("https://open.spotify.com/oembed").query(&[("url", link.as_str())]).send() {
            if let Ok(v) = r.json::<Value>() {
                album.cover_url = v["thumbnail_url"].as_str().map(str::to_string);
                if album.title.is_empty() {
                    album.title = clean(v["title"].as_str().unwrap_or(""));
                }
            }
        }
    }
    if album.title.is_empty() {
        bail!("Nie udało się odczytać albumu ze Spotify. Wpisz album i wykonawcę ręcznie.")
    }
    if album.track_count == 0 {
        album.track_count = album.tracks.len();
    }
    album.id = id;
    Ok(album)
}

/// The cover, only from Spotify's image server.
pub fn cover(album: &Album) -> Option<Vec<u8>> {
    let url = url::Url::parse(album.cover_url.as_deref()?).ok()?;
    if url.scheme() != "https" || url.host_str() != Some("i.scdn.co") {
        return None;
    }
    let r = client().ok()?.get(url).send().ok()?;
    if !r.status().is_success() {
        return None;
    }
    let bytes = r.bytes().ok()?;
    (bytes.len() <= 8 * 1024 * 1024).then(|| bytes.to_vec())
}

/// The embed player keeps its data in a JSON script (Next.js).
pub fn parse_embed(html: &str) -> Option<Album> {
    let start = html.find("id=\"__NEXT_DATA__\"")?;
    let open = start + html[start..].find('>')? + 1;
    let close = open + html[open..].find("</script>")?;
    let data: Value = serde_json::from_str(&html[open..close]).ok()?;
    let entity = find_entity(&data)?;
    let text = |v: &Value| clean(v.as_str().unwrap_or(""));
    let mut album = Album {
        title: text(entity.get("name").or_else(|| entity.get("title"))?),
        artist: entity
            .get("subtitle")
            .map(text)
            .filter(|s| !s.is_empty())
            .or_else(|| entity["artists"].as_array().map(|a| a.iter().map(|x| text(&x["name"])).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(", ")))
            .unwrap_or_default(),
        date: entity["releaseDate"]["isoString"]
            .as_str()
            .or_else(|| entity["releaseDate"].as_str())
            .or_else(|| entity["date"].as_str())
            .map(|d| d.get(..10).unwrap_or(d).trim_end_matches("-01-01").to_string())
            .unwrap_or_default(),
        ..Default::default()
    };
    for t in entity["trackList"].as_array().into_iter().flatten() {
        let title = text(&t["title"]);
        if title.is_empty() {
            continue;
        }
        album.tracks.push(Song {
            title,
            artist: text(&t["subtitle"]),
            duration_ms: t["duration"].as_u64().or_else(|| t["duration"].as_f64().map(|d| d as u64)).unwrap_or(0),
        });
    }
    album.track_count = album.tracks.len();
    album.cover_url = cover_url(entity);
    Some(album)
}

/// The object describing the album: the one with a track list.
fn find_entity(v: &Value) -> Option<&Value> {
    match v {
        Value::Object(m) => {
            if m.get("trackList").is_some_and(Value::is_array) && (m.contains_key("name") || m.contains_key("title")) {
                return Some(v);
            }
            m.values().find_map(find_entity)
        }
        Value::Array(a) => a.iter().find_map(find_entity),
        _ => None,
    }
}

/// The largest image of the album: any object with a Spotify image address, wherever
/// the player keeps it (the layout of its data changes).
fn cover_url(entity: &Value) -> Option<String> {
    fn walk<'a>(v: &'a Value, out: &mut Vec<(u64, &'a str)>) {
        match v {
            Value::Object(m) => {
                if let Some(u) = m.get("url").and_then(Value::as_str).filter(|u| u.starts_with("https://i.scdn.co/image/")) {
                    let w = ["maxWidth", "width", "maxHeight", "height"].iter().find_map(|k| m.get(*k).and_then(Value::as_u64)).unwrap_or(1);
                    out.push((w, u));
                }
                // Track entries carry their own small art; the album's is enough.
                for (k, x) in m {
                    if k != "trackList" {
                        walk(x, out);
                    }
                }
            }
            Value::Array(a) => a.iter().for_each(|x| walk(x, out)),
            Value::String(u) if u.starts_with("https://i.scdn.co/image/") => out.push((0, u)),
            _ => {}
        }
    }
    let mut found = Vec::new();
    walk(entity, &mut found);
    found.into_iter().max_by_key(|(w, _)| *w).map(|(_, u)| u.to_string())
}

/// Trimmed text with ordinary spaces (Spotify uses non-breaking ones in names).
fn clean(s: &str) -> String {
    s.replace(['\u{a0}', '\u{202f}'], " ").split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The album page's description tags ("Radiohead · Album · 1997 · 12 songs").
pub fn parse_page(html: &str) -> Album {
    let mut album = Album {
        title: clean(&meta(html, "og:title").unwrap_or_default()),
        date: meta(html, "music:release_date").unwrap_or_default(),
        cover_url: meta(html, "og:image"),
        ..Default::default()
    };
    let songs = html.matches("name=\"music:song\"").count();
    if let Some(d) = meta(html, "og:description") {
        // Older pages start with "Listen to … on Spotify."
        let d = d.rsplit_once("Spotify. ").map(|(_, r)| r).unwrap_or(&d).trim_end_matches('.');
        let parts: Vec<&str> = d.split(" · ").map(str::trim).collect();
        if parts.len() >= 2 {
            album.artist = clean(parts[0]);
        }
        for p in &parts[1..] {
            if p.len() == 4 && p.bytes().all(|b| b.is_ascii_digit()) && album.date.is_empty() {
                album.date = p.to_string();
            }
            if let Some(n) = p.split(' ').next().and_then(|n| n.parse::<usize>().ok()) {
                if p.contains("song") || p.contains("utw") {
                    album.track_count = n;
                }
            }
        }
    }
    if album.artist.is_empty() {
        // "<title>OK Computer - Album by Radiohead | Spotify</title>"
        if let Some(t) = between(html, "<title>", "</title>") {
            if let Some((_, rest)) = t.split_once(" by ") {
                album.artist = decode(rest.trim_end_matches(" | Spotify").trim());
            }
        }
    }
    if album.track_count == 0 {
        album.track_count = songs;
    }
    album
}

fn between<'a>(s: &'a str, a: &str, b: &str) -> Option<&'a str> {
    let i = s.find(a)? + a.len();
    let j = i + s[i..].find(b)?;
    Some(&s[i..j])
}

/// Content of `<meta property|name="key" content="…">`.
fn meta(html: &str, key: &str) -> Option<String> {
    let mut rest = html;
    while let Some(i) = rest.find("<meta") {
        let tag_end = rest[i..].find('>')? + i;
        let tag = &rest[i..tag_end];
        rest = &rest[tag_end..];
        if tag.contains(&format!("property=\"{key}\"")) || tag.contains(&format!("name=\"{key}\"")) {
            return between(tag, "content=\"", "\"").map(decode).filter(|s| !s.is_empty());
        }
    }
    None
}

fn decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest[..rest.len().min(10)].find(';') else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let name = &rest[1..end];
        let ch = match name {
            "amp" => Some('&'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "nbsp" => Some(' '),
            _ => name
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| name.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match ch {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn album_links() {
        let id = "6dVIqQ8qmQ5GBnJ9shOYGE";
        assert_eq!(album_id(&format!("https://open.spotify.com/album/{id}?si=abc")).as_deref(), Some(id));
        assert_eq!(album_id(&format!("https://open.spotify.com/intl-pl/album/{id}")).as_deref(), Some(id));
        assert_eq!(album_id(&format!("spotify:album:{id}")).as_deref(), Some(id));
        assert_eq!(album_id(&format!("https://open.spotify.com/track/{id}")), None);
        assert_eq!(album_id(&format!("https://evil.example/album/{id}")), None);
        assert_eq!(album_id(&format!("http://open.spotify.com/album/{id}")), None);
        assert_eq!(album_id("https://open.spotify.com/album/../../x"), None);
    }

    #[test]
    fn embed_data_gives_tracks_and_lengths() {
        let html = r#"<html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"album","name":"OK Computer","subtitle":"Radiohead","releaseDate":{"isoString":"1997-05-21T00:00:00Z"},"visualIdentity":{"image":[{"url":"https://i.scdn.co/image/small","maxWidth":64},{"url":"https://i.scdn.co/image/big","maxWidth":640}]},"trackList":[{"title":"Airbag","subtitle":"Radiohead","duration":284000},{"title":"Paranoid Android","subtitle":"Radiohead","duration":383000}]}}}}}}</script></html>"#;
        let a = parse_embed(html).unwrap();
        assert_eq!(a.title, "OK Computer");
        assert_eq!(a.artist, "Radiohead");
        assert_eq!(a.date, "1997-05-21");
        assert_eq!(a.tracks.len(), 2);
        assert_eq!(a.tracks[1], Song { title: "Paranoid Android".into(), artist: "Radiohead".into(), duration_ms: 383000 });
        assert_eq!(a.cover_url.as_deref(), Some("https://i.scdn.co/image/big"));
        // Other layouts: cover under any key, names with non-breaking spaces.
        let other = r#"<script id="__NEXT_DATA__" type="application/json">{"entity":{"name":"Queen of Time","subtitle":"Amorphis\u00a0","coverArt":{"extractedColors":{},"sources":[{"url":"https://i.scdn.co/image/a300","height":300},{"url":"https://i.scdn.co/image/a640","height":640}]},"trackList":[{"title":"The Bee","subtitle":"Amorphis","duration":400000,"image":{"url":"https://i.scdn.co/image/track"}}]}}</script>"#;
        let b = parse_embed(other).unwrap();
        assert_eq!(b.artist, "Amorphis");
        assert_eq!(b.tracks[0].artist, "Amorphis");
        assert_eq!(b.cover_url.as_deref(), Some("https://i.scdn.co/image/a640"));
    }

    #[test]
    fn album_page_description() {
        let html = r#"<head><title>OK Computer - Album by Radiohead | Spotify</title><meta property="og:title" content="OK Computer"/><meta property="og:description" content="Radiohead &#183; Album · 1997 · 12 songs"/><meta property="og:image" content="https://i.scdn.co/image/x"/><meta name="music:song" content="a"/></head>"#;
        let a = parse_page(html);
        assert_eq!(a.title, "OK Computer");
        assert_eq!(a.artist, "Radiohead");
        assert_eq!(a.date, "1997");
        assert_eq!(a.track_count, 12);
        let old = r#"<meta property="og:title" content="Rock &amp; Roll"/><meta property="og:description" content="Listen to Rock &amp; Roll on Spotify. Some Band · Album · 2001 · 9 songs."/>"#;
        let b = parse_page(old);
        assert_eq!(b.title, "Rock & Roll");
        assert_eq!(b.artist, "Some Band");
        assert_eq!(b.track_count, 9);
        // Only the title tag names the artist.
        let c = parse_page(r#"<title>Blue - Album by Joni Mitchell | Spotify</title><meta property="og:title" content="Blue"/>"#);
        assert_eq!(c.artist, "Joni Mitchell");
    }
}
