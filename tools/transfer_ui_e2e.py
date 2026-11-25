"""PC 0.9 UI smoke against a real Rust server; TLS peer is a test client.
No Windows execution, physical camera or phone is implied by this test.
"""
from pathlib import Path
import argparse,subprocess,tempfile,json,urllib.request,urllib.parse,ssl,hashlib,time
from playwright.sync_api import sync_playwright,expect
p=argparse.ArgumentParser();p.add_argument('--backend',required=True);p.add_argument('--chrome',required=True);p.add_argument('--screenshots',required=True);a=p.parse_args();root=Path(__file__).resolve().parents[1];shots=Path(a.screenshots);shots.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='mytify-ui09-')as tmp:
 proc=subprocess.Popen([a.backend,'--headless','--audio-test','--port','0','--data-dir',tmp,'--ui-dir',str(root/'build/web')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  c=json.loads(proc.stdout.readline())
  def api(req):
   return json.load(urllib.request.urlopen(urllib.request.Request(c['base']+'/api/transfer',data=json.dumps(req).encode(),headers={'X-Mytify-Token':c['token'],'Content-Type':'application/json'})))
  with sync_playwright()as pw:
   browser=pw.chromium.launch(executable_path=a.chrome,headless=True,args=['--no-sandbox','--no-zygote','--single-process','--use-angle=swiftshader','--enable-unsafe-swiftshader'])
   page=browser.new_page(viewport={'width':1280,'height':900});errors=[];page.on('pageerror',lambda e:errors.append(str(e)));page.goto(c['base']);page.locator('flt-glass-pane').wait_for(state='attached',timeout=45000)
   placeholder=page.locator('flt-semantics-placeholder');placeholder.wait_for(state='attached');placeholder.dispatch_event('click')
   def click(name):
    page.get_by_role('button',name=name,exact=True).click(force=True);page.wait_for_timeout(400)
   click('Połącz telefon');expect(page.get_by_role('button',name='Włącz parowanie',exact=True)).to_be_visible();assert not api({'action':'status'})['enabled']
   click('Włącz parowanie');expect(page.get_by_role('img',name='Kod QR do sparowania telefonu')).to_be_visible(timeout=15000);state=api({'action':'status'});assert state['enabled'];page.screenshot(path=str(shots/'pc_pairing.png'))
   q=urllib.parse.parse_qs(urllib.parse.urlparse(state['pairUri']).query);host=q['host'][0];port=int(q['port'][0]);ctx=ssl._create_unverified_context()
   import http.client
   conn=http.client.HTTPSConnection(host,port,context=ctx);conn.connect();assert hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()==q['fingerprint'][0]
   conn.request('POST','/pair',json.dumps({'secret':q['secret'][0],'name':'Telefon testowy'}),{'Content-Type':'application/json'});response=conn.getresponse();assert response.status==200;peer=json.loads(response.read());conn.close()
   expect(page.get_by_role('group',name='Telefon testowy',exact=True)).to_be_visible(timeout=10000);page.get_by_role('button',name='Cofnij dostęp',exact=True).click(force=True);page.wait_for_timeout(500);assert not api({'action':'status'})['peers']
   click('Wyłącz transfer');expect(page.get_by_role('button',name='Włącz parowanie',exact=True)).to_be_visible();assert not api({'action':'status'})['enabled'];page.screenshot(path=str(shots/'pc_pairing_stopped.png'));assert not errors,errors
   print('PASS PC UI: opt-in TLS, QR, real pinned pairing, peer refresh, revoke, stop; no JS errors.',flush=True)
   click('Playlisty');click('Nowa playlista')
   field=page.get_by_role('textbox',name='Nazwa playlisty');field.click(force=True);page.wait_for_timeout(300);page.keyboard.insert_text('Na telefon');page.keyboard.press('Tab');click('Zapisz')
   expect(page.get_by_role('button',name='Nowa playlista',exact=True)).to_be_visible();assert api({'action':'playlistList'})[0]['name']=='Na telefon';print('PASS PC UI: persistent playlist creation through editor.',flush=True)
   browser.close()
 finally:
  proc.terminate();proc.wait(timeout=10)
