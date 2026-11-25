//! Playlists shared with a music server (OpenSubsonic). Server playlists appear as local
//! ones; local edits are sent back. When both sides changed, nothing is overwritten:
//! the server version arrives as a separate copy.

use crate::{catalog::Catalog, remote_scan::remote_id, transfer::Transfer};
use anyhow::Result;
use rusqlite::params;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Default)]
pub struct SyncReport {
    pub imported: u32,
    pub updated: u32,
    pub sent: u32,
    pub conflicts: u32,
}

fn fingerprint(name: &str, ids: &[String]) -> String {
    crate::catalog::hex(Sha256::digest(format!("{name}\n{}", ids.join("\n")).as_bytes()))
}

pub fn sync(catalog: &Catalog, transfer: &Transfer, source: &str) -> Result<SyncReport> {
    let mut report = SyncReport::default();
    let client = catalog.subsonic_client(source)?;
    let server = client.playlists()?;
    let db = catalog.db()?;
    let known: HashSet<String> = {
        let mut stmt = db.prepare("SELECT track_id FROM locations WHERE source_id=?1")?;
        let rows = stmt.query_map([source], |r| r.get(0))?.collect::<rusqlite::Result<HashSet<String>>>()?;
        rows
    };
    // Local track id -> song id on this server, for sending local edits.
    let song_of: HashMap<String, String> = {
        let mut stmt = db.prepare("SELECT track_id,path FROM locations WHERE source_id=?1")?;
        let rows = stmt.query_map([source], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<HashMap<_, _>>>()?;
        rows
    };
    let mut links: HashMap<String, (String, String, String)> = {
        let mut stmt = db.prepare("SELECT remote_id,local_id,server_hash,local_hash FROM remote_playlists WHERE source_id=?1")?;
        let rows = stmt
            .query_map([source], |r| Ok((r.get::<_, String>(0)?, (r.get(1)?, r.get(2)?, r.get(3)?))))?
            .collect::<rusqlite::Result<HashMap<_, _>>>()?;
        rows
    };
    drop(db);
    let locals: HashMap<String, (String, Vec<String>)> =
        transfer.playlist_entries().into_iter().map(|(id, name, ids)| (id, (name, ids))).collect();
    let save = |remote: &str, local: &str, server_hash: &str, local_hash: &str| -> Result<()> {
        catalog.db()?.execute(
            "INSERT INTO remote_playlists(source_id,remote_id,local_id,server_hash,local_hash) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(source_id,remote_id) DO UPDATE SET local_id=excluded.local_id,server_hash=excluded.server_hash,local_hash=excluded.local_hash",
            params![source, remote, local, server_hash, local_hash],
        )?;
        Ok(())
    };
    let mut seen = HashSet::new();
    for p in &server {
        seen.insert(p.id.clone());
        let ids: Vec<String> = p
            .songs
            .iter()
            .map(|s| remote_id(source, &s.id))
            .filter(|id| known.contains(id))
            .collect();
        let server_hash = fingerprint(&p.name, &ids);
        match links.remove(&p.id) {
            None => {
                let local = transfer.put_playlist(None, &p.name, ids.clone())?;
                save(&p.id, &local, &server_hash, &fingerprint(&p.name, &ids))?;
                report.imported += 1;
            }
            // Deleted here on purpose: stays deleted, the server copy is not touched.
            Some((local, ..)) if local.is_empty() => save(&p.id, "", &server_hash, "")?,
            Some((local, old_server, old_local)) => {
                let Some((name, local_ids)) = locals.get(&local) else {
                    save(&p.id, "", &server_hash, "")?;
                    continue;
                };
                let local_hash = fingerprint(name, local_ids);
                let server_changed = server_hash != old_server;
                let local_changed = local_hash != old_local;
                match (server_changed, local_changed) {
                    (false, false) => {}
                    (true, false) => {
                        transfer.put_playlist(Some(&local), &p.name, ids.clone())?;
                        save(&p.id, &local, &server_hash, &fingerprint(&p.name, &ids))?;
                        report.updated += 1;
                    }
                    (false, true) => {
                        // Only songs that live on this server can be sent; others stay local.
                        let songs: Vec<String> = local_ids.iter().filter_map(|t| song_of.get(t).cloned()).collect();
                        let sent: Vec<String> = local_ids.iter().filter(|t| song_of.contains_key(*t)).cloned().collect();
                        client.save_playlist(Some(&p.id), name, &songs)?;
                        save(&p.id, &local, &fingerprint(name, &sent), &local_hash)?;
                        report.sent += 1;
                    }
                    (true, true) => {
                        // Both changed: keep the local edit and bring the server version as a copy.
                        let copy = transfer.put_playlist(None, &format!("{} (z serwera)", p.name), ids.clone())?;
                        save(&p.id, &copy, &server_hash, &fingerprint(&format!("{} (z serwera)", p.name), &ids))?;
                        report.conflicts += 1;
                    }
                }
            }
        }
    }
    // Removed on the server: the local playlist stays, only the link goes.
    for remote in links.keys() {
        if !seen.contains(remote) {
            catalog
                .db()?
                .execute("DELETE FROM remote_playlists WHERE source_id=?1 AND remote_id=?2", params![source, remote])?;
        }
    }
    Ok(report)
}
