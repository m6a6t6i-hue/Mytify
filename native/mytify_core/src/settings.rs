//! Small app settings kept in the library database (folders chosen by the user).
//! Never used for passwords or tokens: those live in the system secure store.
use crate::catalog::Catalog;
use anyhow::Result;
use rusqlite::OptionalExtension;

fn ensure(db: &rusqlite::Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS app_settings(key TEXT PRIMARY KEY, value TEXT)")?;
    Ok(())
}

pub fn get(catalog: &Catalog, key: &str) -> Result<Option<String>> {
    let db = catalog.db()?;
    ensure(&db)?;
    let v: Option<String> = db.query_row("SELECT value FROM app_settings WHERE key=?1", [key], |r| r.get(0)).optional()?;
    Ok(v.filter(|s| !s.is_empty()))
}

pub fn set(catalog: &Catalog, key: &str, value: Option<&str>) -> Result<()> {
    let db = catalog.db()?;
    ensure(&db)?;
    match value.map(str::trim).filter(|v| !v.is_empty()) {
        Some(v) => db.execute(
            "INSERT INTO app_settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [key, v],
        )?,
        None => db.execute("DELETE FROM app_settings WHERE key=?1", [key])?,
    };
    Ok(())
}
