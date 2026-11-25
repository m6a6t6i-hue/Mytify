use anyhow::{bail, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CdTrack {
    pub number: u8,
    pub start: u32,
    pub end: u32,
    pub data: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Toc {
    pub drive: String,
    pub disc_id: String,
    pub tracks: Vec<CdTrack>,
    pub leadout: u32,
}
pub fn parse_toc(drive: &str, b: &[u8]) -> Result<Toc> {
    if b.len() < 20 {
        bail!("Niepełna tabela płyty")
    };
    let first = b[2];
    let last = b[3];
    if first == 0 || last < first || last > 99 {
        bail!("Nieprawidłowa tabela płyty")
    };
    let n = (last - first + 1) as usize;
    if b.len() < 4 + (n + 1) * 8 {
        bail!("Niepełna tabela płyty")
    };
    let offset = |i: usize| -> Result<u32> {
        let k = 4 + i * 8;
        if b[k + 6] >= 60 || b[k + 7] >= 75 {
            bail!("Nieprawidłowy offset CD")
        };
        let v = (b[k + 5] as u32 * 60 + b[k + 6] as u32) * 75 + b[k + 7] as u32;
        v.checked_sub(150)
            .ok_or_else(|| anyhow::anyhow!("Nieprawidłowy początek CD"))
    };
    let leadout = offset(n)?;
    let mut tracks = Vec::new();
    for i in 0..n {
        let start = offset(i)?;
        let end = offset(i + 1)?;
        if start >= end || end > 75 * 60 * 120 || b[4 + i * 8 + 2] != first + i as u8 {
            bail!("Nieprawidłowa kolejność ścieżek CD")
        };
        tracks.push(CdTrack {
            number: first + i as u8,
            start,
            end,
            data: b[4 + i * 8 + 1] & 4 != 0,
        })
    }
    // Mixed-mode/CD-Extra lead-out needs session-aware TOC. Reject rather than silently truncate audio.
    if tracks.iter().any(|t| t.data) {
        bail!("Płyta zawiera ścieżki z danymi (CD-Extra, CD-ROM lub DVD). Mytify importuje tylko płyty Audio CD.")
    };
    let mut ascii = format!("{first:02X}{last:02X}{:08X}", leadout + 150);
    for number in 1..=99 {
        ascii.push_str(&format!(
            "{:08X}",
            tracks
                .iter()
                .find(|t| t.number == number)
                .map(|t| t.start + 150)
                .unwrap_or(0)
        ))
    }
    let hash = Sha1::digest(ascii.as_bytes());
    let disc_id = base64::engine::general_purpose::STANDARD
        .encode(hash)
        .replace('+', ".")
        .replace('/', "_")
        .replace('=', "-");
    Ok(Toc {
        drive: drive.into(),
        disc_id,
        tracks,
        leadout,
    })
}
#[cfg(windows)]
pub mod device {
    use super::*;
    use std::{ffi::c_void, ptr};
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetLogicalDrives() -> u32;
        fn GetDriveTypeW(root: *const u16) -> u32;
        fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            security: *const c_void,
            creation: u32,
            flags: u32,
            template: *mut c_void,
        ) -> *mut c_void;
        fn DeviceIoControl(
            handle: *mut c_void,
            code: u32,
            input: *const c_void,
            input_len: u32,
            output: *mut c_void,
            output_len: u32,
            returned: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
        fn CloseHandle(handle: *mut c_void) -> i32;
    }
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }
    pub fn drives() -> Vec<String> {
        let mask = unsafe { GetLogicalDrives() };
        (0..26)
            .filter(|n| mask & (1 << n) != 0)
            .map(|n| format!("{}:", (b'A' + n as u8) as char))
            .filter(|s| unsafe { GetDriveTypeW(wide(&format!("{s}\\")).as_ptr()) } == 5)
            .collect()
    }
    /// Vendor and model reported by the drive, e.g. "ASUS SDRW-08U9M-U". None if it does not answer.
    pub fn name(id: &str) -> Option<String> {
        let h = unsafe {
            CreateFileW(
                wide(&format!("\\\\.\\{id}")).as_ptr(),
                0,
                3,
                ptr::null(),
                3,
                0,
                ptr::null_mut(),
            )
        };
        if h as isize == -1 {
            return None;
        }
        let drive = Drive(h);
        // STORAGE_PROPERTY_QUERY { StorageDeviceProperty, PropertyStandardQuery }
        let query = [0u32; 3];
        let mut b = [0u8; 1024];
        let mut n = 0;
        let ok = unsafe {
            DeviceIoControl(
                drive.0,
                0x2D1400,
                query.as_ptr().cast(),
                std::mem::size_of_val(&query) as u32,
                b.as_mut_ptr().cast(),
                b.len() as u32,
                &mut n,
                ptr::null_mut(),
            )
        };
        if ok == 0 || n < 20 {
            return None;
        }
        let text = |at: usize| -> Option<String> {
            let offset = u32::from_le_bytes(b[at..at + 4].try_into().ok()?) as usize;
            if offset == 0 || offset >= n as usize {
                return None;
            }
            let end = b[offset..n as usize].iter().position(|c| *c == 0)? + offset;
            let s = String::from_utf8_lossy(&b[offset..end]).trim().to_string();
            (!s.is_empty()).then_some(s)
        };
        let name = [text(12), text(16)].into_iter().flatten().collect::<Vec<_>>().join(" ");
        (!name.is_empty()).then_some(name)
    }
    pub struct Drive(*mut c_void);
    impl Drop for Drive {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    impl Drive {
        pub fn open(id: &str) -> Result<Self> {
            if !drives().iter().any(|s| s == id) {
                bail!("Wybierz dostępny napęd optyczny")
            };
            let h = unsafe {
                CreateFileW(
                    wide(&format!("\\\\.\\{id}")).as_ptr(),
                    0x80000000,
                    3,
                    ptr::null(),
                    3,
                    0,
                    ptr::null_mut(),
                )
            };
            if h as isize == -1 {
                bail!(
                    "Nie można otworzyć napędu: {}",
                    std::io::Error::last_os_error()
                )
            };
            Ok(Self(h))
        }
        pub fn toc(&self, id: &str) -> Result<Toc> {
            let mut b = [0u8; 804];
            let mut n = 0;
            let ok = unsafe {
                DeviceIoControl(
                    self.0,
                    0x24000,
                    ptr::null(),
                    0,
                    b.as_mut_ptr().cast(),
                    b.len() as u32,
                    &mut n,
                    ptr::null_mut(),
                )
            };
            if ok == 0 {
                let e = std::io::Error::last_os_error();
                // ERROR_NOT_READY: the tray is empty or the disc is still spinning up.
                if e.raw_os_error() == Some(21) {
                    bail!("Brak płyty w napędzie.")
                }
                bail!("Nie można odczytać płyty: {e}")
            };
            parse_toc(id, &b[..n as usize])
        }
        pub fn read(&self, lba: u32, sectors: u32) -> Result<Vec<u8>> {
            #[repr(C)]
            struct Raw {
                offset: i64,
                count: u32,
                mode: i32,
            }
            let raw = Raw {
                offset: lba as i64 * 2048,
                count: sectors,
                mode: 2,
            };
            let mut b = vec![0; sectors as usize * 2352];
            let mut n = 0;
            let ok = unsafe {
                DeviceIoControl(
                    self.0,
                    0x2403e,
                    (&raw as *const Raw).cast(),
                    std::mem::size_of::<Raw>() as u32,
                    b.as_mut_ptr().cast(),
                    b.len() as u32,
                    &mut n,
                    ptr::null_mut(),
                )
            };
            if ok == 0 || n as usize != b.len() {
                bail!(
                    "Błąd odczytu sektora {lba}: {}",
                    std::io::Error::last_os_error()
                )
            };
            Ok(b)
        }
    }
}
/// Bounded repeated-read comparison, with explicit ambiguity rejection.
pub fn verified_chunk(
    mut read: impl FnMut(u32, u32) -> Result<Vec<u8>>,
    start: u32,
    sectors: u32,
) -> Result<(Vec<u8>, Vec<u32>)> {
    if sectors == 0 || sectors > 16 {
        bail!("Nieprawidłowa wielkość odczytu")
    }
    let count = sectors as usize * 2352;
    let a = read(start, sectors);
    let b = read(start, sectors);
    if let (Ok(a), Ok(b)) = (&a, &b) {
        if a.len() == count && a == b {
            return Ok((a.clone(), Vec::new()));
        }
    }
    let mut out = Vec::with_capacity(count);
    let mut retried = Vec::new();
    for sector in start..start + sectors {
        let mut variants: Vec<(Vec<u8>, usize)> = Vec::new();
        for _ in 0..4 {
            if let Ok(bytes) = read(sector, 1) {
                if bytes.len() != 2352 {
                    continue;
                }
                if let Some((_, n)) = variants.iter_mut().find(|(b, _)| *b == bytes) {
                    *n += 1
                } else {
                    variants.push((bytes, 1))
                }
            }
        }
        variants.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
        if variants.first().is_none_or(|(_, n)| *n < 2)
            || variants.len() > 1 && variants[0].1 == variants[1].1
        {
            bail!("Sektor {sector} nie ma jednoznacznych zgodnych odczytów")
        };
        out.extend_from_slice(&variants[0].0);
        retried.push(sector);
    }
    Ok((out, retried))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn official_musicbrainz_toc_vector() {
        let offsets = [0, 15213, 32164, 46442, 63264, 80339, 95312];
        let mut b = vec![0u8; 4 + offsets.len() * 8];
        b[2] = 1;
        b[3] = 6;
        for (i, lba) in offsets.iter().enumerate() {
            let f = lba + 150;
            let k = 4 + i * 8;
            b[k + 2] = if i == 6 { 170 } else { i as u8 + 1 };
            b[k + 5] = (f / 4500) as u8;
            b[k + 6] = ((f / 75) % 60) as u8;
            b[k + 7] = (f % 75) as u8;
        }
        let t = parse_toc("D:", &b).unwrap();
        assert_eq!(t.disc_id, "49HHV7Eb8UKF3aQiNmu1GR8vKTY-");
        b[5] |= 4;
        assert!(parse_toc("D:", &b).is_err());
    }
    #[test]
    fn read_retry_recovers_majority_but_rejects_ambiguous_and_short_data() {
        let mut n = 0;
        let (b, r) = verified_chunk(
            |_, _| {
                n += 1;
                Ok(vec![if n == 1 || n == 3 { 1 } else { 2 }; 2352])
            },
            10,
            1,
        )
        .unwrap();
        assert_eq!(b[0], 2);
        assert_eq!(r, [10]);
        let mut n = 0;
        assert!(verified_chunk(
            |_, _| {
                n += 1;
                Ok(vec![(n % 2) as u8; 2352])
            },
            10,
            1
        )
        .is_err());
        assert!(verified_chunk(|_, _| Ok(vec![0; 2351]), 10, 1).is_err());
    }
}
