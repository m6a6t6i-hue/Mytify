use mytify_core::{
    catalog::{hash_file, Catalog, ScanRequest},
    metadata::Edit,
};
use serde_json::json;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};
fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures/sample.flac")
}
fn scan(c: &Catalog, p: &Path) {
    c.scan(
        ScanRequest {
            paths: vec![p.to_string_lossy().into()],
            folder: true,
            force: true,
            ..Default::default()
        },
        &AtomicBool::new(false),
        |_| {},
    )
    .unwrap();
}
#[test]
fn edits_survive_force_rescan_reopen_and_reset_without_changing_audio() {
    let source = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let file = source.path().join("a.flac");
    fs::copy(fixture(), &file).unwrap();
    let c = Catalog::open(data.path()).unwrap();
    scan(&c, source.path());
    let id = c.tracks().unwrap()[0].id.clone();
    c.edit_metadata(vec![Edit{id:id.clone(),patch:json!({"title":"Moje światło","artist":"Warszawa","albumArtist":"Warszawa","album":"Własny album","trackNumber":7,"source":"manual"})}]).unwrap();
    scan(&c, source.path());
    let t = c.tracks().unwrap().remove(0);
    assert!(t.edited);
    assert_eq!(t.title, "Moje światło");
    assert_eq!(t.track_number, 7);
    assert_eq!(hash_file(&file).unwrap(), id);
    assert_eq!(c.search_ids("moje warszawa").unwrap(), vec![id.clone()]);
    assert!(c.search_ids("lodz").unwrap().is_empty());
    drop(c);
    let c = Catalog::open(data.path()).unwrap();
    assert_eq!(c.tracks().unwrap()[0].album, "Własny album");
    c.reset_metadata(&[id.clone()]).unwrap();
    let t = c.tracks().unwrap().remove(0);
    assert!(!t.edited);
    assert_eq!(t.title, "Światło");
    assert_eq!(c.search_ids("lodz swiatlo").unwrap(), vec![id]);
}
#[test]
fn invalid_batch_is_atomic_and_cannot_set_paths_or_remote_covers() {
    let source = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    fs::copy(fixture(), source.path().join("a.flac")).unwrap();
    let c = Catalog::open(data.path()).unwrap();
    scan(&c, source.path());
    let id = c.tracks().unwrap()[0].id.clone();
    assert!(c
        .edit_metadata(vec![
            Edit {
                id: id.clone(),
                patch: json!({"title":"Zmiana"})
            },
            Edit {
                id: "a".repeat(64),
                patch: json!({"title":"Nieistniejący"})
            }
        ])
        .is_err());
    assert_eq!(c.tracks().unwrap()[0].title, "Światło");
    for patch in [
        json!({"cover":"https://example.org/image.jpg"}),
        json!({"trackNumber":-1}),
        json!({"discNumber":10000}),
        json!({"title":"  "}),
        json!({"path":"C:/other"}),
        json!({"cover":"a".repeat(64)}),
    ] {
        assert!(c
            .edit_metadata(vec![Edit {
                id: id.clone(),
                patch
            }])
            .is_err());
    }
    assert!(!c.tracks().unwrap()[0].edited);
}
#[test]
fn metadata_edits_follow_changed_file_identity() {
    let source = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let file = source.path().join("a.flac");
    fs::copy(fixture(), &file).unwrap();
    let c = Catalog::open(data.path()).unwrap();
    scan(&c, source.path());
    let id = c.tracks().unwrap()[0].id.clone();
    c.edit_metadata(vec![Edit {
        id: id.clone(),
        patch: json!({"title":"Zachowaj mnie"}),
    }])
    .unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&file)
        .unwrap()
        .write_all(&[0; 10])
        .unwrap();
    scan(&c, source.path());
    let t = c.tracks().unwrap().remove(0);
    assert_ne!(t.id, id);
    assert_eq!(t.title, "Zachowaj mnie");
    assert_eq!(c.search_ids("zachowaj").unwrap(), vec![t.id]);
}
#[test]
fn v02_upgrade_makes_consistent_backup_once() {
    let data = tempfile::tempdir().unwrap();
    let c = Catalog::open(data.path()).unwrap();
    drop(c);
    let path = data.path().join("catalog.sqlite3");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.pragma_update(None, "user_version", 2).unwrap();
    drop(db);
    let c = Catalog::open(data.path()).unwrap();
    drop(c);
    let backup = data.path().join("catalog-before-0.3.sqlite3");
    assert!(backup.is_file());
    let db = rusqlite::Connection::open(backup).unwrap();
    assert_eq!(
        db.pragma_query_value::<i64, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        2
    );
    let db = rusqlite::Connection::open(path).unwrap();
    assert_eq!(
        db.pragma_query_value::<i64, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        3
    );
}
#[test]
fn cover_override_reset_returns_embedded_picture() {
    let source = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    fs::copy(fixture(), source.path().join("a.flac")).unwrap();
    let c = Catalog::open(data.path()).unwrap();
    scan(&c, source.path());
    let t = c.tracks().unwrap().remove(0);
    let original = t.cover.clone();
    assert!(original.is_some());
    c.edit_metadata(vec![Edit {
        id: t.id.clone(),
        patch: json!({"cover":""}),
    }])
    .unwrap();
    assert!(c.tracks().unwrap()[0].cover.is_none());
    c.reset_metadata(&[t.id]).unwrap();
    assert_eq!(c.tracks().unwrap()[0].cover, original);
}
