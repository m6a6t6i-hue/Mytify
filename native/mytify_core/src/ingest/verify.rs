//! Rip verification against AccurateRip and the CUETools database (CTDB),
//! drive read offset detection, and the checksums both databases use.
use super::cd::Toc;
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::time::Duration;

pub const SAMPLES_PER_SECTOR: u64 = 588;

/// Read offsets by popularity (AccurateRip drive list, as used by whipper).
pub const OFFSETS: &[i32] = &[
    6, 667, 48, 102, 30, 12, 103, 618, 96, 738, 594, 98, -472, 733, 696, 116, 120, 691, 685, 99,
    702, 97, 600, 676, 690, 1292, 686, 697, -24, 704, 572, 1182, 688, -491, 91, 145, 689, 86, 355,
    708, 79, 564, -496, 679, -1164, 0, 1160, -436, 684, 694, 1194, 94, 106, 681, 678, 117, 692,
    943, 92, 680, 682, 1268, 1279, 1473, -54, 1263, -582, 674, 687, 1272, 1508, -489, 740, 675,
    534, 122, 974, 976, 1303, 111, 108, 1130, 975, 87, 739, 732, -589, -495, -494, -12, 961, 935,
    699, 668, 234, 1776, 138, 1364, 1336, 1262, 1161, 1127,
];
pub const MAX_OFFSET: i32 = 1776;

/// AccurateRip disc ids and the CDDB id, as in the database file name.
pub fn accuraterip_ids(toc: &Toc) -> (u32, u32, u32) {
    let mut id1: u32 = 0;
    let mut id2: u32 = 0;
    let audio: Vec<_> = toc.tracks.iter().filter(|t| !t.data).collect();
    for t in &audio {
        id1 = id1.wrapping_add(t.start);
        id2 = id2.wrapping_add(t.start.max(1).wrapping_mul(t.number as u32));
    }
    id1 = id1.wrapping_add(toc.leadout);
    id2 = id2.wrapping_add(toc.leadout.wrapping_mul(audio.len() as u32 + 1));
    (id1, id2, cddb_id(toc))
}

pub fn cddb_id(toc: &Toc) -> u32 {
    fn digits(mut n: u32) -> u32 {
        let mut s = 0;
        while n > 0 {
            s += n % 10;
            n /= 10;
        }
        s
    }
    let sum: u32 = toc.tracks.iter().map(|t| digits((t.start + 150) / 75)).sum();
    let first = toc.tracks.first().map(|t| t.start).unwrap_or(0) / 75;
    let total = toc.leadout / 75 - first;
    ((sum % 255) << 24) | ((total & 0xffff) << 8) | (toc.tracks.len() as u32 & 0xff)
}

pub fn accuraterip_path(toc: &Toc) -> String {
    let (id1, id2, cddb) = accuraterip_ids(toc);
    let h = format!("{id1:08x}");
    let b = h.as_bytes();
    format!(
        "{}/{}/{}/dBAR-{:03}-{id1:08x}-{id2:08x}-{cddb:08x}.bin",
        b[7] as char,
        b[6] as char,
        b[5] as char,
        toc.tracks.iter().filter(|t| !t.data).count()
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArResponse {
    /// Per track: (confidence, checksum).
    pub tracks: Vec<(u8, u32)>,
}

pub fn parse_accuraterip(mut b: &[u8]) -> Result<Vec<ArResponse>> {
    let mut out = Vec::new();
    while !b.is_empty() {
        let n = b[0] as usize;
        let size = 13 + n * 9;
        if n == 0 || b.len() < size {
            bail!("Nieprawidłowa odpowiedź AccurateRip")
        }
        let tracks = (0..n)
            .map(|i| {
                let p = 13 + i * 9;
                (b[p], u32::from_le_bytes(b[p + 1..p + 5].try_into().unwrap()))
            })
            .collect();
        out.push(ArResponse { tracks });
        b = &b[size..];
    }
    Ok(out)
}

/// CRC-32 (IEEE, as zlib), table driven.
pub struct Crc32 {
    table: [u32; 256],
    pub value: u32,
}
impl Default for Crc32 {
    fn default() -> Self {
        let mut table = [0u32; 256];
        for (i, slot) in table.iter_mut().enumerate() {
            let mut c = i as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
            }
            *slot = c;
        }
        Self { table, value: 0xffff_ffff }
    }
}
impl Crc32 {
    pub fn update(&mut self, bytes: &[u8]) {
        let mut c = self.value;
        for &b in bytes {
            c = self.table[((c ^ b as u32) & 0xff) as usize] ^ (c >> 8);
        }
        self.value = c;
    }
    pub fn finish(&self) -> u32 {
        self.value ^ 0xffff_ffff
    }
}

/// Streaming AccurateRip v1/v2 and CTDB CRC of one track, fed with 16-bit stereo frames.
pub struct TrackSums {
    position: u64,
    from: u64,
    to: u64,
    v1: u32,
    hi: u32,
    crc: Crc32,
    crc_from: u64,
    crc_to: u64,
}
impl TrackSums {
    /// `samples`: track length in stereo samples. First and last tracks skip 5 sectors
    /// for AccurateRip; CTDB skips `ctdb_prefix` / `ctdb_suffix` samples at the disc edges.
    pub fn new(samples: u64, first: bool, last: bool, ctdb_prefix: u64, ctdb_suffix: u64) -> Self {
        let edge = 5 * SAMPLES_PER_SECTOR;
        Self {
            position: 0,
            from: if first { edge } else { 1 },
            to: if last { samples.saturating_sub(edge) } else { samples },
            v1: 0,
            hi: 0,
            crc: Crc32::default(),
            crc_from: if first { ctdb_prefix } else { 0 },
            crc_to: if last { samples.saturating_sub(ctdb_suffix) } else { samples },
        }
    }
    pub fn feed(&mut self, pcm: &[u8]) {
        for frame in pcm.chunks_exact(4) {
            let value = u32::from_le_bytes(frame.try_into().unwrap());
            let index = self.position;
            self.position += 1;
            let multiplier = self.position;
            if multiplier >= self.from && multiplier <= self.to {
                let product = value as u64 * multiplier;
                self.v1 = self.v1.wrapping_add(product as u32);
                self.hi = self.hi.wrapping_add((product >> 32) as u32);
            }
            if index >= self.crc_from && index < self.crc_to {
                self.crc.update(frame);
            }
        }
    }
    pub fn v1(&self) -> u32 {
        self.v1
    }
    pub fn v2(&self) -> u32 {
        self.v1.wrapping_add(self.hi)
    }
    pub fn crc(&self) -> u32 {
        self.crc.finish()
    }
}

/// AccurateRip v1 and v2 of a whole track held in memory (offset detection).
pub fn accuraterip_sums(pcm: &[u8], first: bool, last: bool) -> (u32, u32) {
    let mut s = TrackSums::new((pcm.len() / 4) as u64, first, last, 0, 0);
    s.feed(pcm);
    (s.v1(), s.v2())
}

/// CTDB layout string: track starts then leadout, colon separated.
pub fn ctdb_toc(toc: &Toc) -> String {
    let mut s = String::new();
    for t in &toc.tracks {
        if t.data {
            s.push('-');
        }
        s.push_str(&format!("{}:", t.start));
    }
    s.push_str(&toc.leadout.to_string());
    s
}

/// CTDB skips 10 sectors at the start and 10 plus the remainder of the stride at the end.
pub fn ctdb_edges(toc: &Toc) -> (u64, u64) {
    let stride: u64 = 10 * SAMPLES_PER_SECTOR * 2;
    let first = toc.tracks.first().map(|t| t.start).unwrap_or(0) as u64;
    let disc = (toc.leadout as u64 - first) * SAMPLES_PER_SECTOR;
    let last = stride + (disc * 2) % stride;
    (stride / 2, last / 2)
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct CtdbEntry {
    pub crc: u32,
    pub confidence: u32,
    pub track_crcs: Vec<u32>,
}

pub fn parse_ctdb(xml: &str) -> Result<Vec<CtdbEntry>> {
    let doc = roxmltree::Document::parse(xml).context("Nieprawidłowa odpowiedź CTDB")?;
    let mut out = Vec::new();
    for e in doc.descendants().filter(|n| n.has_tag_name("entry")) {
        let Some(crc) = e.attribute("crc32").and_then(|v| u32::from_str_radix(v, 16).ok()) else {
            continue;
        };
        out.push(CtdbEntry {
            crc,
            confidence: e.attribute("confidence").and_then(|v| v.parse().ok()).unwrap_or(0),
            track_crcs: e
                .attribute("trackcrcs")
                .map(|v| v.split_whitespace().filter_map(|x| u32::from_str_radix(x, 16).ok()).collect())
                .unwrap_or_default(),
        });
    }
    Ok(out)
}

/// What the databases know about this disc. Empty lists when the disc is unknown;
/// `error` when a database could not be reached.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Databases {
    #[serde(skip)]
    pub accuraterip: Vec<ArResponse>,
    #[serde(skip)]
    pub ctdb: Vec<CtdbEntry>,
    pub accuraterip_entries: usize,
    pub ctdb_entries: usize,
    pub errors: Vec<String>,
}

fn client() -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(20))
        .user_agent("Mytify/0.20 (CD ripper; https://kanik.dev)")
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()?)
}

fn get(client: &reqwest::blocking::Client, url: &str, limit: u64) -> Result<Option<Vec<u8>>> {
    let r = client.get(url).send().context("brak połączenia")?;
    if r.status().as_u16() == 404 {
        return Ok(None);
    }
    if !r.status().is_success() {
        bail!("HTTP {}", r.status().as_u16())
    }
    let mut b = Vec::new();
    r.take(limit + 1).read_to_end(&mut b)?;
    if b.len() as u64 > limit {
        bail!("odpowiedź za duża")
    }
    Ok(Some(b))
}

/// Looks the disc up in both databases. AccurateRip is plain HTTP by design of the
/// service; the data is checksums only and is never executed or trusted for audio.
pub fn lookup(toc: &Toc) -> Databases {
    let mut d = Databases::default();
    let client = match client() {
        Ok(c) => c,
        Err(e) => {
            d.errors.push(format!("Weryfikacja online niedostępna: {e}"));
            return d;
        }
    };
    let url = format!("http://www.accuraterip.com/accuraterip/{}", accuraterip_path(toc));
    match get(&client, &url, 256 * 1024).and_then(|b| b.map(|b| parse_accuraterip(&b)).transpose()) {
        Ok(r) => d.accuraterip = r.unwrap_or_default(),
        Err(e) => d.errors.push(format!("AccurateRip: {e}")),
    }
    let url = format!(
        "https://db.cuetools.net/lookup2.php?version=3&ctdb=1&fuzzy=0&metadata=none&toc={}",
        ctdb_toc(toc)
    );
    match get(&client, &url, 1024 * 1024)
        .and_then(|b| b.map(|b| parse_ctdb(&String::from_utf8_lossy(&b))).transpose())
    {
        Ok(r) => d.ctdb = r.unwrap_or_default(),
        Err(e) => d.errors.push(format!("CTDB: {e}")),
    }
    d.accuraterip_entries = d.accuraterip.len();
    d.ctdb_entries = d.ctdb.len();
    d
}

/// Result for one ripped track.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackVerdict {
    pub track: u8,
    pub v1: String,
    pub v2: String,
    pub crc: String,
    /// Sum of confidences of AccurateRip entries that match (v1 or v2).
    pub accuraterip: u32,
    /// Highest confidence any AccurateRip entry has for this track (0 = not in database).
    pub accuraterip_best: u32,
    pub ctdb: u32,
    pub retried_sectors: usize,
}

pub fn judge(d: &Databases, index: usize, number: u8, sums: &TrackSums, retried: usize) -> TrackVerdict {
    let mut v = TrackVerdict {
        track: number,
        v1: format!("{:08x}", sums.v1()),
        v2: format!("{:08x}", sums.v2()),
        crc: format!("{:08x}", sums.crc()),
        retried_sectors: retried,
        ..Default::default()
    };
    for r in &d.accuraterip {
        if let Some((confidence, checksum)) = r.tracks.get(index) {
            v.accuraterip_best = v.accuraterip_best.max(*confidence as u32);
            if *checksum == sums.v1() || *checksum == sums.v2() {
                v.accuraterip += *confidence as u32;
            }
        }
    }
    for e in &d.ctdb {
        if e.track_crcs.get(index) == Some(&sums.crc()) {
            v.ctdb += e.confidence;
        }
    }
    v
}

/// Finds the drive read offset from one track read with a margin of whole sectors on
/// both sides. Returns the offset whose AccurateRip checksum matches the database.
pub fn find_offset(
    d: &Databases,
    index: usize,
    first: bool,
    last: bool,
    track_samples: u64,
    padded: &[u8],
    margin_samples: u64,
) -> Option<i32> {
    let wanted: Vec<u32> = d
        .accuraterip
        .iter()
        .filter_map(|r| r.tracks.get(index).filter(|(c, _)| *c > 0).map(|(_, s)| *s))
        .collect();
    if wanted.is_empty() {
        return None;
    }
    for &offset in OFFSETS {
        let start = margin_samples as i64 + offset as i64;
        if start < 0 {
            continue;
        }
        let a = start as usize * 4;
        let b = a + track_samples as usize * 4;
        if b > padded.len() {
            continue;
        }
        let (v1, v2) = accuraterip_sums(&padded[a..b], first, last);
        if wanted.contains(&v1) || wanted.contains(&v2) {
            return Some(offset);
        }
    }
    None
}

pub fn parse_offset(v: &serde_json::Value) -> Result<Option<i32>> {
    match v {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::Number(n) => {
            let o = n.as_i64().ok_or_else(|| anyhow!("Nieprawidłowe przesunięcie"))?;
            if o.abs() > 3000 {
                bail!("Przesunięcie odczytu musi mieścić się w zakresie ±3000 próbek")
            }
            Ok(Some(o as i32))
        }
        _ => bail!("Nieprawidłowe przesunięcie"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ingest::cd::CdTrack;

    fn toc(starts: &[u32], leadout: u32, data_last: bool) -> Toc {
        Toc {
            drive: "D:".into(),
            disc_id: String::new(),
            tracks: starts
                .iter()
                .enumerate()
                .map(|(i, s)| CdTrack {
                    number: i as u8 + 1,
                    start: *s,
                    end: starts.get(i + 1).copied().unwrap_or(leadout),
                    data: data_last && i + 1 == starts.len(),
                })
                .collect(),
            leadout,
        }
    }

    #[test]
    fn disc_ids_match_whipper_and_eac() {
        // Ladyhawke (whipper test, verified against freedb and EAC): 12 audio + 1 data track.
        let t = toc(
            &[0, 15537, 31691, 50866, 66466, 81202, 99409, 115920, 133093, 149847, 161560, 177682, 207106],
            210385,
            true,
        );
        assert_eq!(cddb_id(&t), 0xc60af50d);
        let (a, b, _) = accuraterip_ids(&t);
        assert_eq!((a, b), (0x0013bd5a, 0x00b8d489));
        assert_eq!(accuraterip_path(&t), "a/5/d/dBAR-012-0013bd5a-00b8d489-c60af50d.bin");
    }

    #[test]
    fn database_file_with_two_pressings() {
        // Layout of whipper's dBAR-002-0000f21c-00027ef8-05021002.bin.
        let mut b = Vec::new();
        for (c1, s1, c2, s2) in [(12u8, 0x284fc705u32, 20u8, 0x9cc1f32eu32), (7, 0xdc77f9ab, 7, 0xdd97d2c3)] {
            b.push(2);
            b.extend(0x0000f21cu32.to_le_bytes());
            b.extend(0x00027ef8u32.to_le_bytes());
            b.extend(0x05021002u32.to_le_bytes());
            for (c, s) in [(c1, s1), (c2, s2)] {
                b.push(c);
                b.extend(s.to_le_bytes());
                b.extend(0u32.to_le_bytes());
            }
        }
        let r = parse_accuraterip(&b).unwrap();
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].tracks, [(12, 0x284fc705), (20, 0x9cc1f32e)]);
        assert_eq!(r[1].tracks[1], (7, 0xdd97d2c3));
        assert!(parse_accuraterip(&b[..20]).is_err());
    }

    /// Straight port of compute_checksums() from whipper's accuraterip-checksum.c.
    fn reference(words: &[u32], track: usize, total: usize) -> (u32, u32) {
        let (mut hi, mut lo) = (0u32, 0u32);
        let from = if track == 1 { (2352 * 5 / 4) as u32 } else { 0 };
        let to = if track == total { words.len() as u32 - 2352 * 5 / 4 } else { words.len() as u32 };
        let mut mul: u32 = 1;
        for w in words {
            if mul >= from && mul <= to {
                let p = *w as u64 * mul as u64;
                hi = hi.wrapping_add((p >> 32) as u32);
                lo = lo.wrapping_add(p as u32);
            }
            mul += 1;
        }
        (lo, lo.wrapping_add(hi))
    }

    #[test]
    fn checksums_equal_reference_and_find_the_offset() {
        let mut x: u32 = 12345;
        let mut words = Vec::new();
        for _ in 0..588 * 40 {
            x = x.wrapping_mul(1664525).wrapping_add(1013904223);
            words.push(x);
        }
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        for (track, total) in [(1, 3), (2, 3), (3, 3), (1, 1)] {
            let (v1, v2) = accuraterip_sums(&bytes, track == 1, track == total);
            assert_eq!((v1, v2), reference(&words, track, total), "track {track}/{total}");
        }
        // A drive reading 6 samples early: the true track starts 6 samples into the read.
        let margin = 4 * 588;
        let track = 588 * 30;
        let truth = &bytes[(margin + 6) * 4..(margin + 6 + track) * 4];
        let (v1, _) = accuraterip_sums(truth, false, false);
        let d = Databases { accuraterip: vec![ArResponse { tracks: vec![(0, 1), (9, v1)] }], ..Default::default() };
        assert_eq!(find_offset(&d, 1, false, false, track as u64, &bytes, margin as u64), Some(6));
        assert_eq!(find_offset(&d, 0, false, false, track as u64, &bytes, margin as u64), None);
    }

    #[test]
    fn crc32_and_ctdb_parsing() {
        let mut c = Crc32::default();
        c.update(b"123456789");
        assert_eq!(c.finish(), 0xcbf43926);
        let xml = r#"<?xml version="1.0"?><ctdb xmlns="http://db.cuetools.net/ns/mmd-1.0#">
            <entry confidence="23" crc32="a1b2c3d4" id="1" npar="8" stride="5880" toc="0:100:200" trackcrcs="00000001 0000000a" />
            <entry confidence="2" crc32="ffffffff" id="2" npar="8" stride="5880" toc="0:100:200" /></ctdb>"#;
        let e = parse_ctdb(xml).unwrap();
        assert_eq!(e.len(), 2);
        assert_eq!(e[0], CtdbEntry { crc: 0xa1b2c3d4, confidence: 23, track_crcs: vec![1, 10] });
        assert_eq!(ctdb_toc(&toc(&[0, 100], 200, false)), "0:100:200");
        assert_eq!(ctdb_edges(&toc(&[0, 100], 200, false)), (5880, (11760 + (200 * 588 * 2) % 11760) / 2));
    }
}
