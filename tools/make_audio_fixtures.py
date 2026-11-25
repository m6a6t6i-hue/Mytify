"""Create original audio signals for decoder, transition and resampler tests. Requires FFmpeg."""
from pathlib import Path
import math,struct,wave,subprocess
root=Path(__file__).resolve().parents[1]/'test/fixtures/audio';root.mkdir(parents=True,exist_ok=True)
def wav(name,rate,frames,bits=16):
 with wave.open(str(root/name),'wb') as f:
  f.setnchannels(2);f.setsampwidth(bits//8);f.setframerate(rate)
  scale=2**(bits-1);data=bytearray()
  for frame in frames:
   for sample in frame:
    value=max(-scale,min(scale-1,round(sample*scale)))
    data.extend(value.to_bytes(bits//8,'little',signed=True))
  f.writeframes(bytes(data))
rate=48000
signal=[(.5*math.sin(2*math.pi*997*i/rate),.3*math.cos(2*math.pi*997*i/rate)) for i in range(rate)]
wav('whole.wav',rate,signal);wav('part-a.wav',rate,signal[:24000]);wav('part-b.wav',rate,signal[24000:])
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(root/'part-b.wav'),'-c:a','flac',str(root/'part-b.flac')],check=True)
(root/'part-b.wav').unlink()
rate44=44100
signal44=[(.5*math.sin(2*math.pi*997*i/rate44),.3*math.cos(2*math.pi*997*i/rate44)) for i in range(rate44)]
wav('whole-44100.wav',rate44,signal44);wav('part-44100-a.wav',rate44,signal44[:22050]);wav('part-44100-b.wav',rate44,signal44[22050:])
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(root/'part-44100-b.wav'),'-c:a','flac',str(root/'part-44100-b.flac')],check=True)
(root/'part-44100-b.wav').unlink()
wav('impulse-44100.wav',44100,[(.75 if i in [0,500,2047] else 0.0,)*2 for i in range(2048)])
hires=[(.5*math.sin(2*math.pi*1000*i/96000)+.25*math.sin(2*math.pi*30000*i/96000),)*2 for i in range(48000)]
wav('hires-24.wav',96000,hires,24)
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(root/'hires-24.wav'),'-c:a','flac',str(root/'hires-24.flac')],check=True)
wav('dc-44100.wav',44100,[(.25,-.25)]*12345)
for ext,codec in [('ogg','libvorbis'),('m4a','alac')]:
 subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(root/'whole.wav'),'-c:a',codec,str(root/('codec.'+ext))],check=True)
print('Original reference signals generated:',len(list(root.iterdir())),'files')
