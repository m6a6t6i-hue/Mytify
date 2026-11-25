"""Real pinned TLS Rust host -> Android receiver under Robolectric -> verified private offline files.
Run this script and Gradle in one process namespace. Hardware is not simulated as tested.
"""
from pathlib import Path
import subprocess,tempfile,urllib.request,json,os,time,shutil,argparse,threading
p=argparse.ArgumentParser();p.add_argument('--backend',required=True);a=p.parse_args();project=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='mytify-transfer-')as tmp:
 tmp=Path(tmp);music=tmp/'music';music.mkdir()
 for ext in ['flac','mp3','m4a','wav']:shutil.copy2(project/'test/fixtures'/('sample.'+ext),music/('sample.'+ext))
 backend=subprocess.Popen([a.backend,'--headless','--audio-test','--port','0','--data-dir',str(tmp/'data')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  line=backend.stdout.readline();assert line,backend.stderr.read();c=json.loads(line)
  def api(path,body=None):
   q=urllib.request.Request(c['base']+path,data=json.dumps(body).encode()if body is not None else None,headers={'X-Mytify-Token':c['token'],'Content-Type':'application/json'});
   try:return json.load(urllib.request.urlopen(q))
   except urllib.error.HTTPError as e:raise RuntimeError(e.read().decode()) from e
  job=api('/api/scan',{'paths':[str(music)],'folder':True})['job']
  for _ in range(300):
   state=api('/api/jobs/'+job)
   if state['finished']:assert not state['error'];break
   time.sleep(.02)
  tracks=api('/api/library');assert len(tracks)==4
  api('/api/transfer',{'action':'playlistSave','name':'Z PC na telefon','ids':[t['id']for t in tracks]})
  stop_request=tmp/'stop-request';stop_ack=tmp/'stop-ack'
  def stop_pc():
   while backend.poll() is None:
    if stop_request.exists():
     backend.terminate();backend.wait(timeout=10);stop_ack.write_text('stopped');return
    time.sleep(.02)
  threading.Thread(target=stop_pc,daemon=True).start()
  state=api('/api/transfer',{'action':'start','port':0});fixture=tmp/'fixture.json';fixture.write_text(json.dumps({'link':state['pairUri'],'qr':state['qr'],'base':c['base'],'token':c['token'],'stopRequest':str(stop_request),'stopAck':str(stop_ack),'hashes':{t['id']:t['size']for t in tracks}}));fixture.chmod(0o600)
  env=os.environ.copy();env['MYTIFY_TRANSFER_E2E']=str(fixture)
  subprocess.run(['./gradlew','--no-daemon','-Ptarget-platform=android-arm64',':app:testReleaseUnitTest'],cwd=project/'android',env=env,check=True)
  print('PASS real Rust TLS -> Android: pinned pairing, rejected pin, partial resume, SHA-256 rejection, dedupe, phone edit protection, playlist copy, offline bytes after PC stop, safe deletion.',flush=True)
 finally:
  if backend.poll() is None:backend.terminate()
  backend.wait(timeout=10)
