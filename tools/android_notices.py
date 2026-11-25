"""Collect licenses from the resolved Android runtime artifacts and Flutter APK."""
import argparse,gzip,io,re,xml.etree.ElementTree as ET,zipfile,zlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--log',type=Path,required=True);p.add_argument('--apk',type=Path,required=True);p.add_argument('--cache',type=Path,required=True);a=p.parse_args()
docs=Path(__file__).resolve().parents[1]/'docs'
with zipfile.ZipFile(a.apk) as z:
 data=z.read('assets/flutter_assets/NOTICES.Z')
 try:notice=gzip.decompress(data)
 except gzip.BadGzipFile:notice=zlib.decompress(data)
 (docs/'FLUTTER_NOTICES.txt').write_bytes(notice)
out=['MYTIFY 0.9 — ANDROID RUNTIME NOTICES','Flutter/Dart/engine notices: FLUTTER_NOTICES.txt.','Android runtime dependency coordinates, declared license links and bundled notices follow.','']
count=0
for line in a.log.read_text().splitlines():
 if not line.startswith('MYTIFY_ARTIFACT|'):continue
 _,group,name,version,path=line.split('|',4);count+=1;out.append(f'\n{group}:{name}:{version}\n')
 ns={'m':'http://maven.apache.org/POM/4.0.0'}
 for pom in (a.cache/group/name/version).glob('*/*.pom'):
  root=ET.fromstring(pom.read_bytes())
  for lic in root.findall('m:licenses/m:license',ns):out.append((lic.findtext('m:name',default='',namespaces=ns)+' '+lic.findtext('m:url',default='',namespaces=ns)).strip())
 def extract(data):
  with zipfile.ZipFile(data) as z:
   for n in z.namelist():
    if re.search(r'(^|/)(LICENSE|NOTICE|COPYING)(\.[^/]*)?$',n,re.I):
     raw=z.read(n)
     if len(raw)<500000:out.append(n+'\n'+raw.decode('utf-8','replace'))
    if n=='classes.jar':extract(io.BytesIO(z.read(n)))
 try:extract(Path(path))
 except zipfile.BadZipFile:pass
assert count>5,'Missing resolved runtime artifact report'
out.append('\nApache License 2.0 (AndroidX Media3 and Apache-licensed runtime components)\n')
out.append(Path('/usr/share/common-licenses/Apache-2.0').read_text())
(docs/'ANDROID_NOTICES.txt').write_text('\n'.join(out)+'\n')
print(f'{count} Android runtime artifacts; Flutter notices {len(notice)} bytes')
