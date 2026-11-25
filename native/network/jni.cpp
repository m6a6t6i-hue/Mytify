#include <algorithm>
#include <jni.h>
#include "bridge.h"
#include <samplerate.h>
#include <array>
#include <cmath>
#include <cstring>
#include <string>
struct JSession{void* sender=nullptr;SRC_STATE* src=nullptr;int rate=0;float gain=0.8f;std::array<float,8192> input{};std::array<float,32768> output{};std::array<int16_t,32768> pcm{};uint32_t rng=938671;~JSession(){if(src)src_delete(src);mytify_airplay_close(sender);}};
static std::string str(JNIEnv*e,jstring s){if(!s)return {};const char*b=e->GetStringUTFChars(s,nullptr);std::string r=b;e->ReleaseStringUTFChars(s,b);return r;}
extern "C" JNIEXPORT jlong JNICALL Java_pl_mytify_mytify_AirplaySession_nativeOpen(JNIEnv*e,jobject,jstring host,jint port,jstring name,jint auth,jboolean ap2,jstring id,jstring creds,jstring password,jstring identity){
 auto*p=new JSession;p->sender=mytify_airplay_open(str(e,host).c_str(),port,str(e,name).c_str(),auth,ap2,str(e,id).c_str(),str(e,creds).c_str(),str(e,password).c_str(),str(e,identity).c_str());if(!p->sender){delete p;return 0;}return reinterpret_cast<jlong>(p);
}
extern "C" JNIEXPORT jint JNICALL Java_pl_mytify_mytify_AirplaySession_nativeState(JNIEnv*,jobject,jlong h){return mytify_airplay_state(reinterpret_cast<JSession*>(h)->sender);}
extern "C" JNIEXPORT void JNICALL Java_pl_mytify_mytify_AirplaySession_nativeCommand(JNIEnv*e,jobject,jlong h,jint kind,jstring text){mytify_airplay_command(reinterpret_cast<JSession*>(h)->sender,kind,str(e,text).c_str());}
extern "C" JNIEXPORT jstring JNICALL Java_pl_mytify_mytify_AirplaySession_nativeText(JNIEnv*e,jobject,jlong h,jint kind){char text[16384];mytify_airplay_text(reinterpret_cast<JSession*>(h)->sender,kind,text,sizeof(text));return e->NewStringUTF(text);}
extern "C" JNIEXPORT void JNICALL Java_pl_mytify_mytify_AirplaySession_nativeClose(JNIEnv*,jobject,jlong h){delete reinterpret_cast<JSession*>(h);}
extern "C" JNIEXPORT jint JNICALL Java_pl_mytify_mytify_AirplaySession_nativeWrite(JNIEnv*e,jobject,jlong h,jobject buffer,jint offset,jint bytes,jint rate,jint channels,jfloat gain){
 auto*p=reinterpret_cast<JSession*>(h);auto*data=static_cast<uint8_t*>(e->GetDirectBufferAddress(buffer));auto capacity=e->GetDirectBufferCapacity(buffer);
 if(!data||offset<0||bytes<0||static_cast<int64_t>(offset)+bytes>capacity||rate<8000||rate>384000||channels<1||channels>2||mytify_airplay_state(p->sender)!=1)return 0;
 int available=mytify_airplay_free(p->sender)/2;if(available<64)return 0;
 int frames=std::min(4096,bytes/(channels*2));if(frames==0||!std::isfinite(gain)||gain<0||gain>1)return 0;float initialGain=p->gain;float currentGain=initialGain;
 for(int i=0;i<frames;i++){int16_t l,r;std::memcpy(&l,data+offset+i*channels*2,2);if(channels==1)r=l;else std::memcpy(&r,data+offset+i*4+2,2);currentGain+=std::clamp(gain-currentGain,-1.f/(rate*.005f),1.f/(rate*.005f));p->input[i*2]=l/32768.f*currentGain;p->input[i*2+1]=r/32768.f*currentGain;}
 int used=frames,produced=frames;
 if(rate==44100){produced=std::min(frames,available);used=produced;std::copy_n(p->input.data(),produced*2,p->output.data());}
 else {if(p->rate!=rate){if(p->src)src_delete(p->src);int err;p->src=src_new(SRC_SINC_BEST_QUALITY,2,&err);p->rate=rate;if(!p->src)return 0;}SRC_DATA d{};d.data_in=p->input.data();d.input_frames=frames;d.data_out=p->output.data();d.output_frames=std::min(available,16384);d.src_ratio=44100./rate;if(src_process(p->src,&d)!=0)return 0;used=d.input_frames_used;produced=d.output_frames_gen;}
 p->gain=initialGain+std::clamp(gain-initialGain,-used/(rate*.005f),used/(rate*.005f));
 for(int i=0;i<produced*2;i++){auto random=[&]{auto&x=p->rng;x^=x<<13;x^=x>>17;x^=x<<5;return x/4294967295.;};double s=p->output[i];p->pcm[i]=static_cast<int16_t>(std::clamp(std::round(s*32768.+(s==0?0:random()-random())),-32768.,32767.));}
 if(produced)mytify_airplay_feed(p->sender,p->pcm.data(),produced*2);
 return used*channels*2;
}
extern "C" JNIEXPORT jint JNICALL Java_pl_mytify_mytify_AirplaySession_nativeDrain(JNIEnv*,jobject,jlong h){
 auto*p=reinterpret_cast<JSession*>(h);if(!p->src)return 0;if(mytify_airplay_state(p->sender)!=1)return -1;int space=mytify_airplay_free(p->sender)/2;if(space<64)return -1;
 SRC_DATA d{};d.data_out=p->output.data();d.output_frames=std::min(space,16384);d.end_of_input=1;d.src_ratio=44100./p->rate;if(src_process(p->src,&d)!=0)return 0;
 for(int i=0;i<d.output_frames_gen*2;i++)p->pcm[i]=static_cast<int16_t>(std::clamp(std::round(p->output[i]*32768.),-32768.,32767.));
 if(d.output_frames_gen)mytify_airplay_feed(p->sender,p->pcm.data(),d.output_frames_gen*2);return d.output_frames_gen;
}
extern "C" JNIEXPORT void JNICALL Java_pl_mytify_mytify_AirplaySession_nativeReset(JNIEnv*,jobject,jlong h){auto*p=reinterpret_cast<JSession*>(h);if(p->src)src_reset(p->src);}
