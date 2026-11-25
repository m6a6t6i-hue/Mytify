# Native network dependencies

Vendored, unmodified upstream sources; Mytify adapters are bridge.cpp/bridge.h/jni.cpp outside their source directories.

- airplay/: https://github.com/akustikrausch/airplay2-sender-cpp, commit fc913509039412790aa2427558d35178aa7842ea, Apache-2.0. Upstream NOTICE and licenses/THIRD-PARTY-NOTICES.txt retain pyatv MIT and other attributions. Strict receiver authentication is enabled in Mytify.
- mbedtls/: Mbed TLS commit 2ca6c285a0dd3f33982dd57299012dacab1ff206 (3.6.0), Apache-2.0 selected from dual license.
- mbedtls/framework/: commit 750634d3a51eb9d61b59fd5d801546927c946588.
- airplay/third_party/ed25519/: upstream vendored orlp/ed25519 commit b1f19fab4aebe607805620d25a5e42566ce46a0e, zlib.
- libsamplerate/: version 0.2.2, BSD-2-Clause. JNI uses SRC_SINC_BEST_QUALITY. Windows uses the existing Rust sinc renderer and feeds 44.1 kHz directly.

CMake FETCHCONTENT_SOURCE_DIR_MBEDTLS points at these bundled sources. No Qt, Python or GPL AirPlay implementation is linked into Mytify. Full dependency license texts are also aggregated in docs/NETWORK_NOTICES.txt.
