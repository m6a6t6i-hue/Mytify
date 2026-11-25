# Mytify 0.8

Flutter: wspólne UI, grupowanie albumów, wybór urządzenia, kreatory importu.
Windows: Wry/WebView2 i lokalny serwer tylko dla własnego UI; Rust/SQLite,
Symphonia, CPAL/WASAPI, Rubato sinc. Brak odtwarzania przez HTMLAudioElement.
Android: Kotlin, SQLite/SAF i Media3 MediaLibrarySession, wspólny właściciel
kolejki dla telefonu i Android Auto. Schemat Android nadal 2, PC nadal 3.

AirPlay: współdzielona biblioteka C++20, Apache-2.0, adapter C ABI/JNI.
Windows renderer Rust podaje PCM16 stereo 44,1 kHz. Android dekoduje Media3,
procesor przekazuje PCM do JNI, libsamplerate SINC_BEST_QUALITY dopasowuje
częstotliwość. Lokalny AudioTrack dostaje ciszę i dostarcza zegar; nie gra
równolegle na głośniku telefonu. Bufor SPSC, osobny wątek protokołu, HAP/PIN,
ścisła weryfikacja odbiornika. Uprawnienia parowania są w danych prywatnych.
Suwak AirPlay zmienia poziom sygnału; nie wysyła automatycznego SetVolume.

DLNA: SSDP i opis usług, AVTransport, RenderingControl oraz YXC do wybudzenia
Yamahy. PC ma osobny stan odbiornika i wysyła jego realną pozycję do UI.
Android podmienia Player w tej samej sesji na DlnaPlayer (SimpleBasePlayer),
zwalniając ExoPlayer. HTTP udostępnia tylko zatwierdzony identyfikator pliku,
losowy token i adres wybranego odbiornika; GET/HEAD/Range, bez dowolnych
ścieżek z żądania. Port LAN PC jest otwierany dopiero po wyborze DLNA.
Nieznana głośność wyłącza suwak. Odłączenie nie uruchamia samoczynnie PC.

CD: readonly uchwyt tylko wykrytego napędu optycznego Windows, TOC i CDDA
DeviceIoControl. Bounded read/porównania i raport rozbieżności, TOC Disc ID,
opcjonalne MusicBrainz. Nie jest to implementacja AccurateRip/CD-paranoia.

Analog: CPAL input → stałe pakiety SPSC → wątek zapisu WAV24. Callback nie
zapisuje na dysk i nie czeka na UI. Atomowe mierniki/clip/dropout. Awaria
pozostawia partial; odzyskanie wyrównuje do pełnej ramki. Oryginał master.wav
jest czytany bez modyfikacji podczas podziału. FLAC kodowany strumieniowo
flacenc, z nominalnym stałym rozmiarem bloków w STREAMINFO, MD5 PCM, tagami
Vorbis. Gotowe utwory zatwierdzane osobno i od razu dodawane do katalogu.
Zatrzymanie eksportu sprawdzane pomiędzy blokami, nie dopiero po całej stronie.

Ograniczenia protokołów i otwarte pomiary sprzętowe są w README i raporcie
testów. Skompilowany kod celu nie jest dowodem odsłuchu na urządzeniu.
