//! WebDAV over HTTPS against a real server (tools/dav_test_server.py), started by CI.
use mytify_core::{
    catalog::{Catalog, ScanRequest},
    sources::NetworkConfig,
};
use std::{
    io::{Read, Seek, SeekFrom},
    path::Path,
    sync::atomic::AtomicBool,
};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures").join(name)).unwrap()
}

fn dav(url: &str, password: &str) -> NetworkConfig {
    NetworkConfig {
        protocol: "webdav".into(),
        url: url.into(),
        user: "mat".into(),
        password: Some(password.into()),
        ..Default::default()
    }
}

#[test]
fn real_webdav_scan_play_seek() {
    let Ok(url) = std::env::var("MYTIFY_DAV_URL") else {
        eprintln!("MYTIFY_DAV_URL not set, skipping real WebDAV test");
        return;
    };
    let password = std::env::var("MYTIFY_DAV_PASSWORD").unwrap();

    let wrong = mytify_core::sources::test(None, &dav(&url, "zle")).unwrap_err().to_string();
    assert_eq!(wrong, "Nieprawidłowy użytkownik lub hasło.");

    if let Ok(untrusted) = std::env::var("MYTIFY_DAV_UNTRUSTED_URL") {
        let error = mytify_core::sources::test(None, &dav(&untrusted, &password)).unwrap_err().to_string();
        eprintln!("untrusted: {error}");
        assert!(error.starts_with("Certyfikat serwera nie jest zaufany"), "{error}");
    }

    let folders = mytify_core::sources::test(None, &dav(&url, &password)).unwrap();
    assert_eq!(folders, vec!["Polskie ąę albumy".to_string()]);
    let inner = mytify_core::sources::browse(None, &dav(&url, &password), "Polskie ąę albumy").unwrap();
    assert!(inner.is_empty(), "{inner:?}");

    let data = tempfile::tempdir().unwrap();
    let c = Catalog::open(data.path()).unwrap();
    // Linux CI has no credential store: run with --features memory-secrets.
    let id = c.save_network_source(None, &dav(&url, &password)).unwrap();
    let report = c
        .scan(ScanRequest { source_id: Some(id.clone()), ..Default::default() }, &AtomicBool::new(false), |_| {})
        .unwrap();
    eprintln!("{report:?}");
    assert_eq!(report.added, 2, "{:?}", report.errors);
    let again = c
        .scan(ScanRequest { source_id: Some(id.clone()), ..Default::default() }, &AtomicBool::new(false), |_| {})
        .unwrap();
    assert_eq!(again.unchanged, 2);
    let tracks = c.tracks().unwrap();
    let mp3 = tracks.iter().find(|t| t.format == "MP3").unwrap();
    assert_eq!(mp3.bit_depth, 0, "no PCM bit depth for MP3");
    let flac = tracks.iter().find(|t| t.format == "FLAC").unwrap();
    let bytes = fixture("sample.flac");
    let mut input = c.open_audio(&flac.id).unwrap();
    assert_eq!(input.len, bytes.len() as u64);
    input.reader.seek(SeekFrom::Start(5000)).unwrap();
    let mut tail = Vec::new();
    input.reader.read_to_end(&mut tail).unwrap();
    assert_eq!(tail, bytes[5000..]);
    c.forget_source(&id).unwrap();
}

#[test]
fn reader_matches_file_from_start() {
    let Ok(url) = std::env::var("MYTIFY_DAV_URL") else { return };
    let password = std::env::var("MYTIFY_DAV_PASSWORD").unwrap();
    let config = mytify_core::sources::clean(&dav(&url, &password)).unwrap();
    let client = mytify_core::sources::dav(None, &config).unwrap();
    let entries = client.list(&client.url("Polskie%20%C4%85%C4%99%20albumy/").unwrap()).unwrap();
    let mp3 = entries.iter().find(|e| e.name.ends_with(".mp3")).unwrap();
    assert_eq!(mp3.name, "Zażółć gęślą jaźń.mp3");
    let file = client.url(&mp3.href).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("copy.mp3");
    let n = mytify_core::webdav::download(&client, &file, &mp3.version, &target).unwrap();
    assert_eq!(n, mp3.size);
    assert_eq!(std::fs::read(&target).unwrap(), fixture("sample.mp3"));
}

/// A server without Range support: the reader falls back to one full download.
#[test]
fn server_without_ranges_falls_back_to_one_download() {
    let Ok(url) = std::env::var("MYTIFY_NORANGE_URL") else { return };
    let base = mytify_core::webdav::clean_url(&url).unwrap();
    let client = std::sync::Arc::new(mytify_core::webdav::Dav::new(base.clone(), "", "").unwrap());
    let bytes = fixture("sample.flac");
    let file = client.url("Polskie%20%C4%85%C4%99%20albumy/a.flac").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache.bin");
    let mut reader = mytify_core::webdav::RemoteReader::new(client, file, bytes.len() as u64, String::new(), cache.clone());
    reader.seek(SeekFrom::Start(7000)).unwrap();
    let mut part = vec![0u8; 100];
    reader.read_exact(&mut part).unwrap();
    assert_eq!(part, bytes[7000..7100]);
    assert!(cache.is_file(), "full copy kept for further seeks");
    reader.seek(SeekFrom::Start(0)).unwrap();
    let mut all = Vec::new();
    reader.read_to_end(&mut all).unwrap();
    assert_eq!(all, bytes);
    drop(reader);
    assert!(!cache.exists(), "temporary copy removed");
}
