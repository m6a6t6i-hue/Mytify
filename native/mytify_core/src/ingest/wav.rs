use anyhow::{bail, Result};
use flacenc::{
    bitsink::ByteSink,
    component::{BitRepr, Stream, StreamInfo},
    error::Verify,
    source::{Fill, FrameBuf},
};
use sha2::Digest;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
};
pub struct Wav {
    pub file: File,
    pub rate: u32,
    pub channels: u16,
    pub bits: u16,
    pub bytes: u64,
}
impl Wav {
    pub fn create(path: &Path, rate: u32, channels: u16, bits: u16) -> Result<Self> {
        if !(8000..=384000).contains(&rate)
            || !(1..=2).contains(&channels)
            || ![16, 24].contains(&bits)
        {
            bail!("Nieprawidłowy format PCM")
        };
        let mut s = Self {
            file: OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .open(path)?,
            rate,
            channels,
            bits,
            bytes: 0,
        };
        s.header()?;
        Ok(s)
    }
    pub fn header(&mut self) -> Result<()> {
        let mut h = Vec::new();
        h.extend(b"RIFF");
        h.extend((36 + self.bytes as u32).to_le_bytes());
        h.extend(b"WAVEfmt ");
        h.extend(16u32.to_le_bytes());
        h.extend(1u16.to_le_bytes());
        h.extend(self.channels.to_le_bytes());
        h.extend(self.rate.to_le_bytes());
        let block = self.channels * self.bits / 8;
        h.extend((self.rate * block as u32).to_le_bytes());
        h.extend(block.to_le_bytes());
        h.extend(self.bits.to_le_bytes());
        h.extend(b"data");
        h.extend((self.bytes as u32).to_le_bytes());
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(&h)?;
        self.file.seek(SeekFrom::End(0))?;
        Ok(())
    }
    pub fn write(&mut self, b: &[u8]) -> Result<()> {
        if self.bytes + b.len() as u64 > (u32::MAX as u64 - 36) {
            bail!("Osiągnięto limit 4 GB nagrania. Zapisano dotychczasowe audio; rozpocznij nową stronę.")
        };
        self.file.write_all(b)?;
        self.bytes += b.len() as u64;
        Ok(())
    }
    pub fn finish(&mut self) -> Result<()> {
        self.header()?;
        self.file.sync_all()?;
        Ok(())
    }
    pub fn read(path: &Path) -> Result<Self> {
        let mut file = File::open(path)?;
        let mut h = [0u8; 44];
        file.read_exact(&mut h)?;
        if &h[..4] != b"RIFF"
            || &h[8..16] != b"WAVEfmt "
            || &h[36..40] != b"data"
            || u16::from_le_bytes([h[20], h[21]]) != 1
        {
            bail!("To nie jest nagranie PCM Mytify")
        };
        let channels = u16::from_le_bytes([h[22], h[23]]);
        let bits = u16::from_le_bytes([h[34], h[35]]);
        let rate = u32::from_le_bytes(h[24..28].try_into()?);
        if ![1, 2].contains(&channels)
            || ![16, 24].contains(&bits)
            || !(8000..=384000).contains(&rate)
        {
            bail!("Nieprawidłowy nagłówek nagrania")
        };
        let block = channels as u64 * bits as u64 / 8;
        let bytes = (file.metadata()?.len().saturating_sub(44) / block) * block;
        if bytes > (u32::MAX as u64 - 36) {
            bail!("Nagranie przekracza limit WAV")
        };
        Ok(Self {
            file,
            rate,
            channels,
            bits,
            bytes,
        })
    }
    pub fn recover(path: &Path) -> Result<Self> {
        let read = Self::read(path)?;
        let Self {
            rate,
            channels,
            bits,
            bytes,
            ..
        } = read;
        let file = OpenOptions::new().read(true).write(true).open(path)?;
        file.set_len(44 + bytes)?;
        let mut s = Self {
            file,
            rate,
            channels,
            bits,
            bytes,
        };
        s.finish()?;
        Ok(s)
    }
    /// Drops everything after `frames` (end of a recorded side).
    pub fn truncate(&mut self, frames: u64) -> Result<()> {
        let block = self.channels as u64 * self.bits as u64 / 8;
        let bytes = (frames * block).min(self.bytes);
        self.file.set_len(44 + bytes)?;
        self.file.seek(SeekFrom::Start(44 + bytes))?;
        self.bytes = bytes;
        Ok(())
    }
    pub fn frames(&self) -> u64 {
        self.bytes / (self.channels as u64 * self.bits as u64 / 8)
    }
}
/// Streams bounded frames to disk. STREAMINFO/MD5 are patched after all audio is encoded.
pub fn flac(input: &Path, output: &Path, start: u64, end: u64) -> Result<()> {
    flac_cancellable(
        input,
        output,
        start,
        end,
        &std::sync::atomic::AtomicBool::new(false),
    )
}
pub fn flac_cancellable(
    input: &Path,
    output: &Path,
    start: u64,
    end: u64,
    cancel: &std::sync::atomic::AtomicBool,
) -> Result<()> {
    let mut wav = Wav::read(input)?;
    if start >= end || end > wav.frames() {
        bail!("Nieprawidłowy podział nagrania")
    };
    let channels = wav.channels as usize;
    let bytes = wav.bits as usize / 8;
    let mut info = StreamInfo::new(wav.rate as usize, channels, wav.bits as usize)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let header = |i: &StreamInfo| -> Result<Vec<u8>> {
        let mut sink = ByteSink::new();
        Stream::with_stream_info(i.clone()).write(&mut sink)?;
        Ok(sink.as_slice().to_vec())
    };
    let config = flacenc::config::Encoder::default()
        .into_verified()
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output)?;
    file.write_all(&header(&info)?)?;
    wav.file
        .seek(SeekFrom::Start(44 + start * channels as u64 * bytes as u64))?;
    let mut md5 = md5::Md5::new();
    let mut pos = start;
    let mut number = 0;
    while pos < end {
        if cancel.load(std::sync::atomic::Ordering::Acquire) {
            bail!("Anulowano eksport — zachowano oryginał i ukończone utwory")
        };
        let n = (end - pos).min(4096) as usize;
        let mut raw = vec![0u8; n * channels * bytes];
        wav.file.read_exact(&mut raw)?;
        md5.update(&raw);
        let mut framebuf =
            FrameBuf::with_size(channels, 4096).map_err(|e| anyhow::anyhow!("{e}"))?;
        framebuf
            .fill_le_bytes(&raw, bytes)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let frame = flacenc::encode_fixed_size_frame(&config, &framebuf, number, &info)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        info.update_frame_info(&frame);
        let mut sink = ByteSink::new();
        frame.write(&mut sink)?;
        file.write_all(sink.as_slice())?;
        number += 1;
        pos += n as u64;
    }
    info.set_block_sizes(4096, 4096)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    info.set_md5_digest(&md5.finalize().into());
    file.seek(SeekFrom::Start(0))?;
    file.write_all(&header(&info)?)?;
    file.sync_all()?;
    Ok(())
}
#[cfg(test)]
mod cancel_test {
    use super::*;
    #[test]
    fn cancelled_encoding_keeps_master_and_never_publishes_final_file() {
        let d = tempfile::tempdir().unwrap();
        let master = d.path().join("master.wav");
        let output = d.path().join("track.flac.partial");
        let mut w = Wav::create(&master, 48000, 2, 24).unwrap();
        w.write(&vec![0; 48000 * 6]).unwrap();
        w.finish().unwrap();
        drop(w);
        let before = std::fs::read(&master).unwrap();
        assert!(flac_cancellable(
            &master,
            &output,
            0,
            48000,
            &std::sync::atomic::AtomicBool::new(true)
        )
        .unwrap_err()
        .to_string()
        .starts_with("Anulowano eksport"));
        assert!(!d.path().join("track.flac").exists());
        assert_eq!(before, std::fs::read(master).unwrap());
    }
}
