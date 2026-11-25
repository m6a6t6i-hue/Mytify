# Architektura 0.2

## Dostarczana paczka Windows

Mytify.exe = Rust (Tao/Wry + SQLite + Lofty + serwer loopback) + osadzony Flutter Web. WebView2 pokazuje ekrany Fluttera we własnym oknie; nie wymaga otwierania osobnej przeglądarki. To świadomy etap przejściowy do walidacji natywnego silnika audio. Interfejs pozostaje wspólnym kodem Flutter dla dalszych platform. Android wymaga osobnego adaptera uprawnień i Media3, a nie przeniesienia serwera Windows do usługi telefonu.

Rust: `native/mytify_core/src/catalog.rs` odpowiada za katalog i import; `server.rs` za most API i strumień audio; `desktop.rs` za okno Windows; `main.rs` za start i lokalizację danych. Flutter: `lib/main.dart`, `model.dart`, `queue.dart`; adapter uruchomionego interfejsu to `repository_web.dart` + `tools/web_bridge/bridge.js`. Zachowany adapter `repository_native.dart` umożliwia dalszą pracę z osobnym runnerem Flutter Windows i procesem Rust, ale ten runner nie jest binarnym wydaniem 0.2.

## Katalog

SQLite w trybie WAL, transakcje dla pojedynczego utworu, rozdzielenie tożsamości audio i lokalizacji. SHA-256 całego pliku jest identyfikatorem treści; dokładne kopie tworzą kolejne lokalizacje tego samego utworu. Nie jest to rozpoznawanie różnych wydań/remasterów ani fingerprint akustyczny. Skan strumieniowo hashuje oryginał, odczytuje tagi, zapisuje metadane i wydzieloną okładkę. Nie przepisuje plików muzycznych.

Szybki rescan pomija pliki o tym samym rozmiarze i czasie modyfikacji. `force: true` w API wymusza ponowne hashowanie, ale nie ma jeszcze osobnego przycisku tego trybu. Pełne przejście źródła oznacza nieodnalezione lokalizacje jako brakujące. Przerwany skan nie oznacza niesprawdzonych plików jako usuniętych. Niedostępny katalog główny oznacza źródło offline. Katalog zachowuje polubienia i brakujące lokalizacje. Ponowne wskazanie folderu przenosi ścieżki względem nowego katalogu głównego.

Wyszukiwanie FTS5: znormalizowany tekst bez znaków diakrytycznych, prefiksy bez wykonywania surowej składni użytkownika. Listy są obecnie ładowane w całości, więc wydajność przy 100 tys. utworów pozostaje zadaniem walidacyjnym.

## Most lokalny

Wyłącznie `127.0.0.1`, port domyślny 47173. Serwer sprawdza Host, Origin i Sec-Fetch-Site. Dane API wymagają losowego tokenu sesji. `/api/session` wydaje go tylko dla poprawnej lokalnej witryny; audio i okładki przyjmują także token w URL potrzebny elementom multimedialnym. Brak CORS, brak wysyłania muzyki do internetu. Okno blokuje nawigację poza własny origin. Mechanizm nie jest serwerem sieci domowej ani API dla niezaufanych aplikacji lokalnych.

- GET `/api/library`, `/api/sources`, `/api/search?q=...`.
- POST `/api/pick` → systemowy dialog Windows; `/api/scan` → asynchroniczne zadanie.
- GET/DELETE `/api/jobs/{id}` → postęp/zatrzymanie po bieżącym pliku.
- POST `/api/relink`, `/api/like/{id}`; DELETE `/api/tracks/{id}`, `/api/sources/{id}`.
- GET/HEAD `/api/audio/{id}` → oryginalny plik, pojedynczy Range 206/416.
- GET/HEAD `/api/artwork/{hash}` → okładka z cache.
- POST `/api/migrate-v01` → kopia blobu starej biblioteki, weryfikacja SHA-256, idempotentne przenoszenie polubień.

`--headless --port 0` wybiera wolny port i wypisuje konfigurację dla adaptera/testów. `--browser` uruchamia interfejs w domyślnej przeglądarce do migracji profilu 0.1. `--data-dir` i `--ui-dir` służą do izolowanych testów.

## Zbudowanie na Windows

Narzędzia: Flutter 3.50.1 / Dart 3.14, Rust stable, Node.js z npm, Visual Studio Build Tools z C++ i Windows SDK. Do samego używania paczki nie są potrzebne. WebView2 Runtime jest potrzebny do działania okna.

Uruchom `BUILD_WINDOWS.cmd` w folderze source. Skrypt instaluje zależności zgodnie z lockfile, buduje most JS, sprawdza Dart i Rust, buduje Flutter Web lokalnie wraz z CanvasKit i fontami, a następnie Rust z funkcjami `desktop,embed-ui`. Wynik MSVC: `native/mytify_core/target/release/mytify.exe`. WebView2 Loader jest wtedy linkowany statycznie. Zbudowane zasoby `build/web` muszą istnieć PRZED kompilacją Rust z embed-ui. Przy zmianie zasobów przebuduj oba etapy.

Dostarczony build powstał na Linux przez Rust `x86_64-pc-windows-gnullvm` i llvm-mingw UCRT 20261117. Ten wariant wymaga dołączonego x64 WebView2Loader.dll. Polecenie po zbudowaniu web: `cargo build --locked --release --target x86_64-pc-windows-gnullvm --features desktop,embed-ui`, z linkerem i kompilatorem C z llvm-mingw. Nie uruchomiono pliku PE na Windows; instrukcja MSVC też wymaga pierwszego wykonania na tym systemie.

## Testy

`flutter test`, `flutter analyze`; `cargo test --locked` w native/mytify_core. Zbuduj lokalny backend przez `cargo build --locked`, następnie z katalogu projektu: `python tools/browser_e2e.py --chrome <ścieżka-do-Chrome>`. Potrzebny Python z Playwright. Na Windows podaj `--backend native/mytify_core/target/debug/mytify.exe`. Test używa własnych sygnałów testowych i tymczasowych danych; zastępuje tylko systemowy picker odpowiedzią z lokalnymi ścieżkami. Pozostałe operacje przechodzą przez rzeczywisty Rust, SQLite i audio.
