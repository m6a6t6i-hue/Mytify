"""Package Windows Wry executable, loader, sources, notices and test report.
Run after Flutter Web and Rust desktop/embed-ui builds.
"""
import argparse
import hashlib
import shutil
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True, type=Path)
parser.add_argument('--loader', type=Path, help='Required for GNU/gnullvm build; MSVC links loader statically')
args = parser.parse_args()
project = Path(__file__).resolve().parents[1]
if not args.binary.is_file():
    raise SystemExit('Missing Windows executable')
if args.loader and not args.loader.is_file():
    raise SystemExit('Missing WebView2Loader.dll')
destination = project.parent / 'release' / 'Mytify_0.4'
if destination.exists():
    shutil.rmtree(destination)
destination.mkdir(parents=True)
shutil.copy(args.binary, destination / 'Mytify.exe')
if args.loader:
    shutil.copy(args.loader, destination / 'WebView2Loader.dll')
shutil.copytree(project, destination / 'source', symlinks=False, ignore=shutil.ignore_patterns(
    'node_modules', 'target', '.dart_tool', 'build', '.idea', '*.iml', '.flutter-plugins-dependencies',
    '__pycache__', 'ephemeral', '.plugin_symlinks', '.git', 'dist'))
shutil.copy(project / 'tools/MIGRACJA_0.1.cmd', destination / 'MIGRACJA_0.1.cmd')
shutil.copy(project / 'README.md', destination / 'README.md')
for name in ['PLAN_ITERACJI.md', 'TESTY_0.4.md', 'THIRD_PARTY_NOTICES.txt', 'RUST_NOTICES.txt',
             'FLUTTER_NOTICES.txt', 'WEBVIEW2_SDK_LICENSE.txt','AUDIO_SOAK_0.4.json']:
    shutil.copy(project / 'docs' / name, destination / name)
manifest = []
for path in sorted(destination.rglob('*')):
    if path.is_file():
        manifest.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(destination).as_posix()}')
(destination / 'SHA256SUMS.txt').write_text('\n'.join(manifest) + '\n')
archive = destination.parent / 'Mytify_0.4_Windows_i_zrodla.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
    for path in sorted(destination.rglob('*')):
        if path.is_file():
            output.write(path, path.relative_to(destination.parent))
with zipfile.ZipFile(archive) as output:
    assert output.testzip() is None
    assert not any('/target/' in n or '/node_modules/' in n or '/.dart_tool/' in n for n in output.namelist())
print(archive)
print(f'{archive.stat().st_size / 1024 / 1024:.1f} MiB; {len(manifest)} files; SHA-256: {hashlib.sha256(archive.read_bytes()).hexdigest()}')
