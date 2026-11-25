# Android 0.5

Flutter → MethodChannel pl.mytify/library → Kotlin. Długie zadania katalogu
oraz HTTP wykonuje jeden worker; postęp wraca EventChannel pl.mytify/import.
SAF zapewnia content:// URI i trwałe uprawnienia tylko do odczytu wybranych
plików/folderów. Bez MANAGE_EXTERNAL_STORAGE i uprawnień do całej pamięci.

catalog-android.sqlite3, schemat 1: tracks, sources, locations, ignored.
ID jest hashem pełnej zawartości SHA-256, zgodnym z PC. Kilka lokalizacji może
wskazywać ten sam utwór. Poprawki są osobne od tagów; batch jest transakcyjny.
Polubienia i poprawki przetrwają zmianę treści pod tym samym URI.
Zapomniany utwór jest ignorowany do jawnego ponownego dodania pliku.

Zatwierdzanie importu per plik. Anulowanie kooperatywne; nieodwiedzone pliki
nie stają się brakujące po przerwaniu. Źródło niedostępne zachowuje wpisy.
Pełny hash wymaga ponownego czytania audio przy skanie, co trwa przy dużym zbiorze.
Tagi odczytuje MediaMetadataRetriever; fallback do nazwy. Okładki JPEG do 1200 px,
limit wejściowy 8 MB. Flutter używa Image.file, nie transportu base64 całej kolekcji.

Jeden ExoPlayer + MediaSession w PlaybackService (MediaSessionService).
Activity jest kontrolerem; zniszczenie UI nie zwalnia odtwarzacza.
Media3 zapewnia powiadomienie i kontrolery systemowe. Włączono float output
dla PCM wysokiej rozdzielczości, jeżeli wspiera je urządzenie. Nie oznacza
to pomiaru bit-perfect ani ominięcia miksera Androida. ExoPlayer obsługuje focus
oraz becoming-noisy. Lokalne wake lock podczas odtwarzania; brak boot receivera.
Stan kolejki i pozycja są zapisywane przy zmianach stanu oraz co 10 s.
Nagłe zabicie procesu może cofnąć pozycję o ostatni interwał. Przywracanie
kolejki nie uruchamia Play, a niedostępne wpisy są pomijane.

Online: MusicBrainz REST/CAA, wyłącznie na żądanie użytkownika, HTTPS,
lista hostów przekierowań, limity wielkości/czasu, odstęp MusicBrainz 1,1 s,
cache 24 h wyszukiwania i 7 dni wydań. Brak wysyłania plików/ścieżek/hashy.

Android używa Kotlin/SQLite ze względu na SAF. Nie uruchamia serwera PC Rust
ani CPAL. Wspólne DTO pozwalają później oprzeć transfer/synchronizację na SHA-256;
nie oznacza to dostarczenia synchronizacji w tej iteracji.

Android Auto wymaga MediaLibraryService, drzewa biblioteki i osobnych testów DHU.
To krok 0.6; nie dodano deklaracji obsługi samochodowej w 0.5.

Dokumentacja:
- https://developer.android.com/media/media3/session/background-playback
- https://developer.android.com/training/data-storage/shared/documents-files
- https://developer.android.com/jetpack/androidx/releases/media3
- https://musicbrainz.org/doc/MusicBrainz_API
- https://musicbrainz.org/doc/Cover_Art_Archive/API
