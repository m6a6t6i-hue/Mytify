"""Package the Android layout hotfix and complete sources; Windows binary stays 0.8.1."""
from pathlib import Path
import argparse,hashlib,shutil,zipfile
p=argparse.ArgumentParser();p.add_argument('--apk',required=True,type=Path);a=p.parse_args()
project=Path(__file__).resolve().parents[1];release=project.parent/'release';dest=release/'Mytify_0.8.2'
with zipfile.ZipFile(a.apk)as z:
 assert z.testzip()is None
 assert {n.split('/')[1]for n in z.namelist()if n.startswith('lib/')and n.endswith('.so')}=={'arm64-v8a'}
 assert 'lib/arm64-v8a/libmytify_airplay.so'in z.namelist()
if dest.exists():shutil.rmtree(dest)
(dest/'Android').mkdir(parents=True)
apk=release/'Mytify_0.8.2_Android_Auto.apk';shutil.copy2(a.apk,apk);shutil.copy2(apk,dest/'Android'/apk.name)
excluded={'build','build-win','target','node_modules','.dart_tool','.gradle','.cxx','.kotlin','.idea','__pycache__','ephemeral','.plugin_symlinks','.git','dist'}
shutil.copytree(project,dest/'source',ignore=shutil.ignore_patterns(*excluded,'*.iml','.flutter-plugins-dependencies','local.properties'))
shutil.copy2(project/'README.md',dest/'README_PL.md')
for name in ['TESTY_0.8.2.md','CHANGELOG_0.8.2.md','CO_DALEJ_0.8.1.md','THIRD_PARTY_NOTICES.txt','RUST_NOTICES.txt','NETWORK_NOTICES.txt','FLUTTER_NOTICES.txt','ANDROID_NOTICES.txt','WEBVIEW2_SDK_LICENSE.txt']:shutil.copy2(project/'docs'/name,dest/name)
files=sorted(f for f in dest.rglob('*')if f.is_file());(dest/'SHA256SUMS.txt').write_text('\n'.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.relative_to(dest).as_posix()for f in files)+'\n')
archive=release/'Mytify_0.8.2_Android_i_zrodla.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9)as z:
 for f in sorted(dest.rglob('*')):
  if f.is_file():z.write(f,f.relative_to(release))
with zipfile.ZipFile(archive)as z:
 assert z.testzip()is None
 for line in z.read('Mytify_0.8.2/SHA256SUMS.txt').decode().splitlines():
  digest,name=line.split('  ',1);assert hashlib.sha256(z.read('Mytify_0.8.2/'+name)).hexdigest()==digest,name
for f in [apk,archive]:print(f,f.stat().st_size,hashlib.sha256(f.read_bytes()).hexdigest())
