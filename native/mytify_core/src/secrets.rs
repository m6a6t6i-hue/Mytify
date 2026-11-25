//! Passwords of network sources in the system credential store
//! (Windows Credential Manager). Never in the catalog, logs or the UI.

use anyhow::Result;

fn target(id: &str) -> String {
    format!("Mytify/source/{id}")
}

#[cfg(windows)]
mod imp {
    use anyhow::{bail, Result};
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE,
        CRED_TYPE_GENERIC,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    pub fn store(target: &str, user: &str, secret: &str) -> Result<()> {
        let mut target_w = wide(target);
        let mut user_w = wide(user);
        let mut blob: Vec<u8> = secret.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target_w.as_mut_ptr(),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: user_w.as_mut_ptr(),
            ..Default::default()
        };
        let ok = unsafe { CredWriteW(&credential, 0) };
        blob.iter_mut().for_each(|b| *b = 0);
        if ok == 0 {
            bail!("Nie można zapisać hasła w Menedżerze poświadczeń Windows.");
        }
        Ok(())
    }

    pub fn load(target: &str) -> Result<Option<String>> {
        let target_w = wide(target);
        let mut out: *mut CREDENTIALW = std::ptr::null_mut();
        let ok = unsafe { CredReadW(target_w.as_ptr(), CRED_TYPE_GENERIC, 0, &mut out) };
        if ok == 0 || out.is_null() {
            return Ok(None);
        }
        let secret = unsafe {
            let c = &*out;
            let bytes = std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize);
            let units: Vec<u16> = bytes
                .chunks_exact(2)
                .map(|p| u16::from_le_bytes([p[0], p[1]]))
                .collect();
            let text = String::from_utf16_lossy(&units);
            CredFree(out as *const _);
            text
        };
        Ok(Some(secret))
    }

    pub fn delete(target: &str) {
        let target_w = wide(target);
        unsafe {
            CredDeleteW(target_w.as_ptr(), CRED_TYPE_GENERIC, 0);
        }
    }
}

#[cfg(all(not(windows), not(feature = "memory-secrets")))]
mod imp {
    use anyhow::{bail, Result};
    pub fn store(_target: &str, _user: &str, _secret: &str) -> Result<()> {
        bail!("Brak bezpiecznego magazynu haseł na tej platformie.")
    }
    pub fn load(_target: &str) -> Result<Option<String>> {
        Ok(None)
    }
    pub fn delete(_target: &str) {}
}

/// Test builds only: nothing is written to disk.
#[cfg(all(not(windows), feature = "memory-secrets"))]
mod imp {
    use anyhow::Result;
    use std::{collections::HashMap, sync::Mutex};
    static STORE: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);
    pub fn store(target: &str, _user: &str, secret: &str) -> Result<()> {
        STORE.lock().unwrap().get_or_insert_with(HashMap::new).insert(target.into(), secret.into());
        Ok(())
    }
    pub fn load(target: &str) -> Result<Option<String>> {
        Ok(STORE.lock().unwrap().as_ref().and_then(|m| m.get(target).cloned()))
    }
    pub fn delete(target: &str) {
        if let Some(m) = STORE.lock().unwrap().as_mut() {
            m.remove(target);
        }
    }
}

pub fn store(id: &str, user: &str, secret: &str) -> Result<()> {
    imp::store(&target(id), user, secret)
}

pub fn load(id: &str) -> Result<Option<String>> {
    imp::load(&target(id))
}

pub fn delete(id: &str) {
    imp::delete(&target(id))
}
