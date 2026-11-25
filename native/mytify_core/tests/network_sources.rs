use mytify_core::{
    catalog::{hash_file, Catalog, ScanRequest},
    sources::NetworkConfig,
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/fixtures")
        .join(name)
}

fn scan(catalog: &Catalog, request: ScanRequest) -> mytify_core::catalog::Report {
    catalog
        .scan(request, &AtomicBool::new(false), |_| {})
        .unwrap()
}

fn folder(path: &Path) -> ScanRequest {
    ScanRequest {
        paths: vec![path.to_string_lossy().into_owned()],
        folder: true,
        ..Default::default()
    }
}

fn source(id: &str) -> ScanRequest {
    ScanRequest {
        source_id: Some(id.into()),
        ..Default::default()
    }
}

fn smb(host: &str, share: &str, folder: &str) -> NetworkConfig {
    NetworkConfig {
        protocol: "smb".into(),
        host: host.into(),
        share: share.into(),
        folder: folder.into(),
        ..Default::default()
    }
}

#[test]
fn upgrade_to_v4_keeps_library_and_backup() {
    let music = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    fs::copy(fixture("sample.flac"), music.path().join("a.flac")).unwrap();
    let c = Catalog::open(data.path()).unwrap();
    scan(&c, folder(music.path()));
    let id = c.tracks().unwrap()[0].id.clone();
    c.like(&id, true).unwrap();
    drop(c);
    // Simulate a 0.14 catalog.
    let path = data.path().join("catalog.sqlite3");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("DROP TABLE source_settings; PRAGMA user_version=3;")
        .unwrap();
    drop(db);
    let c = Catalog::open(data.path()).unwrap();
    let tracks = c.tracks().unwrap();
    assert_eq!(tracks.len(), 1);
    assert!(tracks[0].liked);
    assert_eq!(tracks[0].id, id);
    let backup = rusqlite::Connection::open(data.path().join("catalog-before-0.15.sqlite3")).unwrap();
    assert_eq!(
        backup
            .pragma_query_value::<i64, _>(None, "user_version", |r| r.get(0))
            .unwrap(),
        3
    );
}

#[test]
fn unreachable_share_keeps_collection() {
    let music = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    fs::copy(fixture("sample.flac"), music.path().join("a.flac")).unwrap();
    let c = Catalog::open(data.path()).unwrap();
    scan(&c, folder(music.path()));
    let track = c.tracks().unwrap()[0].id.clone();
    // A share that cannot be reached from the test machine.
    let id = c
        .save_network_source(None, &smb("mytify-missing-nas.invalid", "music", "Albumy"))
        .unwrap();
    let sources = c.sources().unwrap();
    let nas = sources.iter().find(|s| s.id == id).unwrap();
    assert_eq!(nas.protocol, "smb");
    assert_eq!(nas.address, r"\\mytify-missing-nas.invalid\music\Albumy");
    assert!(!serde_json::to_string(&sources).unwrap().contains("password"));
    // The same track also lives on the NAS (as after an earlier scan).
    let db = rusqlite::Connection::open(data.path().join("catalog.sqlite3")).unwrap();
    db.execute(
        "INSERT INTO locations(source_id,path_key,path,track_id,size,modified,seen,available,display_name) VALUES(?1,'nas-a','nas-a',?2,1,'1','old',1,'a.flac')",
        rusqlite::params![id, track],
    )
    .unwrap();
    let report = scan(&c, source(&id));
    assert_eq!(report.offline_sources, 1);
    assert_eq!(report.missing, 0);
    let nas = c.sources().unwrap().into_iter().find(|s| s.id == id).unwrap();
    assert_eq!(nas.state, "offline");
    assert_eq!(nas.files, 1, "offline NAS must not lose its files");
    // One track, two locations, still playable from the local copy.
    let tracks = c.tracks().unwrap();
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0].location_count, 2);
    assert!(tracks[0].available);
    assert_eq!(
        hash_file(&c.audio_path(&track).unwrap()).unwrap(),
        track,
        "local copy is preferred over the network"
    );
    // Without the local copy the track stays in the library, unavailable.
    let local = c.sources().unwrap().into_iter().find(|s| s.kind == "folder").unwrap();
    c.forget_source(&local.id).unwrap();
    let tracks = c.tracks().unwrap();
    assert_eq!(tracks.len(), 1);
    assert!(!tracks[0].available);
}

#[test]
fn editing_share_settings_keeps_tracks_and_rejects_duplicates() {
    let data = tempfile::tempdir().unwrap();
    let c = Catalog::open(data.path()).unwrap();
    let id = c.save_network_source(None, &smb("nas", "music", "")).unwrap();
    assert!(c.save_network_source(None, &smb("NAS", "music", "")).is_err() || cfg!(not(windows)));
    let mut changed = smb("nas", "music", "Jazz");
    changed.name = "Jazz na NAS".into();
    assert_eq!(c.save_network_source(Some(&id), &changed).unwrap(), id);
    let saved = c.network_settings(&id).unwrap().unwrap();
    assert_eq!(saved.folder, "Jazz");
    assert_eq!(saved.name, "Jazz na NAS");
    assert!(c
        .save_network_source(None, &smb("nas", "music", "../x"))
        .is_err());
}

/// Real SMB share, set up by CI on Windows (see .github/workflows/windows.yml).
#[test]
fn real_share_scan_play_and_dedupe() {
    let Ok(host) = std::env::var("MYTIFY_SMB_HOST") else {
        eprintln!("MYTIFY_SMB_HOST not set, skipping real SMB test");
        return;
    };
    let share = std::env::var("MYTIFY_SMB_SHARE").unwrap();
    let user = std::env::var("MYTIFY_SMB_USER").unwrap();
    let password = std::env::var("MYTIFY_SMB_PASSWORD").unwrap();
    let local_copy = PathBuf::from(std::env::var("MYTIFY_SMB_LOCAL").unwrap());
    let data = tempfile::tempdir().unwrap();
    let c = Catalog::open(data.path()).unwrap();

    let mut wrong = smb(&host, &share, "");
    wrong.user = user.clone();
    wrong.password = Some("zle-haslo".into());
    let error = mytify_core::sources::test(None, &wrong).unwrap_err().to_string();
    eprintln!("wrong password: {error}");
    assert!(!error.contains("os error"), "readable error expected: {error}");

    let mut config = smb(&host, &share, "");
    config.user = user;
    config.password = Some(password);
    let folders = mytify_core::sources::test(None, &config).unwrap();
    assert!(folders.iter().any(|f| f == "Polskie ąę albumy"), "{folders:?}");
    let inner = mytify_core::sources::browse(None, &config, "Polskie ąę albumy").unwrap();
    eprintln!("inner folders: {inner:?}");

    // Same file on a local folder: must stay one track after the NAS scan.
    scan(&c, folder(&local_copy));
    let id = c.save_network_source(None, &config).unwrap();
    let report = scan(&c, source(&id));
    eprintln!("{report:?}");
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    let tracks = c.tracks().unwrap();
    let names: Vec<_> = tracks.iter().map(|t| (t.title.clone(), t.location_count)).collect();
    eprintln!("{names:?}");
    assert_eq!(tracks.len(), 2, "one shared track + one only on the NAS");
    assert!(tracks.iter().any(|t| t.location_count == 2));
    let nas_only = tracks.iter().find(|t| t.location_count == 1).unwrap();
    let path = c.audio_path(&nas_only.id).unwrap();
    assert_eq!(hash_file(&path).unwrap(), nas_only.id);

    // A second scan changes nothing.
    let again = scan(&c, source(&id));
    assert_eq!(again.added, 0);
    assert_eq!(c.tracks().unwrap().len(), 2);

    // Session dropped (sleep, network change): playback logs in again by itself.
    mytify_core::smb::disconnect(&format!(r"\\{host}\{share}"));
    let path = c.audio_path(&nas_only.id).unwrap();
    assert_eq!(hash_file(&path).unwrap(), nas_only.id);
    c.forget_source(&id).unwrap();
}
