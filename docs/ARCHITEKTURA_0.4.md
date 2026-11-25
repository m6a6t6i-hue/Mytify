# Architektura 0.4 — natywne audio PC

Dotychczasowy host Wry/Tao i Flutter Web zostają interfejsem. Odtwarzanie nie używa media_kit, HTMLAudioElement ani adresów HTTP z muzyką. Flutter wysyła identyfikatory utworów z lokalnego katalogu i polecenia; tylko Rust rozwiązuje je do zatwierdzonych ścieżek. Istniejący endpoint plików zostaje dla zgodności, ale nowy player nie korzysta z niego.

## Silnik

- `audio/decoder.rs`: Symphonia 0.5.5, włączone kontenery/kodeki, format.enable_gapless; mono → stereo, odrzucenie >2 kanałów i nieprawidłowych próbek. Konwerter Rubato 0.16.2 SincFixedIn f64: 256 tap, 256 faz, Blackman-Harris, chunk 1024. Wersje i wyrównanie są przypięte testami impulsu, pierwszej/ostatniej próbki i długości; nie odcinamy dodatkowo output_delay, który w tym wariancie oznacza lookahead.
- `audio/sequence.rs`: czyta kolejne pliki w jednym strumieniu wejściowym dla stałej częstotliwości źródła. Zachowuje historię/fazę sinc na granicach i mapuje wynik na identyfikator utworu oraz jego pozycję. Inna częstotliwość źródła kończy grupę i otwiera nowy konwerter, bez sztucznego dopełniania bloków w kolejce wyjścia.
- `audio/render.rs`: stała pula bloków 512 klatek stereo i dwie kolejki SPSC rtrb. Producer dekoduje na roboczym wątku, callback oddaje bloki do puli. Callback nie czyta dysku, nie czeka na mutex, nie alokuje/zwalnia sterty. Atomiki: pauza, epoka, bieżący indeks, pozycja, głośność i liczniki. Przy seek stara epoka jest odrzucana również podczas pauzy. Głośność ma krótki ramp, aby ograniczyć zipper/click.
- `audio/output.rs`: CPAL 0.18.2, Windows WASAPI shared. Preferuje F32 stereo przy częstotliwości domyślnej konfiguracji urządzenia, w razie potrzeby obsługuje I16/I32. I16 z ditherem TPDF, cyfrowa cisza pozostaje zerowa. Dla wyjścia >2 kanałów stereo trafia na pierwszą parę, pozostałe są zerowane. Backend urządzeń tej paczki jest tylko dla Windows.
- `audio/mod.rs`: jeden właściciel kolejki i wyjścia, serializowane polecenia, loop/repeat/shuffle, ustawienia, log ostatniego błędu. Stabilny identyfikator CPAL, brak cichego fallbacku na inne urządzenie. Przy zamykaniu okna host zapisuje bieżące ustawienia bez oczekiwania na zakończenie dekodowania pliku.

Pula ma około 3 s audio, maksymalnie 2048 bloków (~8 MiB próbek), plus małe bufory dekodera i konwertera. Utwory nie są ładowane w całości. Kolejka ma limit 10 tys. identyfikatorów. Kod kanałów/configów wymaga sprawdzenia na prawdziwych urządzeniach Windows, w szczególności przy odłączeniu USB i zmianie urządzenia domyślnego.

## Kontrola i UI

GET `/api/player/state`, GET `/api/player/devices`, POST `/api/player/command`. Pole `action`: load (ids,index), play, pause, stop, seek (positionMs), next, previous, volume (value), repeat/shuffle (value), device/jump (id). Brak dowolnych URL lub ścieżek w tym API. Dotychczasowe zabezpieczenia token/Host/Origin pozostają.

`lib/audio_player.dart` serializuje polecenia, odrzuca spóźnione odpowiedzi sprzed nowego polecenia, odpytuje stan co 150 ms i redukuje polecenia suwaka głośności. Pozycja jest prezentacją licznika wyjścia, a nie zegarem uruchamiającym kolejny plik. Seek jest wysyłany po zakończeniu przeciągania. Native queue jest źródłem prawdy; lokalny PlaybackQueue służy do wyświetlania. Ustawienia pokazują rzeczywistą konfigurację strumienia i błędy. Samplerate/F32 nie dowodzą parametrów analogowego DAC.

## Test output

Wyłącznie debug build zawiera `--audio-test` i `--audio-test-output <plik.f32le>`. To osobny, jawny test clock wywołujący **ten sam Renderer**, ale bez karty dźwiękowej; stan ma testSink=true i backend=test-clock. UI wyświetla to jako wyjście testowe bez dźwięku. Release odrzuca flagi testowe, a sterownik test-clock nie jest do niego kompilowany.

Profil dev ma jawne optymalizacje mytify-core (2) i Rubato (3), aby także debug dotrzymywał czasu wyjścia. Pierwsza nieoptymalizowana próba czasowa miała niedobory, powtórna 180 s przeszła; gorąca część audio w release korzysta z optymalizacji 3 i LTO (pozostały kod zachowuje optymalizację rozmiaru).

Testy unit porównują PCM, SRC, granice, alokacje callbacku, seek, zatrzymanie, urządzenie/ustawienia i działanie bez odpytywania UI. Playwright korzysta z debug backendu: faktyczne dekodowanie w Rust i test output, zakaz HTMLMediaElement.play; online metadata i picker Windows są kontrolowane. `tools/audio_soak.py` wykonuje czasowy test pętli i pamięci bez sprzętu. To nie zastępuje wielogodzinnego odsłuchu WASAPI ani testu DAC.

## Budowanie

Tak jak poprzednio: Node/npm dla mostka, Flutter 3.50.1 / Dart 3.14 dla web, Rust stable oraz MSVC/Windows SDK. `BUILD_WINDOWS.cmd` uruchamia kontrole, buduje Flutter Web i potem Rust desktop,embed-ui. Nowe zależności są w Cargo.lock; nie potrzeba mpv/FFmpeg DLL w aplikacji. FFmpeg jest jedynie narzędziem do odtworzenia własnych testowych plików przez `tools/make_audio_fixtures.py`.

Dostarczony EXE to x86_64-pc-windows-gnullvm z llvm-mingw UCRT 20261117, z x64 WebView2Loader.dll obok. Oryginalne źródła i notices są dołączone. W celu uruchomienia testu UI: zbuduj `cargo build` i `flutter build web`, następnie `python tools/browser_e2e.py --backend <debug-mytify> --chrome <Chrome>`. Nie podawaj release jako debug backendu testowego.

Źródła API: https://docs.rs/cpal/0.18.2/cpal/ , https://docs.rs/symphonia/0.5.5/symphonia/ , https://docs.rs/rubato/0.16.2/rubato/ . Zgodność próbek w testach odnosi się do strumienia w programie; systemowy miks, urządzenie fizyczne i kodeki AAC mogą mieć inne ograniczenia. Brak deklaracji bit-perfect, exclusive lub ogólnego gapless dla każdego formatu.
