use mytify_core::{
    catalog::{hash_file, Catalog, ScanRequest},
    server::parse_range,
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};
use tempfile::TempDir;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/fixtures")
        .join(name)
}
fn library() -> (TempDir, TempDir, Catalog) {
    let source = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let catalog = Catalog::open(data.path()).unwrap();
    (source, data, catalog)
}
fn copy(source: &Path, name: &str) {
    fs::copy(fixture("sample.flac"), source.join(name)).unwrap();
}
fn scan(catalog: &Catalog, source: &Path) -> mytify_core::catalog::Report {
    catalog
        .scan(
            ScanRequest {
                paths: vec![source.to_string_lossy().into_owned()],
                folder: true,
                ..Default::default()
            },
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap()
}
fn rescan(catalog: &Catalog) -> mytify_core::catalog::Report {
    catalog
        .scan(
            ScanRequest {
                source_id: Some("all".into()),
                ..Default::default()
            },
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap()
}

#[test]
fn reads_real_formats_unicode_and_embedded_cover() {
    let (source, _data, catalog) = library();
    for ext in ["flac", "mp3", "m4a", "wav"] {
        fs::copy(
            fixture(&format!("sample.{ext}")),
            source.path().join(format!("sample.{ext}")),
        )
        .unwrap();
    }
    let report = scan(&catalog, source.path());
    assert_eq!(report.added, 4);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    let tracks = catalog.tracks().unwrap();
    assert_eq!(tracks.len(), 4);
    for track in &tracks {
        assert_eq!(track.title, "Światło");
        assert_eq!(track.artist, "Łódź");
        assert_eq!(track.album, "Album testowy");
        assert_eq!(track.sample_rate, 44100);
        assert!(track.duration_ms > 900);
        assert!(track.available);
        assert!(!track.managed);
    }
    let cover = tracks.iter().find_map(|t| t.cover.as_ref()).unwrap();
    assert!(catalog.artwork_path(cover).unwrap().exists());
}
#[test]
fn links_without_copying_audio_and_detects_duplicate_names() {
    let (source, data, catalog) = library();
    copy(source.path(), "first.flac");
    copy(source.path(), "renamed.flac");
    let original = hash_file(&source.path().join("first.flac")).unwrap();
    let report = scan(&catalog, source.path());
    assert_eq!(report.added, 1);
    assert_eq!(report.duplicates, 1);
    let tracks = catalog.tracks().unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].location_count, 2);
    assert_eq!(
        hash_file(&source.path().join("first.flac")).unwrap(),
        original
    );
    assert_eq!(
        fs::read_dir(data.path().join("imported-v01"))
            .unwrap()
            .count(),
        0
    );
    // Windows returns verbatim (\\?\) canonical paths; compare in the same form.
    assert!(catalog
        .audio_path(&tracks[0].id)
        .unwrap()
        .starts_with(fs::canonicalize(source.path()).unwrap()));
}
#[test]
fn fast_rescan_does_not_reimport_unchanged_files() {
    let (source, _data, catalog) = library();
    copy(source.path(), "a.flac");
    scan(&catalog, source.path());
    let report = rescan(&catalog);
    assert_eq!(report.added, 0);
    assert_eq!(report.unchanged, 1);
    assert_eq!(catalog.tracks().unwrap().len(), 1);
    // A new file next to it: only that one is read, the known one is matched from the
    // folder listing.
    fs::copy(fixture("sample.mp3"), source.path().join("b.mp3")).unwrap();
    let mut totals = Vec::new();
    let report = catalog
        .scan(ScanRequest { source_id: Some("all".into()), ..Default::default() }, &AtomicBool::new(false), |p| totals.push(p.total))
        .unwrap();
    assert_eq!(report.unchanged, 1);
    assert_eq!(catalog.tracks().unwrap().len(), 2);
    assert_eq!(totals.iter().filter(|t| **t > 0).max(), Some(&1), "{totals:?}");
}
#[test]
fn missing_track_remains_in_catalog_with_liked_state() {
    let (source, _data, catalog) = library();
    copy(source.path(), "a.flac");
    scan(&catalog, source.path());
    let id = catalog.tracks().unwrap()[0].id.clone();
    catalog.like(&id, true).unwrap();
    fs::remove_file(source.path().join("a.flac")).unwrap();
    let report = rescan(&catalog);
    assert_eq!(report.missing, 1);
    let tracks = catalog.tracks().unwrap();
    assert_eq!(tracks.len(), 1);
    assert!(!tracks[0].available);
    assert!(tracks[0].liked);
    assert!(catalog.audio_path(&id).is_err());
}
#[test]
fn disconnected_folder_is_offline_and_can_return() {
    let (source, _data, catalog) = library();
    let root = source.path().join("music");
    fs::create_dir(&root).unwrap();
    copy(&root, "a.flac");
    scan(&catalog, &root);
    let away = source.path().join("unplugged");
    fs::rename(&root, &away).unwrap();
    assert_eq!(rescan(&catalog).offline_sources, 1);
    assert_eq!(catalog.sources().unwrap()[0].state, "offline");
    assert!(!catalog.tracks().unwrap()[0].available);
    fs::rename(away, &root).unwrap();
    rescan(&catalog);
    assert!(catalog.tracks().unwrap()[0].available);
}
#[test]
fn renamed_file_keeps_identity_and_favorite() {
    let (source, _data, catalog) = library();
    copy(source.path(), "old.flac");
    scan(&catalog, source.path());
    let id = catalog.tracks().unwrap()[0].id.clone();
    catalog.like(&id, true).unwrap();
    fs::rename(
        source.path().join("old.flac"),
        source.path().join("new.flac"),
    )
    .unwrap();
    rescan(&catalog);
    let tracks = catalog.tracks().unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].id, id);
    assert!(tracks[0].liked && tracks[0].available);
}
#[test]
fn duplicate_from_second_source_remains_available_when_one_is_missing() {
    let (source, _data, catalog) = library();
    let a = source.path().join("a");
    let b = source.path().join("b");
    fs::create_dir(&a).unwrap();
    fs::create_dir(&b).unwrap();
    copy(&a, "song.flac");
    copy(&b, "same.flac");
    scan(&catalog, &a);
    scan(&catalog, &b);
    fs::remove_file(a.join("song.flac")).unwrap();
    rescan(&catalog);
    assert_eq!(catalog.tracks().unwrap().len(), 1);
    assert!(catalog.tracks().unwrap()[0].available);
}
#[test]
fn forgotten_track_does_not_reappear_after_scan_and_original_is_safe() {
    let (source, _data, catalog) = library();
    copy(source.path(), "a.flac");
    scan(&catalog, source.path());
    let id = catalog.tracks().unwrap()[0].id.clone();
    catalog.forget_track(&id).unwrap();
    rescan(&catalog);
    assert!(catalog.tracks().unwrap().is_empty());
    assert!(source.path().join("a.flac").exists());
    catalog
        .scan(
            ScanRequest {
                paths: vec![source.path().join("a.flac").to_string_lossy().into_owned()],
                ..Default::default()
            },
            &AtomicBool::new(false),
            |_| {},
        )
        .unwrap();
    assert_eq!(catalog.tracks().unwrap().len(), 1);
}
#[test]
fn sqlite_survives_reopen_and_supports_polish_fts() {
    let (source, data, catalog) = library();
    copy(source.path(), "a.flac");
    scan(&catalog, source.path());
    let id = catalog.tracks().unwrap()[0].id.clone();
    catalog.like(&id, true).unwrap();
    drop(catalog);
    let catalog = Catalog::open(data.path()).unwrap();
    assert!(catalog.tracks().unwrap()[0].liked);
    assert_eq!(catalog.search_ids("lodz swiat").unwrap(), vec![id]);
    assert!(catalog.search_ids("nieistniejacy").unwrap().is_empty());
    assert!(catalog.search_ids("\" OR *").is_ok());
}
#[test]
fn canceled_scan_never_marks_existing_tracks_missing() {
    let (source, _data, catalog) = library();
    copy(source.path(), "a.flac");
    scan(&catalog, source.path());
    let result = catalog
        .scan(
            ScanRequest {
                source_id: Some("all".into()),
                ..Default::default()
            },
            &AtomicBool::new(true),
            |_| {},
        )
        .unwrap();
    assert!(result.cancelled);
    assert!(catalog.tracks().unwrap()[0].available);
}
#[test]
fn removing_source_never_deletes_music() {
    let (source, _data, catalog) = library();
    copy(source.path(), "a.flac");
    scan(&catalog, source.path());
    let id = catalog.sources().unwrap()[0].id.clone();
    catalog.forget_source(&id).unwrap();
    assert!(catalog.tracks().unwrap().is_empty());
    assert!(source.path().join("a.flac").exists());
}
#[test]
fn relink_folder_keeps_track_and_source_identity() {
    let (source, _data, catalog) = library();
    let old = source.path().join("old");
    fs::create_dir(&old).unwrap();
    copy(&old, "a.flac");
    scan(&catalog, &old);
    let source_id = catalog.sources().unwrap()[0].id.clone();
    let id = catalog.tracks().unwrap()[0].id.clone();
    catalog.like(&id, true).unwrap();
    let new = source.path().join("new");
    fs::rename(old, &new).unwrap();
    catalog.relink_source(&source_id, &new).unwrap();
    rescan(&catalog);
    assert_eq!(catalog.sources().unwrap()[0].id, source_id);
    assert_eq!(catalog.tracks().unwrap()[0].id, id);
    assert!(catalog.tracks().unwrap()[0].liked && catalog.tracks().unwrap()[0].available);
    assert_eq!(catalog.sources().unwrap()[0].files, 1);
    assert_eq!(catalog.tracks().unwrap()[0].location_count, 1);
    scan(&catalog, &new);
    assert_eq!(catalog.sources().unwrap().len(), 1);
}
#[test]
fn legacy_migration_preserves_bytes_and_does_not_reset_later_likes() {
    let (_source, data, catalog) = library();
    let path = data.path().join("imported-v01/legacy.flac");
    fs::copy(fixture("sample.flac"), &path).unwrap();
    let hash = hash_file(&path).unwrap();
    catalog
        .migrate_file(&path, "Oryginalna nazwa.flac", &hash, true)
        .unwrap();
    assert!(catalog.tracks().unwrap()[0].liked);
    assert!(catalog.tracks().unwrap()[0].managed);
    catalog.like(&hash, false).unwrap();
    catalog
        .migrate_file(&path, "Oryginalna nazwa.flac", &hash, true)
        .unwrap();
    assert!(!catalog.tracks().unwrap()[0].liked);
    assert_eq!(hash_file(&path).unwrap(), hash);
}
#[test]
fn http_range_boundaries() {
    assert_eq!(parse_range("bytes=0-9", 100), Some((0, 9)));
    assert_eq!(parse_range("bytes=90-", 100), Some((90, 99)));
    assert_eq!(parse_range("bytes=-10", 100), Some((90, 99)));
    assert_eq!(parse_range("bytes=100-", 100), None);
    assert_eq!(parse_range("bytes=9-2", 100), None);
    assert_eq!(parse_range("bytes=0-1,3-4", 100), None);
    assert_eq!(parse_range("bytes=-0", 100), None);
    assert_eq!(parse_range("bytes=0-", 0), None);
}
