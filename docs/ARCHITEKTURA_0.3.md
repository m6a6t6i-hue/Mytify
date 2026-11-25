# Architektura 0.3

Baza 0.2: Wry/Tao + lokalny serwer Rust, SQLite, Lofty i osadzony Flutter Web. Szczegóły bazowego katalogu: ARCHITEKTURA_0.2.md. Dostarczany EXE używa WebView2, a zachowany osobny runner Flutter Windows nie jest wydaniem binarnym.

## Zmiany

`metadata_overrides(track_id, patch)` przechowuje wyłącznie poprawki i wybrane okładki. Odczytane tagi w `tracks` pozostają bazą; odpowiedź katalogu nakłada poprawki i aktualizuje indeks FTS. Reset usuwa warstwę poprawek. Edycja grupy jest jedną transakcją: błąd dowolnego wpisu wycofuje całość. Rescan nie nadpisuje poprawek. Jeśli zawartość istniejącego pliku zmienia SHA po zewnętrznej edycji, zapisane poprawki są przenoszone do nowej tożsamości, o ile ta nie ma własnych. Dokładne kopie po SHA nadal są jednym utworem i dzielą opis.

Schemat 3 migruje tę samą bazę w library-v2. Przed migracją schematu 2 wykonuje spójny backup SQLite, również z danymi WAL. Nowsza nieobsługiwana wersja jest odrzucana.

`metadata.rs`: walidacja poprawek, FTS, parsery MusicBrainz, cache, klient HTTPS i dekodowanie obrazów. `reqwest` ma certyfikaty z systemu, timeout połączenia 8 s, żądania 22 s, kontrolowane przekierowania, limit odpowiedzi JSON 2 MiB i obrazu 8 MiB. Pobrania tylko przez HTTPS do MusicBrainz/CAA/Archive.org. Przekierowanie HTTP z CAA jest podnoszone do HTTPS przed pobraniem. Użytkownik nie podaje dowolnych adresów URL. Brak wysyłania audio do tych usług.

Częstotliwość żądań: globalny gate 1,1 s na start zapytania; brak automatycznego zapętlania błędów 429/503. Cache wyszukiwania 24 h, wydania 7 dni. Znormalizowana okładka JPG <=1200 px jest lokalnym zasobem wskazywanym przez hash. Dekoder ma limit wymiarów i pamięci; SVG/HTML są odrzucane. Bieżący User-Agent identyfikuje osobisty prototyp Mytify/0.3.0; przed publiczną dystrybucją należy podać rzeczywisty kontakt projektu, zgodnie z zasadami MusicBrainz.

`lib/metadata_ui.dart`: edycja ręczna i wybór wydania; `metadata_models.dart`: DTO. UI nie wyszukuje automatycznie po imporcie. Tytuły utworów są osobną opcją; sugestie po numerach wymagają jednoznaczności, a brak dopasowania zachowuje dotychczasowy tytuł. Użytkownik widzi licznik zakresu zmian, rozbieżność liczby ścieżek i ochronę poprawionych wpisów. Przycisk Zapisz wysyła gotową listę patchy, bez automatycznego pobrania lub zastosowania nowej odpowiedzi.

## API

Wspólne zabezpieczenia Host/Origin/token jak w 0.2. Nowe: GET /api/metadata/search?album=...&artist=..., GET /api/metadata/release/{mbid}, GET /api/metadata/cover/{mbid}; POST /api/metadata/cover-file (bajty PNG/JPEG), POST /api/metadata/edits (lista {id,patch}), POST /api/metadata/reset (lista id). Patch dopuszcza title,artist,album,albumArtist,trackNumber,discNumber,cover,source,releaseId. Pusty cover ukrywa okładkę, jego brak nie zmienia obecnego wyboru. URL obrazka nie jest dopuszczalną wartością cover.

## Budowanie i testy

Te same narzędzia i skrypt BUILD_WINDOWS.cmd co w 0.2: Flutter 3.50.1, Dart 3.14, Node + npm, Rust stable i MSVC/Windows SDK. Najpierw npm ci + npm run build w tools/web_bridge, flutter pub get, flutter analyze, flutter test, flutter build web --release --no-web-resources-cdn --no-wasm-dry-run. Potem cargo test --locked i cargo build --locked --release --features desktop,embed-ui w native/mytify_core. Test UI: python tools/browser_e2e.py --chrome <ścieżka> po zbudowaniu backendu i web; potrzebny Playwright.

Dostarczony build: x86_64-pc-windows-gnullvm z llvm-mingw UCRT 20261117, wymagający dołączonego x64 WebView2Loader.dll. Runtime WebView2 jest osobnym komponentem Microsoftu. Binarny start Windows nadal nie był testowany.

Źródła dokumentacji protokołów: https://musicbrainz.org/doc/MusicBrainz_API , https://musicbrainz.org/doc/MusicBrainz_API/Search , https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting , https://musicbrainz.org/doc/Cover_Art_Archive/API . Nie ma fingerprintingu, edycji tagów na dysku, importu Audio CD ani przechwytywania analogowego sygnału w tej iteracji.
