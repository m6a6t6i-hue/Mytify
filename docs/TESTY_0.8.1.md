# Mytify 0.8.1 — weryfikacja UI

24 listopada 2026. Testowa aktualizacja 0.8; kompilacja krzyżowa na Linux.

| Kontrola | Wynik |
| --- | --- |
| Rust: katalog, DSP, import, sieć | 53 testy, bez błędów |
| Flutter: albumy, odtwarzacz, import, playlisty, głośność i animacje | 38 testów, bez błędów |
| Kotlin / Robolectric | 38 testów, bez błędów |
| Flutter Web + rzeczywisty Rust/SQLite | 22 scenariusze Playwright, bez błędów przeglądarki i zewnętrznych zapytań |
| Analiza Dart | Bez uwag |
| Windows x64 | Kompilacja release, osadzone aktualne UI, zasób ikony PE i ikona okna; kontrola struktury PE |
| Android ARM64 | Release APK 0.8.1 (10), pl.mytify.app, lint release, kontrola podpisu i ABI |
| Wygląd | Uruchomione UI: szeroki PC 1440×950 oraz telefon 412×915 z kontrolowaną biblioteką jednego albumu; widoki 390 px w E2E |

Nowe regresje sprawdzają: zatrzymanie dekoracyjnych tickerów po pauzie,
ponowne uruchomienie po play, brak ruchu w tle i przy disableAnimations,
wywołanie play z klawiatury i semantyczną akcję przycisku, szybkie przejścia
Start → Dodaj → Start oraz pełny odtwarzacz na 320×700, 360×800 i 780×360.
Wygaszane ekrany nie dublują przycisków w odczycie dostępności.

Kontrolowana biblioteka do oceny wyglądu nie jest dołączona do aplikacji;
nowa instalacja nie zawiera przykładowych utworów. Nie mierzono FPS, zużycia
baterii ani opóźnień na fizycznym telefonie. Wskaźnik aktywności nie analizuje
próbek audio; jego ruch nie jest synchronizacją z rytmem nagrania.

Natywny protokół AirPlay i biblioteka Windows DLL są zachowane z 0.8; to
wydanie nie zmienia ich implementacji. Dwa zestawy testów CTest protokołu
pochodzą z weryfikacji 0.8 (nie są raportowane jako ponownie wykonane).

Otwarta pozostaje walidacja Windows/WASAPI, prawdziwego telefonu, odbiornika
Yamaha/AirPlay, CD, wejścia audio i Android Auto DHU/samochodu. Nie wykonano
tych prób na podstawie zrzutów ani symulacji. Szczegóły ograniczeń funkcji
są w TESTY_0.8.md i CO_DALEJ_0.8.1.md.
