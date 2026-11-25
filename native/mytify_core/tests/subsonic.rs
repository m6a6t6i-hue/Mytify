//! OpenSubsonic against a real Navidrome (started by CI or locally).
use mytify_core::{
    catalog::{Catalog, ScanRequest},
    sources::NetworkConfig,
    transfer::Transfer,
};
use std::{
    io::{Read, Seek, SeekFrom},
    path::Path,
    sync::{atomic::AtomicBool, Arc},
};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/fixtures").join(name)).unwrap()
}

fn server(url: &str, user: &str, password: &str) -> NetworkConfig {
    NetworkConfig {
        protocol: "subsonic".into(),
        url: url.into(),
        user: user.into(),
        password: Some(password.into()),
        ..Default::default()
    }
}

fn scan(c: &Catalog, id: &str) -> mytify_core::catalog::Report {
    c.scan(ScanRequest { source_id: Some(id.into()), ..Default::default() }, &AtomicBool::new(false), |_| {}).unwrap()
}

#[test]
fn navidrome_library_likes_plays_playlists() {
    let Ok(url) = std::env::var("MYTIFY_SUBSONIC_URL") else {
        eprintln!("MYTIFY_SUBSONIC_URL not set, skipping");
        return;
    };
    let user = std::env::var("MYTIFY_SUBSONIC_USER").unwrap();
    let password = std::env::var("MYTIFY_SUBSONIC_PASSWORD").unwrap();

    let wrong = mytify_core::sources::describe(None, &server(&url, &user, "zle")).unwrap_err().to_string();
    assert_eq!(wrong, "Nieprawidłowy użytkownik lub hasło.");
    let about = mytify_core::sources::describe(None, &server(&url, &user, &password)).unwrap();
    eprintln!("{about}");
    assert!(about.to_lowercase().contains("navidrome"), "{about}");

    let data = tempfile::tempdir().unwrap();
    let c = Arc::new(Catalog::open(data.path()).unwrap());
    let transfer = Transfer::new(c.clone()).unwrap();
    let id = c.save_network_source(None, &server(&url, &user, &password)).unwrap();
    let first = scan(&c, &id);
    eprintln!("{first:?}");
    assert_eq!(first.added, 2, "{:?}", first.errors);
    assert_eq!(scan(&c, &id).unchanged, 2, "a rescan only reads the server index");

    let tracks = c.tracks().unwrap();
    let flac = tracks.iter().find(|t| t.format == "FLAC").unwrap().clone();
    let mp3 = tracks.iter().find(|t| t.format == "MP3").unwrap().clone();
    assert_eq!(mp3.bit_depth, 0, "no PCM bit depth for MP3");

    // Original file, with seeking.
    let bytes = fixture("sample.flac");
    let mut input = c.open_audio(&flac.id).unwrap();
    assert_eq!(input.len, bytes.len() as u64);
    input.reader.seek(SeekFrom::Start(3000)).unwrap();
    let mut tail = Vec::new();
    input.reader.read_to_end(&mut tail).unwrap();
    assert_eq!(tail, bytes[3000..]);

    // Like here -> star on the server.
    c.like(&flac.id, true).unwrap();
    assert_eq!(c.flush_pending(&id).unwrap(), 1);
    let client = mytify_core::sources::subsonic(Some(&id), &c.network_settings(&id).unwrap().unwrap()).unwrap();
    let starred = client.call("getStarred2", &[]).unwrap();
    assert_eq!(starred["starred2"]["song"].as_array().map(|a| a.len()), Some(1));
    // Unstarred on the server (another app) -> follows here.
    let song = starred["starred2"]["song"][0]["id"].as_str().unwrap().to_string();
    client.star(&song, false).unwrap();
    scan(&c, &id);
    assert!(!c.tracks().unwrap().iter().find(|t| t.id == flac.id).unwrap().liked);
    // A local change waiting to be sent is not overwritten by the server state.
    c.like(&mp3.id, true).unwrap();
    let report = c
        .scan(ScanRequest { source_id: Some(id.clone()), ..Default::default() }, &AtomicBool::new(false), |_| {})
        .unwrap();
    assert!(report.errors.is_empty(), "{:?}", report.errors);
    assert!(c.tracks().unwrap().iter().find(|t| t.id == mp3.id).unwrap().liked);

    // A finished play is scrobbled.
    c.played(&flac.id).unwrap();
    assert_eq!(c.flush_pending(&id).unwrap(), 0, "nothing left waiting");

    // Playlists: import, local edit sent back, both edited -> copy, nothing lost.
    let songs: Vec<String> = client.songs(0, 10).unwrap().into_iter().map(|s| s.id).collect();
    let remote = client.save_playlist(None, "Na drogę", &songs[..1]).unwrap();
    let r = mytify_core::playlist_sync::sync(&c, &transfer, &id).unwrap();
    assert_eq!(r.imported, 1);
    let (local, name, ids) = transfer.playlist_entries().into_iter().find(|p| p.1 == "Na drogę").unwrap();
    assert_eq!(ids.len(), 1);
    let both: Vec<String> = vec![flac.id.clone(), mp3.id.clone()];
    transfer.put_playlist(Some(&local), &name, both.clone()).unwrap();
    let r = mytify_core::playlist_sync::sync(&c, &transfer, &id).unwrap();
    assert_eq!(r.sent, 1);
    assert_eq!(client.call("getPlaylist", &[("id", remote.clone())]).unwrap()["playlist"]["songCount"], 2);
    // Now both sides change.
    client.save_playlist(Some(&remote), "Na drogę", &songs[..1]).unwrap();
    transfer.put_playlist(Some(&local), &name, vec![mp3.id.clone()]).unwrap();
    let r = mytify_core::playlist_sync::sync(&c, &transfer, &id).unwrap();
    assert_eq!(r.conflicts, 1);
    let all = transfer.playlist_entries();
    assert!(all.iter().any(|p| p.0 == local && p.2 == vec![mp3.id.clone()]), "local edit kept");
    assert!(all.iter().any(|p| p.1 == "Na drogę (z serwera)" && p.2.len() == 1), "server version kept");
    client.call("deletePlaylist", &[("id", remote)]).unwrap();
    c.forget_source(&id).unwrap();
}
