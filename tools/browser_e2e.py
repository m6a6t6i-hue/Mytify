"""Real Rust/SQLite + Flutter + audio. Windows picker and online metadata responses are substituted; edits and cover decoding use real Rust.
Requires Python Playwright, Chrome, built web and a DEBUG Rust backend with test clock. No sound card is simulated as a production device.
"""
import argparse
import base64
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--chrome', required=True)
parser.add_argument('--backend')
parser.add_argument('--screenshots')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
backend = Path(args.backend) if args.backend else root / 'native/mytify_core/target/debug/mytify'
checks, errors, external = [], [], []
FAKE_ID='12345678-1234-1234-1234-123456789abc'
metadata_cover={'hash':None,'uri':None}
fake_release={'id':FAKE_ID,'title':'Album z propozycji','artist':'Wykonawca testowy','date':'2026','country':'PL','format':'CD','label':'Wytwórnia testowa','barcode':'','disambiguation':'Wydanie testowe','trackCount':4,'score':97}
fake_tracks=[{'title':f'Propozycja {i}','artist':'Wykonawca testowy','discNumber':1,'trackNumber':i,'durationMs':1200} for i in range(1,5)]

def passed(text):
    checks.append(text)
    print('PASS:', text, flush=True)

with tempfile.TemporaryDirectory(prefix='mytify-v02-') as temp:
    temp = Path(temp)
    music = temp / 'Moja muzyka'
    music.mkdir()
    for fixture_file in (root/'test/fixtures').iterdir():
        if fixture_file.is_file():shutil.copy2(fixture_file,music/fixture_file.name)
    data = temp / 'data'
    process = None

    def start(port=0):
        global process, base, token
        process = subprocess.Popen([str(backend), '--headless', '--port', str(port),
            '--data-dir', str(data), '--ui-dir', str(root / 'build/web'),'--audio-test','--audio-test-output',str(temp/'rendered.f32le')],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = process.stdout.readline()
        assert line, 'Backend failed: ' + process.stderr.read()
        config = json.loads(line)
        base, token = config['base'], config['token']

    def stop():
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=10)

    def request(path, method='GET', body=None, headers=None, auth=True, expected=200):
        h = {'X-Mytify-Token': token} if auth else {}
        if body is not None:
            body = json.dumps(body).encode()
            h['Content-Type'] = 'application/json'
        h.update(headers or {})
        req = urllib.request.Request(base + path, data=body, headers=h, method=method)
        try:
            response = urllib.request.urlopen(req, timeout=15)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            payload = response.read()
            assert response.status == expected, (path, response.status, payload[:200])
            return payload, response.headers

    def api(path, **kw):
        return json.loads(request(path, **kw)[0])

    def scan(body):
        job = api('/api/scan', method='POST', body=body)['job']
        for _ in range(300):
            status = api('/api/jobs/' + job)
            if status['finished']:
                assert not status['error'], status
                time.sleep(.02)
                return status['result']
            time.sleep(.02)
        raise AssertionError('Scan timeout')

    def wait_library(predicate):
        for _ in range(400):
            tracks=api('/api/library')
            if predicate(tracks): return tracks
            time.sleep(.05)
        raise AssertionError('Library condition timed out: '+str([(t['title'],t['album'],t['edited']) for t in tracks]))

    def type_field(page,label,value):
        field=page.get_by_role('textbox',name=re.compile(label))
        field.click(force=True)
        page.wait_for_timeout(300)
        page.wait_for_timeout(250)
        page.keyboard.press('Control+A')
        page.keyboard.press('Backspace')
        if value: page.keyboard.insert_text(value)
        page.wait_for_timeout(150)
        page.keyboard.press('Tab')
        page.wait_for_timeout(100)

    def semantics(page):
        page.locator('flt-glass-pane').wait_for(state='attached', timeout=45000)
        page.locator('flt-semantics-placeholder, flt-semantics').first.wait_for(state='attached', timeout=20000)
        placeholder = page.locator('flt-semantics-placeholder')
        if placeholder.count():
            placeholder.dispatch_event('click')
        page.get_by_role('button', name='Start', exact=True).wait_for(timeout=20000)

    def report(page):
        page.get_by_text('Operacja zakończona', exact=True).wait_for(timeout=30000)
        page.get_by_role('button', name='Gotowe', exact=True).click(force=True)
        page.wait_for_timeout(300)
        page.get_by_text('Operacja zakończona', exact=True).wait_for(state='hidden')

    try:
        start()
        request('/api/library', auth=False, expected=403)
        request('/api/session', headers={'Origin': 'https://example.org'}, expected=403)
        request('/api/session', headers={'Host': 'example.org'}, expected=403)
        request('/api/session', headers={'Sec-Fetch-Site': 'cross-site'}, expected=403)
        passed('API: session token, Host and Origin restrictions')
        with sync_playwright() as playwright:
            chrome_args = ['--no-sandbox', '--no-zygote', '--single-process', '--use-angle=swiftshader', '--enable-unsafe-swiftshader']
            pick_path = [str(music)]
            def context_open():
                context = playwright.chromium.launch_persistent_context(str(temp / 'profile'),
                    executable_path=args.chrome, headless=True, args=chrome_args,
                    viewport={'width': 1280, 'height': 850})
                def route(r):
                    if r.request.url.startswith(base+'/api/metadata/search?'):
                        r.fulfill(status=200,content_type='application/json',body=json.dumps([fake_release]))
                    elif r.request.url == base+'/api/metadata/release/'+FAKE_ID:
                        r.fulfill(status=200,content_type='application/json',body=json.dumps({'release':fake_release,'tracks':fake_tracks}))
                    elif r.request.url == base+'/api/metadata/cover/'+FAKE_ID:
                        r.fulfill(status=200,content_type='application/json',body=json.dumps(metadata_cover))
                    elif r.request.url == base + '/api/pick':
                        r.fulfill(status=200, content_type='application/json', body=json.dumps({'paths': pick_path}))
                    elif r.request.url.startswith(base + '/') or r.request.url.startswith(('blob:', 'data:')):
                        r.continue_()
                    else:
                        external.append(r.request.url)
                        r.abort()
                context.route('**/*', route)
                context.add_init_script("window.__unexpectedBrowserAudio=0;HTMLMediaElement.prototype.play=function(){window.__unexpectedBrowserAudio++;throw new Error('Browser audio must not be used in 0.4');};")
                page = context.new_page()
                page.on('pageerror', lambda e: errors.append(str(e)))
                page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
                page.goto(base)
                semantics(page)
                return context, page

            context, page = context_open()
            old_bytes = (music / 'sample.flac').read_bytes()
            old_hash = hashlib.sha256(old_bytes).hexdigest()
            page.evaluate('''async ({bytes,id}) => {
              const db = await new Promise((resolve,reject) => {
                const r = indexedDB.open('mytify-library',1);
                r.onupgradeneeded = () => {r.result.createObjectStore('tracks',{keyPath:'id'});r.result.createObjectStore('audio',{keyPath:'id'});};
                r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);
              });
              const tx=db.transaction(['tracks','audio'],'readwrite');
              tx.objectStore('tracks').put({id,fileName:'sample.flac',liked:true,title:'Światło',artist:'Łódź',album:'Album testowy'});
              tx.objectStore('audio').put({id,blob:new Blob([Uint8Array.from(atob(bytes),c=>c.charCodeAt(0))])});
              await new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);});db.close();
            }''', {'bytes': base64.b64encode(old_bytes).decode(), 'id': old_hash})
            page.get_by_role('button', name='Dodaj swoją muzykę', exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button', name='Przenieś bibliotekę z wersji 0.1', exact=True).click(force=True)
            page.wait_for_timeout(300)
            report(page)
            tracks = api('/api/library')
            assert len(tracks) == 1 and tracks[0]['liked'] and tracks[0]['managed']
            assert len(list((data / 'imported-v01').glob('*'))) == 1
            old_count = page.evaluate('''async()=>{const r=indexedDB.open('mytify-library');const db=await new Promise(s=>r.onsuccess=()=>s(r.result));const t=db.transaction('audio');const q=t.objectStore('audio').count();const n=await new Promise(s=>q.onsuccess=()=>s(q.result));db.close();return n;}''')
            assert old_count == 1
            passed('UI: v0.1 migration preserves hash, like and old browser audio')

            page.get_by_role('button', name='Dodaj muzykę', exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button', name='Wybierz folder', exact=True).click(force=True)
            page.wait_for_timeout(300)
            report(page)
            tracks = api('/api/library')
            assert len(tracks) == 4 and all(t['available'] for t in tracks)
            assert all(t['title'] == 'Światło' and t['artist'] == 'Łódź' for t in tracks)
            assert len(list((data / 'imported-v01').glob('*'))) == 1, 'Linked folder copied audio'
            assert hashlib.sha256((music / 'sample.flac').read_bytes()).hexdigest() == old_hash
            assert next(t for t in tracks if t['id'] == old_hash)['locationCount'] == 2
            passed('UI: linked folder, four formats, Unicode tags and duplicate locations')

            audio, h = request('/api/audio/' + old_hash, headers={'Range': 'bytes=10-29'}, expected=206)
            assert audio == old_bytes[10:30] and h['Content-Range'] == f'bytes 10-29/{len(old_bytes)}'
            payload, h = request('/api/audio/' + old_hash, method='HEAD')
            assert not payload and int(h['Content-Length']) == len(old_bytes)
            request('/api/audio/' + old_hash, headers={'Range': 'bytes=999999999-'}, expected=416)
            payload, h = request('/api/audio/' + old_hash)
            assert payload == old_bytes
            cover = next(t['cover'] for t in tracks if t['id'] == old_hash)
            payload, h = request(cover.removeprefix(base))
            assert h['Content-Type'] == 'image/png' and payload.startswith(b'\x89PNG')
            assert len(api('/api/search?q=lodz%20swiatlo')) == 4
            assert api('/api/search?q=' + urllib.parse.quote('" OR * --')) == []
            passed('API: original bytes, seek ranges, HEAD, artwork and SQLite FTS')

            page.get_by_text('Album testowy', exact=False).first.click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button', name='Odtwórz album', exact=True).click(force=True)
            page.wait_for_timeout(300)
            def wait_audio(predicate):
                for _ in range(500):
                    state=api('/api/player/state')
                    if predicate(state):return state
                    time.sleep(.02)
                raise AssertionError('Audio timeout: '+str(state))
            state=wait_audio(lambda s:s['playing'] and s['positionMs']>50)
            assert state['output']['testSink'] and state['output']['backend']=='test-clock'
            page.get_by_role('button',name='Wstrzymaj',exact=True).click(force=True)
            page.wait_for_timeout(300)
            paused=wait_audio(lambda s:not s['playing'])
            assert page.evaluate('window.__unexpectedBrowserAudio')==0
            assert (temp/'rendered.f32le').stat().st_size>4096
            passed('UI: Rust decodes and advances playback through the test output, with no HTML audio')
            api('/api/player/command',method='POST',body={'action':'seek','positionMs':400})
            assert abs(api('/api/player/state')['positionMs']-400)<=1
            page.get_by_role('button',name='Powtarzaj kolejkę',exact=True).click(force=True)
            page.wait_for_timeout(300)
            wait_audio(lambda s:s['repeat'])
            page.get_by_role('button',name='Losowa kolejność',exact=True).click(force=True)
            page.wait_for_timeout(300)
            wait_audio(lambda s:s['shuffled'])
            passed('UI/API: native seek, repeat and shuffle share the Rust queue')
            page.get_by_role('button',name='Odtwarzaj na urządzeniu',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button',name='Zamknij',exact=True).wait_for()
            api('/api/player/command',method='POST',body={'action':'device','id':'test-44100'})
            page.get_by_text('44100 Hz',exact=False).first.wait_for()
            expect(page.get_by_role('button',name='Zamknij',exact=True)).to_be_enabled()
            page.get_by_role('button',name='Zamknij',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button',name='Zamknij',exact=True).wait_for(state='hidden')
            assert api('/api/player/state')['selectedDevice']=='test-44100'
            passed('UI/API: audio settings show the actual selected output and sample rate')

            page.get_by_role('button', name='Utwory', exact=True).click(force=True)
            page.wait_for_timeout(300)
            type_field(page,'Szukaj','lodz swiatlo')
            page.get_by_text('Wyniki wyszukiwania', exact=True).wait_for()
            page.wait_for_timeout(400)
            passed('UI: search without Polish diacritics')

            moved = temp / 'Przeniesiona muzyka'
            music.rename(moved)
            page.get_by_role('button', name='Źródła', exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button', name='Skanuj wszystkie', exact=True).click(force=True)
            page.wait_for_timeout(300)
            report(page)
            assert len(api('/api/library')) == 4
            assert sum(t['available'] for t in api('/api/library')) == 1
            assert next(t for t in api('/api/library') if t['id'] == old_hash)['liked']
            assert any(s['state'] == 'offline' for s in api('/api/sources'))
            passed('UI: detached source retains album, likes and offline entries')

            pick_path[:] = [str(moved)]
            page.get_by_role('button', name='Wskaż folder ponownie', exact=True).click(force=True)
            page.wait_for_timeout(300)
            report(page)
            assert all(t['available'] for t in api('/api/library'))
            assert len(api('/api/sources')) == 2
            assert next(s for s in api('/api/sources') if s['kind'] == 'folder')['files'] == 4
            passed('UI: relink restores availability without duplicate albums')

            removed = next(t for t in api('/api/library') if t['format'] == 'MP3')
            api('/api/tracks/' + removed['id'], method='DELETE')
            result = scan({'sourceId': 'all'})
            assert not result['errors'] and len(api('/api/library')) == 3
            assert (moved / 'sample.mp3').is_file()
            passed('API: forget entry leaves original and survives rescan')
            context.close()
            port = urllib.parse.urlparse(base).port
            stop()
            start(port)
            assert len(api('/api/library')) == 3
            assert next(t for t in api('/api/library') if t['id'] == old_hash)['liked']
            context, page = context_open()
            page.get_by_role('button', name='Źródła', exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_text('Źródła muzyki', exact=True).wait_for()
            if args.screenshots:
                Path(args.screenshots).mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(Path(args.screenshots) / 'mytify04-sources.png'))
            passed('UI/API: SQLite persists after backend and browser restart')
            page.get_by_role('button',name='Albumy',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_text('Album testowy',exact=False).first.click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button',name='Edytuj album',exact=True).click(force=True)
            page.wait_for_timeout(300)
            type_field(page,'^Album$','Moja kolekcja')
            type_field(page,'^Wykonawca albumu$','Moja biblioteka')
            with page.expect_file_chooser() as picker:
                page.get_by_role('button',name='Wybierz okładkę',exact=True).click(force=True)
                page.wait_for_timeout(300)
            with page.expect_response(lambda r:r.url==base+'/api/metadata/cover-file') as uploaded:
                picker.value.set_files(str(root/'test/fixtures/cover.png'))
            assert uploaded.value.ok, uploaded.value.text()
            expect(page.get_by_role('button',name='Zapisz poprawki',exact=True)).to_be_enabled()
            page.get_by_role('button',name='Zapisz poprawki',exact=True).click(force=True)
            page.wait_for_timeout(300)
            wait_library(lambda ts:len(ts)==3 and all(t['album']=='Moja kolekcja' for t in ts))
            modified=api('/api/library')
            assert len(modified)==3 and all(t['edited'] for t in modified), [(t['fileName'],t['album'],t['edited']) for t in modified]
            assert len(set(t['cover'] for t in modified))==1
            metadata_cover.update({'hash':modified[0]['cover'].split('/api/artwork/')[1].split('?')[0],'uri':modified[0]['cover']})
            assert hashlib.sha256((moved/'sample.flac').read_bytes()).hexdigest()==old_hash
            passed('UI/API: manual album edit and own cover upload preserve audio bytes')
            scan({'sourceId':'all','force':True})
            assert all(t['album']=='Moja kolekcja' for t in api('/api/library'))
            assert len(api('/api/search?q=moja%20kolekcja'))==3
            passed('API: force rescan and FTS retain effective metadata')
            page.get_by_role('button',name='Edytuj album',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button',name='Przywróć dane z plików',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('button',name='Przywróć',exact=True).click(force=True)
            page.wait_for_timeout(300)
            wait_library(lambda ts:len(ts)==3 and all(not t['edited'] for t in ts))
            passed('UI: reset restores original tags and embedded artwork')
            page.get_by_role('button',name='Opcje utworu',exact=True).first.click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('menuitem',name='Edytuj dane utworu',exact=True).press('Enter')
            page.wait_for_timeout(300)
            type_field(page,'Tytuł','')
            page.get_by_role('button',name='Zapisz poprawki',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.wait_for_timeout(300)
            expect(page.get_by_role('textbox',name=re.compile('Tytuł'))).to_be_visible()
            assert all(t['title'] for t in api('/api/library'))
            type_field(page,'Tytuł','Tytuł użytkownika')
            page.get_by_role('button',name='Zapisz poprawki',exact=True).click(force=True)
            page.wait_for_timeout(300)
            wait_library(lambda ts:any(t['title']=='Tytuł użytkownika' for t in ts))
            page.get_by_role('button',name='Zapisz poprawki',exact=True).wait_for(state='hidden')
            protected=next(t['id'] for t in api('/api/library') if t['title']=='Tytuł użytkownika')
            passed('UI: track editor validates title and saves a protected manual change')

            def preview():
                page.get_by_role('button',name='Znajdź dane i okładkę',exact=True).click(force=True)
                page.wait_for_timeout(300)
                page.get_by_role('button',name='Szukaj w MusicBrainz',exact=True).click(force=True)
                page.wait_for_timeout(300)
                page.get_by_role('button',name=re.compile('Album z propozycji')).last.click(force=True)
                page.wait_for_timeout(300)
                page.get_by_role('button',name='Pobierz okładkę z CAA',exact=True).wait_for()
                page.wait_for_timeout(200)
            preview()
            assert len([t for t in api('/api/library') if t['album']=='Album testowy'])==3
            page.get_by_role('button',name='Anuluj',exact=True).click(force=True)
            page.wait_for_timeout(300)
            assert all(t['album']=='Album testowy' for t in api('/api/library'))
            passed('UI: release preview and cancel make no catalog changes')
            preview()
            checkbox=page.get_by_role('checkbox',name='Uzupełnij tytuły i wykonawców utworów',exact=True)
            checkbox.focus()
            page.wait_for_timeout(150)
            checkbox.press('Space')
            expect(checkbox).to_be_checked()
            page.get_by_role('button',name='Pobierz okładkę z CAA',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_role('checkbox',name='Zastosuj pobraną okładkę',exact=True).wait_for()
            if args.screenshots:
                page.screenshot(path=str(Path(args.screenshots)/'mytify04-preview.png'))
            save_button=page.get_by_role('button',name='Zapisz wybrane propozycje',exact=True)
            save_button.focus()
            page.wait_for_timeout(150)
            save_button.click(force=True)
            page.wait_for_timeout(300)
            try:
                expect(save_button).to_be_hidden()
            except Exception:
                print(page.locator('flt-semantics-host').aria_snapshot(),flush=True)
                page.screenshot(path=str(root/'build/e2e-save-failure.png'))
                raise
            wait_library(lambda ts:sum(t['album']=='Album z propozycji' for t in ts)==2)
            page.get_by_role('button',name='Pobierz okładkę z CAA',exact=True).wait_for(state='hidden')
            after=api('/api/library')
            assert next(t for t in after if t['id']==protected)['title']=='Tytuł użytkownika'
            assert next(t for t in after if t['id']==protected)['album']=='Album testowy'
            assert all(not t['title'].startswith('Propozycja') for t in after), 'Ambiguous track order was applied'
            assert all(t['releaseId']==FAKE_ID for t in after if t['id']!=protected)
            passed('UI/API: chosen release saves atomically, protects edits and skips ambiguous song positions')
            page.get_by_role('button',name='Albumy',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.get_by_text('Album z propozycji',exact=False).first.click(force=True)
            page.wait_for_timeout(300)
            preview()
            checkbox=page.get_by_role('checkbox',name='Zastąp także własne poprawki',exact=True)
            checkbox.focus()
            page.wait_for_timeout(150)
            checkbox.press('Space')
            expect(checkbox).to_be_checked()
            page.set_viewport_size({'width':390,'height':844})
            page.wait_for_timeout(600)
            assert page.evaluate('document.documentElement.scrollWidth')<=390
            save_button=page.get_by_role('button',name='Zapisz wybrane propozycje',exact=True)
            save_button.focus()
            page.wait_for_timeout(150)
            save_button.click(force=True)
            page.wait_for_timeout(300)
            try:
                expect(save_button).to_be_hidden()
            except Exception:
                print(page.locator('flt-semantics-host').aria_snapshot(),flush=True)
                page.screenshot(path=str(root/'build/e2e-save-failure.png'))
                raise
            page.get_by_role('button',name='Pobierz okładkę z CAA',exact=True).wait_for(state='hidden')
            wait_library(lambda ts:sum(bool(t['releaseId']) for t in ts)==2)
            passed('UI: explicit overwrite choice and release dialog at 390 px')
            page.set_viewport_size({'width':1280,'height':850})
            page.get_by_role('button',name='Źródła',exact=True).click(force=True)
            page.wait_for_timeout(300)
            page.set_viewport_size({'width': 390, 'height': 844})
            page.wait_for_timeout(800)
            assert page.evaluate('document.documentElement.scrollWidth') <= 390
            if args.screenshots:
                page.screenshot(path=str(Path(args.screenshots) / 'mytify04-mobile.png'))
            passed('UI: source management at 390 px')
            context.close()
            ids=[t['id'] for t in api('/api/library')][:2]
            api('/api/player/command',method='POST',body={'action':'repeat','value':False})
            api('/api/player/command',method='POST',body={'action':'load','ids':ids,'index':0})
            state=wait_audio(lambda s:s['completed'])
            assert state['currentId']==ids[-1] and state['renderedFrames']>0
            passed('API: playback crosses tracks and completes after the entire browser is closed')
        assert not errors, errors
        assert not external, external
        passed('No browser errors or external requests')
        print(json.dumps({'passed': len(checks), 'checks': checks}, ensure_ascii=False, indent=2))
    except Exception:
        if 'page' in locals() and not page.is_closed():
            print(page.locator('flt-semantics-host').aria_snapshot(), flush=True)
            page.screenshot(path=str(root/'build/browser-regression-failure.png'))
        raise
    finally:
        stop()
