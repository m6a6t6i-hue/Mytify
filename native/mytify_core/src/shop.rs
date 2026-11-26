//! "Buy music": prices from the iTunes Search API (the only store with a public price
//! lookup). Other stores are offered as search links by the app, without prices.
use anyhow::{bail, Result};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Offer {
    pub store: String,
    /// "album" or "song"
    pub kind: String,
    pub title: String,
    pub artist: String,
    pub price: Option<f64>,
    pub currency: String,
    pub tracks: u32,
    pub year: String,
    pub url: String,
}

fn store_url(u: &str) -> bool {
    u.starts_with("https://music.apple.com/") || u.starts_with("https://itunes.apple.com/")
}

pub fn offers(v: &Value) -> Vec<Offer> {
    v["results"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|r| {
                    let album = r["wrapperType"] == "collection";
                    let song = r["wrapperType"] == "track" && r["kind"] == "song";
                    if !album && !song {
                        return None;
                    }
                    let url = r[if album { "collectionViewUrl" } else { "trackViewUrl" }].as_str()?;
                    if !store_url(url) {
                        return None;
                    }
                    let price = r[if album { "collectionPrice" } else { "trackPrice" }].as_f64().filter(|p| *p > 0.0);
                    Some(Offer {
                        store: "iTunes Store".into(),
                        kind: if album { "album" } else { "song" }.into(),
                        title: r[if album { "collectionName" } else { "trackName" }].as_str().unwrap_or("").into(),
                        artist: r["artistName"].as_str().unwrap_or("").into(),
                        price,
                        currency: r["currency"].as_str().unwrap_or("").into(),
                        tracks: r["trackCount"].as_u64().unwrap_or(0) as u32,
                        year: r["releaseDate"].as_str().unwrap_or("").chars().take(4).collect(),
                        url: url.into(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Answers are kept for ten minutes: Apple allows about 20 lookups a minute.
pub struct Shop {
    cache: Mutex<HashMap<String, (Instant, Vec<Offer>)>>,
}
impl Default for Shop {
    fn default() -> Self {
        Self::new()
    }
}
impl Shop {
    pub fn new() -> Self {
        Self { cache: Mutex::new(HashMap::new()) }
    }
    pub fn search(&self, query: &str, country: &str) -> Result<Vec<Offer>> {
        let q: String = query.trim().chars().take(100).collect();
        if q.chars().count() < 2 {
            return Ok(Vec::new());
        }
        let country = if country.len() == 2 && country.bytes().all(|b| b.is_ascii_alphabetic()) { country.to_uppercase() } else { "PL".into() };
        let key = format!("{country}|{}", q.to_lowercase());
        if let Some((at, hit)) = self.cache.lock().unwrap().get(&key) {
            if at.elapsed() < Duration::from_secs(600) {
                return Ok(hit.clone());
            }
        }
        let client = reqwest::blocking::Client::builder()
            .user_agent(crate::radio::USER_AGENT)
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(12))
            .build()?;
        let mut all = Vec::new();
        for (entity, limit) in [("album", "8"), ("song", "5")] {
            let r = client
                .get("https://itunes.apple.com/search")
                .query(&[("term", q.as_str()), ("country", country.as_str()), ("media", "music"), ("entity", entity), ("limit", limit)])
                .send()?;
            if !r.status().is_success() {
                bail!("Sklep odpowiedział błędem HTTP {}.", r.status().as_u16());
            }
            all.extend(offers(&r.json::<Value>()?));
        }
        let mut cache = self.cache.lock().unwrap();
        if cache.len() > 200 {
            cache.clear();
        }
        cache.insert(key, (Instant::now(), all.clone()));
        Ok(all)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn apple_answers_become_offers() {
        let v: Value = serde_json::from_str(
            r#"{"results":[
            {"wrapperType":"collection","collectionName":"Kind of Blue","artistName":"Miles Davis","collectionPrice":39.99,"currency":"PLN","trackCount":5,"releaseDate":"1959-08-17T07:00:00Z","collectionViewUrl":"https://music.apple.com/pl/album/kind-of-blue/1"},
            {"wrapperType":"track","kind":"song","trackName":"So What","artistName":"Miles Davis","trackPrice":5.49,"currency":"PLN","trackViewUrl":"https://music.apple.com/pl/album/x?i=2"},
            {"wrapperType":"track","kind":"music-video","trackName":"V","trackViewUrl":"https://music.apple.com/v"},
            {"wrapperType":"collection","collectionName":"Bad","collectionPrice":-1,"collectionViewUrl":"javascript:alert(1)"},
            {"wrapperType":"collection","collectionName":"Not for sale","artistName":"A","collectionPrice":-1,"currency":"PLN","collectionViewUrl":"https://music.apple.com/pl/album/3"}
        ]}"#,
        )
        .unwrap();
        let o = offers(&v);
        assert_eq!(o.len(), 3);
        assert_eq!((o[0].title.as_str(), o[0].price, o[0].year.as_str(), o[0].tracks), ("Kind of Blue", Some(39.99), "1959", 5));
        assert_eq!((o[1].kind.as_str(), o[1].price), ("song", Some(5.49)));
        assert_eq!(o[2].price, None);
    }
}
