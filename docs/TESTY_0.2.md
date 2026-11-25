# Mytify 0.2 — weryfikacja

Stan: paczka rozwojowa, kompilacja Windows zakończona; test działania EXE na Windows pozostaje otwarty. Środowisko testów: Linux, Flutter 3.50.1 / Dart 3.14, Rust 1.100, Chrome Headless Shell; własne sygnały 440 Hz, bez cudzych nagrań.

| Kontrola | Wynik |
| --- | --- |
| Rust: testy katalogu i Range | 14/14 |
| Dart: model i kolejka | 10/10 |
| Integracja API + interfejs + audio | 12/12 |
| flutter analyze | bez uwag |
| Flutter Web release, zasoby lokalne | zbudowany |
| Rust Windows x64 desktop + embed-ui | skompilowany PE32+ x64 |
| Start, picker, WebView2 i wyjście audio na Windows | jeszcze nie sprawdzone |

Testy Rust: rzeczywiste tagi i cover FLAC/MP3/M4A/WAV z polskimi znakami, import bez kopiowania, duplikaty między źródłami, szybki rescan, brakujący plik, odłączenie/powrót dysku, rename, polubienia, zapominanie wpisu bez kasowania oryginału, przerwany skan, ponowne otwarcie SQLite i FTS, odłączenie źródła, relink bez mnożenia lokalizacji, migracja 0.1 bez resetu późniejszych polubień, granice HTTP Range.

Testy Dart obejmują wyszukiwanie, grupowanie i kolejność albumów, snapshot i koniec kolejki, shuffle, usuwanie, serializację oraz pomijanie offline i odświeżenie kolejki po skanie.

12 scenariuszy integracji: ochrona API token/Host/Origin; migracja starego IndexedDB z zachowaniem oryginalnego blobu i polubienia; import folderu czterech formatów bez kopiowania; oryginalne bajty audio, Range, HEAD, cover i FTS; rzeczywiste odtwarzanie i pauza; wyszukiwanie bez polskich znaków; odłączenie źródła zachowujące katalog; wskazanie nowej lokalizacji; zapomnienie wpisu zachowujące plik; pełny restart backendu i profilu przeglądarki; układ źródeł przy szerokości 390 px; brak błędów konsoli i zewnętrznych żądań podczas przebiegu.

Systemowy picker jest w tych testach zastąpiony ścieżkami własnych plików. To nie dowodzi działania natywnego dialogu na Windows. Rzeczywisty przebieg odtwarza sygnał w Chrome; nie potwierdza sterownika Windows, kodeków WebView2 ani jakości analogowego wyjścia.

Nie testowano: prawdziwego Windows/WebView2, bibliotek 100 tys.+, wielogodzinnej sesji, gapless/bit-perfect/WASAPI exclusive, ALAC/DSD i wszystkich wariantów kodeków, Androida, Android Auto, CD, nagrywania. Nie obiecujemy tych funkcji na podstawie samego importu.

## Pierwszy test na Windows 11

Uruchom Mytify.exe po rozpakowaniu całej paczki. Dodaj folder z kilkoma MP3 i FLAC; sprawdź album, odsłuch i przewijanie. Polub utwór, zamknij i otwórz aplikację. Przenieś testowy folder, wykonaj skan i użyj „Wskaż folder ponownie”. Oczekiwany wynik: album i polubienie pozostają, a pliki znów grają. Tego punktu nie oznaczamy jako zaliczonego przed rzeczywistym wykonaniem.
