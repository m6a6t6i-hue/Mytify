#include "bridge.h"
#include "raop_sender.h"
#include "raop_loop.h"
#include "ring_buffer.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <deque>
#include <cstring>
#include <cstdlib>
#include <algorithm>
using namespace fxchain;
namespace {
struct Session {
 RingBuffer<int16_t> ring{16384};
 std::atomic<int> state{0}; std::atomic<bool> done{false};
 std::mutex mutex; std::deque<std::pair<int,std::string>> commands;
 std::string error,credentials; std::thread worker;
 ~Session(){done=true;if(worker.joinable())worker.join();}
};
}
API void* mytify_airplay_open(const char* host,int port,const char* name,int auth,int ap2,const char* id,const char* creds,const char* password,const char* identity) {
 if(!host||!name||!id||!creds||!password||!identity||port<1||port>65535||auth<0||auth>5)return nullptr;
 try {
  auto* p=new Session;
  p->credentials=creds;
  p->worker=std::thread([p,h=std::string(host),port,n=std::string(name),auth,ap2,d=std::string(id),pw=std::string(password),ident=std::string(identity)] {
   try {
    RaopLoop loop;
    RaopEvents events;
    events.launched=[p](bool ok,const std::string&e){ {std::lock_guard lock(p->mutex);p->error=e;}p->state=ok?1:3;};
    events.closed=[p]{ if(p->state!=3)p->state=4; };
    events.pinRequired=[p](const std::string&){p->state=2;};
    events.credentialsObtained=[p](const std::string&,const std::string&c){std::lock_guard lock(p->mutex);p->credentials=c;};
    RaopSender sender(loop,events);
    sender.attachRing(&p->ring);sender.setInputFormat(44100);sender.setStrictReceiverAuth(true);
    sender.setIdentity({"Mytify",ident,"Mytify"});
    auto start=[&]{std::string c;{std::lock_guard lock(p->mutex);c=p->credentials;}sender.setAuth(static_cast<RaopDeviceInfo::Auth>(auth),ap2!=0,d,c,pw);p->state=0;sender.start(h,port,n);};
    start();
    while(!p->done) {
     std::deque<std::pair<int,std::string>> cmds;{std::lock_guard lock(p->mutex);cmds.swap(p->commands);}
     for(auto& [kind,text]:cmds) {
      if(kind==1)sender.submitPin(text);
      if(kind==2)sender.setVolume(std::clamp(std::strtod(text.c_str(),nullptr),0.,100.));
      if(kind==3){p->state=0;sender.stop();int16_t scratch[1024];while(p->ring.tryPop(std::span<int16_t>(scratch,std::min<size_t>(1024,p->ring.availableRead())))){if(p->ring.availableRead()==0)break;}start();}
     }
     loop.pump(sender,std::chrono::milliseconds(8));
    }
    sender.stop();
   } catch(const std::exception&e){std::lock_guard lock(p->mutex);p->error=e.what();p->state=3;}
  });
  return p;
 }catch(...){return nullptr;}
}
API int mytify_airplay_state(void*p){return p?static_cast<Session*>(p)->state.load():4;}
API int mytify_airplay_free(void*p){return p?static_cast<int>(static_cast<Session*>(p)->ring.availableWrite()):0;}
API int mytify_airplay_feed(void*v,const int16_t*d,int n){if(!v||!d||n<0||n>16384)return 0;auto*p=static_cast<Session*>(v);if(p->state!=1)return 0;return p->ring.tryPush(std::span<const int16_t>(d,n))?n:0;}
API void mytify_airplay_command(void*v,int kind,const char*t){if(!v||!t)return;auto*p=static_cast<Session*>(v);if(kind==3)p->state=0;std::lock_guard lock(p->mutex);if(p->commands.size()<32)p->commands.emplace_back(kind,t);}
API int mytify_airplay_text(void*v,int kind,char*d,int cap){if(!v||!d||cap<1)return 0;auto*p=static_cast<Session*>(v);std::lock_guard lock(p->mutex);const auto&s=kind==1?p->credentials:p->error;int n=std::min<int>(cap-1,s.size());std::memcpy(d,s.data(),n);d[n]=0;return n;}
API void mytify_airplay_close(void*p){delete static_cast<Session*>(p);}
