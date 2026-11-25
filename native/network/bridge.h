#pragma once
#include <cstdint>
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
// Single producer for PCM. Commands and snapshots may be called concurrently.
API void* mytify_airplay_open(const char* host, int port, const char* name, int auth, int ap2, const char* id, const char* creds, const char* password, const char* identity);
API int mytify_airplay_state(void* p); // 0 connecting, 1 streaming, 2 PIN, 3 error, 4 closed
API int mytify_airplay_feed(void* p,const int16_t* data,int samples);
API int mytify_airplay_free(void* p);
API void mytify_airplay_command(void* p,int kind,const char* text); // 1 PIN, 2 volume, 3 restart/flush
API int mytify_airplay_text(void* p,int kind,char* dest,int capacity); // 0 error, 1 credentials
API void mytify_airplay_close(void* p);
