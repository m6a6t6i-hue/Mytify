"""Generate original 1.2-second test signals; requires FFmpeg, no music downloads."""
import subprocess
import struct
import zlib
from pathlib import Path

destination = Path(__file__).resolve().parents[1] / 'test' / 'fixtures'
destination.mkdir(parents=True, exist_ok=True)
for extension in ['flac', 'mp3', 'm4a', 'wav']:
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=1.2',
        '-ac', '2', '-metadata', 'title=Światło', '-metadata', 'artist=Łódź',
        '-metadata', 'album=Album testowy', '-metadata', 'album_artist=Łódź',
        '-metadata', 'track=1', str(destination / f'sample.{extension}'),
    ], check=True)

def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress((b'\0' + b'\xbb\x9b\xff\xff' * 32) * 32))
png += chunk(b'IEND', b'')
(destination / 'cover.png').write_bytes(png)
covered = destination / 'covered.flac'
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-i', str(destination / 'sample.flac'), '-i', str(destination / 'cover.png'),
    '-map', '0:a', '-map', '1:v', '-c', 'copy', '-disposition:v:0', 'attached_pic',
    str(covered)], check=True)
covered.replace(destination / 'sample.flac')
print(destination)
