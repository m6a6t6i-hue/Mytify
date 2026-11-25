//! SMB 2/3 through the Windows network client: an authenticated session to
//! \\host\share without a drive letter. Windows negotiates the dialect itself
//! (SMB1 is off by default on current Windows and never requested here).

use anyhow::{bail, Result};

/// Readable reason for a Win32 network error code. No codes on main screens.
pub fn message(code: u32) -> String {
    match code {
        5 => "Brak dostępu do udziału dla tego konta.".into(),
        53 => "Nie znaleziono serwera. Sprawdź adres i czy komputer jest w tej samej sieci.".into(),
        67 => "Serwer nie ma udziału o tej nazwie.".into(),
        86 | 1326 | 2202 | 1244 => "Nieprawidłowy użytkownik lub hasło.".into(),
        64 => "Połączenie z serwerem zostało przerwane.".into(),
        121 | 1460 => "Serwer nie odpowiada.".into(),
        1203 | 1222 => "Brak połączenia z siecią.".into(),
        1231 | 1232 => "Serwer jest nieosiągalny.".into(),
        1219 => "Windows ma już połączenie z tym serwerem na innym koncie. Użyj tego samego konta.".into(),
        1311 => "Nie można sprawdzić konta w domenie.".into(),
        1327..=1331 | 1909 => "Konto na serwerze jest zablokowane albo wygasło.".into(),
        3 | 2 => "Folder nie istnieje.".into(),
        _ => format!("Nie można połączyć z udziałem (kod {code})."),
    }
}

/// Readable text for a file system error on a network path.
pub fn io_message(error: &std::io::Error) -> String {
    match error.raw_os_error() {
        Some(code) if code > 0 => message(code as u32),
        _ => match error.kind() {
            std::io::ErrorKind::NotFound => "Folder nie istnieje.".into(),
            std::io::ErrorKind::PermissionDenied => "Brak dostępu do folderu.".into(),
            _ => "Nie można odczytać folderu.".into(),
        },
    }
}

#[cfg(windows)]
pub fn connect(remote: &str, user: &str, password: &str) -> Result<()> {
    use windows_sys::Win32::NetworkManagement::WNet::{
        WNetAddConnection2W, WNetCancelConnection2W, CONNECT_TEMPORARY, NETRESOURCEW,
        RESOURCETYPE_DISK,
    };
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }
    let mut remote_w = wide(remote);
    let user_w = wide(user);
    let password_w = wide(password);
    let resource = NETRESOURCEW {
        dwType: RESOURCETYPE_DISK,
        lpRemoteName: remote_w.as_mut_ptr(),
        ..Default::default()
    };
    // Empty login means "use my Windows account" (null pointers).
    let (user_ptr, password_ptr) = if user.is_empty() {
        (std::ptr::null(), std::ptr::null())
    } else {
        (user_w.as_ptr(), password_w.as_ptr())
    };
    for attempt in 0..2 {
        let code = unsafe { WNetAddConnection2W(&resource, password_ptr, user_ptr, CONNECT_TEMPORARY) };
        match code {
            0 | 85 => return Ok(()),
            // Our own older session with other credentials: drop only that one and retry.
            1219 if attempt == 0 => unsafe {
                WNetCancelConnection2W(remote_w.as_ptr(), 0, 1);
            },
            code => bail!(message(code)),
        }
    }
    bail!(message(1219))
}

#[cfg(windows)]
pub fn disconnect(remote: &str) {
    use windows_sys::Win32::NetworkManagement::WNet::WNetCancelConnection2W;
    let remote_w: Vec<u16> = remote.encode_utf16().chain(Some(0)).collect();
    unsafe {
        WNetCancelConnection2W(remote_w.as_ptr(), 0, 1);
    }
}

#[cfg(not(windows))]
pub fn connect(_remote: &str, _user: &str, _password: &str) -> Result<()> {
    bail!("Foldery sieciowe SMB są dostępne w Mytify na Windows i Androidzie.")
}

#[cfg(not(windows))]
pub fn disconnect(_remote: &str) {}
