"""Package the tested Windows and Android binaries with complete Mytify sources."""
from pathlib import Path
import argparse,os,shutil,zipfile,hashlib,struct
p=argparse.ArgumentParser()
for name in ['windows','airplay','loader','apk']:p.add_argument('--'+name,type=Path,required=True)
a=p.parse_args();project=Path(__file__).resolve().parents[1];release=project.parent/'release';dest=release/'Mytify_0.9'
for file in [a.windows,a.airplay,a.loader]:
 b=file.read_bytes();assert b[:2]==b'MZ';header=struct.unpack_from('<I',b,0x3c)[0];assert b[header:header+4]==b'PE\0\0';assert struct.unpack_from('<H',b,header+4)[0]==0x8664,f'Expected x64: {file}'
with zipfile.ZipFile(a.apk)as z:
 assert z.testzip()is None
 abis={n.split('/')[1]for n in z.namelist()if n.startswith('lib/') and n.endswith('.so')}
 assert abis=={'arm64-v8a'},abis
 assert 'lib/arm64-v8a/libmytify_airplay.so'in z.namelist()
assert (project/'docs/TESTY_0.9.md').exists()
if dest.exists():shutil.rmtree(dest)
(dest/'Windows').mkdir(parents=True);(dest/'Android').mkdir()
for source,name in [(a.windows,'Mytify.exe'),(a.airplay,'mytify_airplay.dll'),(a.loader,'WebView2Loader.dll')]:shutil.copy2(source,dest/'Windows'/name)
shutil.copy2(a.apk,dest/'Android/Mytify_0.9_Android_Auto.apk');shutil.copy2(a.apk,release/'Mytify_0.9_Android_Auto.apk')
excluded={'build','build-win','target','node_modules','.dart_tool','.gradle','.cxx','.kotlin','.idea','__pycache__','ephemeral','.plugin_symlinks','.git','dist'}
shutil.copytree(project,dest/'source',ignore=shutil.ignore_patterns(*excluded,'*.iml','.flutter-plugins-dependencies','local.properties'))
shutil.copy2(project/'README.md',dest/'README_PL.md')
for name in ['TESTY_0.9.md','CHANGELOG_0.9.md','CO_DALEJ_0.9.md','TESTY_0.8.md','CHANGELOG_0.8.md','PLAN_ITERACJI.md','THIRD_PARTY_NOTICES.txt','RUST_NOTICES.txt','NETWORK_NOTICES.txt','FLUTTER_NOTICES.txt','ANDROID_NOTICES.txt','WEBVIEW2_SDK_LICENSE.txt']:
 shutil.copy2(project/'docs'/name,dest/name)
files=sorted(f for f in dest.rglob('*')if f.is_file())
(dest/'SHA256SUMS.txt').write_text('\n'.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.relative_to(dest).as_posix()for f in files)+'\n')
archive=release/'Mytify_0.9_PC_Android_i_zrodla.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9)as z:
 for f in sorted(dest.rglob('*')):
  if f.is_file():z.write(f,f.relative_to(release))
with zipfile.ZipFile(archive)as z:
 assert z.testzip()is None
 assert not any('/.gradle/'in n or '/target/'in n or '/local.properties'in n for n in z.namelist())
for f in [release/'Mytify_0.9_Android_Auto.apk',archive]:print(f,f.stat().st_size,hashlib.sha256(f.read_bytes()).hexdigest())
