//! Offline copies from a real WebDAV server: one track, verified, resumable, removable.
use mytify_core::{
    catalog::{Catalog, ScanRequest},
    downloads::Downloads,
    sources::NetworkConfig,
};
use std::{sync::{atomic::AtomicBool, Arc}, time::{Duration, Instant}};

fn wait(d: &Downloads, until: impl Fn(&mytify_core::downloads::Status) -> bool) -> mytify_core::downloads::Status {
    let start = Instant::now();
    loop {
        let s = d.status().unwrap();
        if until(&s) || start.elapsed() > Duration::from_secs(60) {
            return s;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[test]
fn download_is_a_location_not_a_new_track() {
    let Ok(url) = std::env::var("MYTIFY_DAV_URL") else { return };
    let password = std::env::var("MYTIFY_DAV_PASSWORD").unwrap();
    let data = tempfile::tempdir().unwrap();
    let c = Arc::new(Catalog::open(data.path()).unwrap());
    let id = c
        .save_network_source(None, &NetworkConfig { protocol: "webdav".into(), url, user: "mat".into(), password: Some(password), ..Default::default() })
        .unwrap();
    c.scan(ScanRequest { source_id: Some(id.clone()), ..Default::default() }, &AtomicBool::new(false), |_| {}).unwrap();
    let before = c.tracks().unwrap();
    assert_eq!(before.len(), 2);
    assert!(before.iter().all(|t| t.remote && !t.offline));
    let d = Downloads::new(c.clone()).unwrap();
    let ids: Vec<String> = before.iter().map(|t| t.id.clone()).collect();
    let e = d.estimate(&ids).unwrap();
    assert_eq!(e.count, 2);
    assert!(e.bytes > 0);
    d.start();
    assert_eq!(d.add(&ids, "user").unwrap(), 2);
    let s = wait(&d, |s| s.items.is_empty());
    assert!(s.items.is_empty(), "{:?}", s.items);
    let after = c.tracks().unwrap();
    assert_eq!(after.len(), 2, "download must not create a second track");
    assert!(after.iter().all(|t| t.offline && t.location_count == 2));
    assert!(s.used > 0);
    // Server gone (airplane mode): the local copy still plays.
    c.forget_source(&id).unwrap_or(());
    let flac = after.iter().find(|t| t.format == "FLAC").unwrap();
    let path = c.audio_path(&flac.id).unwrap();
    assert!(path.starts_with(std::fs::canonicalize(d.dir()).unwrap()));
    assert_eq!(c.open_audio(&flac.id).unwrap().len, std::fs::metadata(&path).unwrap().len());
    // "Usuń pobranie" removes only the local copy.
    d.remove(&[flac.id.clone()]).unwrap();
    assert!(!path.exists());
    assert!(c.audio_path(&flac.id).is_err());
}

#[test]
fn partial_of_another_version_is_never_continued() {
    let Ok(url) = std::env::var("MYTIFY_DAV_URL") else { return };
    let password = std::env::var("MYTIFY_DAV_PASSWORD").unwrap();
    let data = tempfile::tempdir().unwrap();
    let c = Arc::new(Catalog::open(data.path()).unwrap());
    let id = c
        .save_network_source(None, &NetworkConfig { protocol: "webdav".into(), url, user: "mat".into(), password: Some(password), ..Default::default() })
        .unwrap();
    c.scan(ScanRequest { source_id: Some(id), ..Default::default() }, &AtomicBool::new(false), |_| {}).unwrap();
    let track = c.tracks().unwrap().into_iter().find(|t| t.format == "FLAC").unwrap();
    let d = Downloads::new(c.clone()).unwrap();
    // Garbage left by an interrupted download of an older file version.
    let partial = d.dir().join(format!("{}.flac.part", track.id));
    std::fs::write(&partial, b"old bytes of another version").unwrap();
    std::fs::write(d.dir().join(format!("{}.flac.part.json", track.id)), "\"old-etag\"").unwrap();
    d.start();
    d.add(&[track.id.clone()], "user").unwrap();
    let s = wait(&d, |s| s.items.is_empty());
    assert!(s.items.is_empty(), "{:?}", s.items);
    let path = c.audio_path(&track.id).unwrap();
    let bytes = std::fs::read(path).unwrap();
    let original = std::fs::read(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/sample.flac")).unwrap();
    assert_eq!(bytes, original);
}
