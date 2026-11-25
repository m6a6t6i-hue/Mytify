"""Package Android APK and complete sources, excluding local SDK/cache."""
import argparse,hashlib,shutil,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--apk',required=True,type=Path);args=p.parse_args()
project=Path(__file__).resolve().parents[1];apk=args.apk.resolve();assert apk.is_file()
release=project.parent/'release';dest=release/'Mytify_0.6'
if dest.exists():shutil.rmtree(dest)
dest.mkdir(parents=True);shutil.copy2(apk,dest/'Mytify_0.6_Android_Auto.apk');shutil.copy2(apk,release/'Mytify_0.6_Android_Auto.apk')
shutil.copytree(project,dest/'source',ignore=shutil.ignore_patterns('node_modules','target','.dart_tool','build','.gradle','.cxx','.kotlin','.idea','*.iml','.flutter-plugins-dependencies','__pycache__','ephemeral','.plugin_symlinks','.git','dist','local.properties','captures'))
shutil.copy2(project/'README.md',dest/'README.md')
for name in ('PLAN_ITERACJI.md','TESTY_0.6.md','ARCHITEKTURA_0.6.md','ANDROID_NOTICES.txt','FLUTTER_NOTICES.txt','THIRD_PARTY_NOTICES.txt'):shutil.copy2(project/'docs'/name,dest/name)
manifest=[]
for f in sorted(dest.rglob('*')):
 if f.is_file():manifest.append(f'{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(dest).as_posix()}')
(dest/'SHA256SUMS.txt').write_text('\n'.join(manifest)+'\n')
archive=release/'Mytify_0.6_Android_Auto_i_zrodla.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for f in sorted(dest.rglob('*')):
  if f.is_file():z.write(f,f.relative_to(release))
with zipfile.ZipFile(archive) as z:
 assert z.testzip() is None
 assert not any('/.gradle/' in n or '/local.properties' in n or '/target/' in n for n in z.namelist())
for f in (release/'Mytify_0.6_Android_Auto.apk',archive):print(f,f.stat().st_size,hashlib.sha256(f.read_bytes()).hexdigest())
