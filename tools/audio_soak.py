"""Time-based bounded-memory test of the real Rust pipeline, using its DEBUG test output.
This does not validate a sound card, WASAPI, hardware clock, or acoustic output.
"""
import argparse,json,subprocess,tempfile,time,urllib.request,os
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--backend',required=True);p.add_argument('--seconds',type=int,default=180);p.add_argument('--report',required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='mytify-soak-') as d:
 process=subprocess.Popen([args.backend,'--headless','--port','0','--data-dir',d,'--audio-test'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  config=json.loads(process.stdout.readline())
  def api(path,body=None):
   request=urllib.request.Request(config['base']+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json','X-Mytify-Token':config['token']})
   with urllib.request.urlopen(request,timeout=20) as r:return json.load(r)
  files=[str(root/'test/fixtures/audio'/n) for n in ['part-44100-a.wav','part-44100-b.flac']]
  job=api('/api/scan',{'paths':files,'folder':False})['job']
  while not api('/api/jobs/'+job)['finished']:time.sleep(.02)
  ids=[t['id'] for t in sorted(api('/api/library'),key=lambda t:t['fileName'])]
  api('/api/player/command',{'action':'repeat','value':True});api('/api/player/command',{'action':'load','ids':ids,'index':0})
  begin=time.monotonic();samples=[];last_print=-30
  while time.monotonic()-begin<args.seconds:
   state=api('/api/player/state');elapsed=time.monotonic()-begin
   rss=None;status=Path(f'/proc/{process.pid}/status')
   if status.exists():rss=int(next(line.split()[1] for line in status.read_text().splitlines() if line.startswith('VmRSS:')))*1024
   samples.append({'seconds':round(elapsed,2),'rss':rss,'renderedFrames':state['renderedFrames'],'underrunFrames':state['underrunFrames'],'error':state['error']})
   assert state['error'] is None,state
   if elapsed-last_print>=30:print(f'Soak {elapsed:.0f}s: {state["renderedFrames"]} frames, underruns {state["underrunFrames"]}, RSS {rss}',flush=True);last_print=elapsed
   time.sleep(1)
  state=api('/api/player/state');warmed=[s['rss'] for s in samples if s['seconds']>10 and s['rss'] is not None]
  report={'seconds':args.seconds,'testOutput':True,'hardwareValidated':False,'sourceRate':44100,'outputRate':state['output']['sampleRate'],'renderedFrames':state['renderedFrames'],'underrunFrames':state['underrunFrames'],'rssMin':min(warmed) if warmed else None,'rssMax':max(warmed) if warmed else None,'samples':samples}
  Path(args.report).write_text(json.dumps(report,indent=2))
  assert state['renderedFrames']>args.seconds*48000*.7,state
  assert state['underrunFrames']==0,state
  if warmed:assert max(warmed)-min(warmed)<64*1024*1024,'Unexpected memory growth'
  Path(args.report).write_text(json.dumps(report,indent=2));print('PASS: timed Rust audio pipeline soak',json.dumps({k:v for k,v in report.items() if k!='samples'}),flush=True)
 finally:process.terminate();process.wait(timeout=10)
