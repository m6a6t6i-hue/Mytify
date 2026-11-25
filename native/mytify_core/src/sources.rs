//! Network music sources. The protocol layer only delivers files and folders;
//! scanning, identity (content hash) and playback stay in the catalog and engine.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Connection settings of a network source. The password is never stored here:
/// it lives in the system credential store and never comes back to the UI.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NetworkConfig {
    pub protocol: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub share: String,
    #[serde(default)]
    pub folder: String,
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub domain: String,
    #[serde(default)]
    pub url: String,
    /// Only on input. `None` keeps the stored password when editing.
    #[serde(default, skip_serializing)]
    pub password: Option<String>,
}

/// Protocols that really work in this build. The UI shows nothing else.
pub fn protocols() -> Vec<&'static str> {
    if cfg!(windows) {
        vec!["smb", "webdav"]
    } else {
        vec!["webdav"]
    }
}

/// What a source of the given kind can do. Not every source does everything.
pub fn capabilities(kind: &str) -> Vec<&'static str> {
    match kind {
        "folder" | "smb" | "webdav" => vec!["browse", "scan", "tags", "artwork", "stream", "seek", "refresh"],
        "files" | "managed" => vec!["tags", "artwork", "stream", "seek", "refresh"],
        _ => vec!["stream", "seek"],
    }
}

fn bad_char(c: char) -> bool {
    c.is_control() || matches!(c, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
}

/// Accepts "nas", "nas.local", "192.168.1.10". Strips a pasted "\\" or "smb://".
pub fn clean_host(host: &str) -> Result<String> {
    let h = host
        .trim()
        .trim_start_matches("smb://")
        .trim_start_matches(r"\\")
        .trim_end_matches(['/', '\\']);
    if h.is_empty() {
        bail!("Podaj adres serwera.");
    }
    if h.len() > 253
        || !h
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
    {
        bail!("Adres serwera może zawierać tylko litery, cyfry, kropki i myślniki.");
    }
    Ok(h.to_string())
}

pub fn clean_share(share: &str) -> Result<String> {
    let s = share.trim().trim_matches(['/', '\\']);
    if s.is_empty() {
        bail!("Podaj nazwę udziału.");
    }
    if s.len() > 80 || s.chars().any(bad_char) {
        bail!("Nazwa udziału zawiera niedozwolone znaki.");
    }
    Ok(s.to_string())
}

/// Folder inside the share as clean segments. Never allows going up.
pub fn folder_segments(folder: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for part in folder.split(['/', '\\']) {
        let part = part.trim();
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." || part.chars().any(bad_char) {
            bail!("Ścieżka folderu jest nieprawidłowa.");
        }
        out.push(part.to_string());
    }
    Ok(out)
}

/// Normalised SMB settings, or a readable reason why they are wrong.
pub fn clean_smb(config: &NetworkConfig) -> Result<NetworkConfig> {
    let host = clean_host(&config.host)?;
    let share = clean_share(&config.share)?;
    let folder = folder_segments(&config.folder)?.join("/");
    let user = config.user.trim().to_string();
    let domain = config.domain.trim().to_string();
    if user.len() > 256 || domain.len() > 256 || user.contains('\\') && !domain.is_empty() {
        bail!("Nazwa użytkownika jest nieprawidłowa.");
    }
    let name = match config.name.trim() {
        "" => folder
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or(&share)
            .to_string(),
        n => n.chars().take(80).collect(),
    };
    Ok(NetworkConfig {
        protocol: "smb".into(),
        name,
        host,
        share,
        folder,
        user,
        domain,
        url: String::new(),
        password: config.password.clone(),
    })
}

/// Normalised WebDAV settings. The folder is kept apart from the server address.
pub fn clean_webdav(config: &NetworkConfig) -> Result<NetworkConfig> {
    let url = crate::webdav::clean_url(&config.url)?;
    let folder = folder_segments(&config.folder)?.join("/");
    let user = config.user.trim().to_string();
    if user.len() > 256 {
        bail!("Nazwa użytkownika jest nieprawidłowa.");
    }
    let name = match config.name.trim() {
        "" => folder
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| {
                let last = crate::webdav::decoded_name(url.path());
                if last.is_empty() { url.host_str().unwrap_or("WebDAV").to_string() } else { last }
            }),
        n => n.chars().take(80).collect(),
    };
    Ok(NetworkConfig {
        protocol: "webdav".into(),
        name,
        url: url.to_string(),
        folder,
        user,
        password: config.password.clone(),
        ..Default::default()
    })
}

pub fn clean(config: &NetworkConfig) -> Result<NetworkConfig> {
    match config.protocol.as_str() {
        "smb" => clean_smb(config),
        "webdav" => clean_webdav(config),
        _ => bail!("Ten rodzaj źródła nie jest dostępny w tej wersji."),
    }
}

/// Folder URL of a WebDAV source: server address plus the chosen folder, trailing slash.
pub fn webdav_root(config: &NetworkConfig, extra: &str) -> Result<url::Url> {
    let mut url = crate::webdav::clean_url(&config.url)?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| anyhow::anyhow!("Adres serwera jest nieprawidłowy."))?;
        segments.pop_if_empty();
        for part in folder_segments(&config.folder)?.into_iter().chain(folder_segments(extra)?) {
            segments.push(&part);
        }
        segments.push("");
    }
    Ok(url)
}

/// WebDAV client of a saved source (cached) or of a form that is not saved yet.
pub fn dav(source_id: Option<&str>, config: &NetworkConfig) -> Result<std::sync::Arc<crate::webdav::Dav>> {
    let make = || {
        let password = match (&config.password, source_id) {
            (Some(p), _) => p.clone(),
            (None, Some(id)) => crate::secrets::load(id)?.unwrap_or_default(),
            (None, None) => String::new(),
        };
        crate::webdav::Dav::new(webdav_root(config, "")?, &config.user, &password)
    };
    match source_id {
        Some(id) if config.password.is_none() => crate::webdav::client(id, make),
        _ => Ok(std::sync::Arc::new(make()?)),
    }
}

/// "\\host\share" as Windows expects it for a network connection.
pub fn share_root(config: &NetworkConfig) -> String {
    format!(r"\\{}\{}", config.host, config.share)
}

/// Readable address shown in the UI, without any credentials.
pub fn smb_address(config: &NetworkConfig) -> String {
    let mut out = share_root(config);
    for part in config.folder.split('/').filter(|s| !s.is_empty()) {
        out.push('\\');
        out.push_str(part);
    }
    out
}

/// Root used for scanning. On Windows the verbatim form lifts the 260 character limit.
pub fn smb_scan_root(config: &NetworkConfig) -> PathBuf {
    let mut root = if cfg!(windows) {
        PathBuf::from(format!(r"\\?\UNC\{}\{}", config.host, config.share))
    } else {
        PathBuf::from(share_root(config))
    };
    for part in config.folder.split('/').filter(|s| !s.is_empty()) {
        root.push(part);
    }
    root
}

pub fn login_name(config: &NetworkConfig) -> String {
    if config.domain.is_empty() {
        config.user.clone()
    } else {
        format!(r"{}\{}", config.domain, config.user)
    }
}

/// Opens (or refreshes) the authenticated session to the share. No drive letter.
pub fn connect(source_id: Option<&str>, config: &NetworkConfig) -> Result<()> {
    match config.protocol.as_str() {
        "smb" => {
            let password = match (&config.password, source_id) {
                (Some(p), _) => p.clone(),
                (None, Some(id)) => crate::secrets::load(id)?.unwrap_or_default(),
                (None, None) => String::new(),
            };
            crate::smb::connect(&share_root(config), &login_name(config), &password)
        }
        "webdav" => {
            let dav = dav(source_id, config)?;
            dav.list(dav.base()).map(|_| ())
        }
        _ => bail!("Ten rodzaj źródła nie jest dostępny w tej wersji."),
    }
}

/// Lists subfolders of `path` (relative to the share) for the folder picker.
pub fn browse(source_id: Option<&str>, config: &NetworkConfig, path: &str) -> Result<Vec<String>> {
    if config.protocol == "webdav" {
        let config = clean_webdav(&NetworkConfig { folder: String::new(), ..config.clone() })?;
        let dav = dav(None, &NetworkConfig { password: config.password.clone().or(source_id.and_then(|id| crate::secrets::load(id).ok().flatten())), ..config.clone() })?;
        let mut names: Vec<String> = dav
            .list(&webdav_root(&config, path)?)?
            .into_iter()
            .filter(|e| e.dir && !e.name.starts_with('.') && !e.name.starts_with('#') && e.name != "@eaDir")
            .map(|e| e.name)
            .collect();
        names.sort_by_key(|s| crate::catalog::search_key(s));
        return Ok(names);
    }
    let config = clean_smb(config)?;
    connect(source_id, &config)?;
    let mut root = smb_scan_root(&NetworkConfig {
        folder: String::new(),
        ..config.clone()
    });
    for part in folder_segments(path)? {
        root.push(part);
    }
    list_dirs(&root)
}

fn list_dirs(path: &Path) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(path).map_err(|e| anyhow::anyhow!(crate::smb::io_message(&e)))? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.starts_with('#') || name == "@eaDir" {
            continue;
        }
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            out.push(name);
        }
    }
    out.sort_by_key(|s| crate::catalog::search_key(s));
    Ok(out)
}

/// Connection test used by the form: logs in and reads the chosen folder.
pub fn test(source_id: Option<&str>, config: &NetworkConfig) -> Result<Vec<String>> {
    if config.protocol == "webdav" {
        let config = clean_webdav(config)?;
        let password = config.password.clone().or(source_id.and_then(|id| crate::secrets::load(id).ok().flatten()));
        let dav = dav(None, &NetworkConfig { password, ..config.clone() })?;
        let mut names: Vec<String> =
            dav.list(dav.base())?.into_iter().filter(|e| e.dir).map(|e| e.name).collect();
        names.sort_by_key(|s| crate::catalog::search_key(s));
        return Ok(names);
    }
    let config = clean_smb(config)?;
    connect(source_id, &config)?;
    list_dirs(&smb_scan_root(&config))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(host: &str, share: &str, folder: &str) -> NetworkConfig {
        NetworkConfig {
            protocol: "smb".into(),
            host: host.into(),
            share: share.into(),
            folder: folder.into(),
            ..Default::default()
        }
    }

    #[test]
    fn cleans_pasted_addresses() {
        let c = clean_smb(&cfg(r"\\Synology\", "/music/", r"\Albumy\Polskie ąę/")).unwrap();
        assert_eq!(c.host, "Synology");
        assert_eq!(c.share, "music");
        assert_eq!(c.folder, "Albumy/Polskie ąę");
        assert_eq!(c.name, "Polskie ąę");
        assert_eq!(smb_address(&c), r"\\Synology\music\Albumy\Polskie ąę");
        assert_eq!(clean_smb(&cfg("smb://nas.local", "m", "")).unwrap().host, "nas.local");
    }

    #[test]
    fn rejects_escapes_and_bad_names() {
        assert!(clean_smb(&cfg("nas", "music", "../etc")).is_err());
        assert!(clean_smb(&cfg("nas", "mu:sic", "")).is_err());
        assert!(clean_smb(&cfg("nas/x", "music", "")).is_err());
        assert!(clean_smb(&cfg("", "music", "")).is_err());
        assert!(clean_smb(&cfg("nas", "", "")).is_err());
    }

    #[test]
    fn password_is_never_serialized() {
        let mut c = cfg("nas", "music", "");
        c.password = Some("tajne".into());
        let text = serde_json::to_string(&c).unwrap();
        assert!(!text.contains("tajne"));
        assert!(!text.contains("password"));
    }

    #[test]
    fn domain_login() {
        let mut c = cfg("nas", "music", "");
        c.user = "mat".into();
        assert_eq!(login_name(&c), "mat");
        c.domain = "DOM".into();
        assert_eq!(login_name(&c), r"DOM\mat");
    }
}
