# Mytify 0.1 — wyniki weryfikacji

## Wykonane sprawdzenia

| Sprawdzenie | Wynik |
| --- | --- |
| `flutter analyze` | Brak problemów |
| `flutter test` | 12 testów zaliczonych |
| `npm test` w `tools/web_bridge` | 8 testów zaliczonych |
| `flutter build web --release --no-web-resources-cdn --no-wasm-dry-run` | Zbudowano |
| Test kompletnej aplikacji w Chrome Headless, na zbudowanym Flutter Web | 8 scenariuszy zaliczonych; brak błędów JavaScript i żądań zewnętrznych |

## Scenariusze interfejsu

1. Import rzeczywistych plików FLAC, MP3, AAC/M4A i WAV przez selektor plików aplikacji. Odczyt tytułów, polskich znaków i osadzonej okładki FLAC.
2. Uruchomienie odtwarzania i pauza. Zweryfikowano stan elementu multimedialnego i rosnący czas odtwarzania; test był wykonywany bez fizycznego odsłuchu na głośnikach.
3. Wyszukiwanie „lodz swiatlo” dla tagów „Łódź / Światło”.
4. Import folderu: wykrycie czterech identycznych zasobów już obecnych w bibliotece.
5. Zamknięcie procesu przeglądarki i ponowny start z tym samym profilem: biblioteka i polubienie pozostały zapisane.
6. Usunięcie zarządzanej kopii przez menu i okno potwierdzenia.
7. Renderowanie układu przy szerokości 390 px.
8. Kontrola ruchu sieciowego: zasoby pobierano wyłącznie z lokalnego serwera; brak żądań zewnętrznych i błędów JavaScript.

## Testy logiki i danych

- Wyszukiwanie, grupowanie kompilacji według album artist, kolejność dysków/utworów.
- Stabilna kolejka niezależna od aktualnego filtra; koniec kolejki i tryb powtarzania.
- Zachowanie bieżącego utworu przy włączeniu/wyłączeniu shuffle.
- Usuwanie bieżącego i ostatniego utworu bez niepoprawnego indeksu.
- Zapis/odczyt pól katalogu.
- Natywny odczyt metadanych MP3, FLAC, M4A i WAV, w tym polskie znaki, czas, sample rate i okładka FLAC.
- Pełny SHA-256 zamiast porównywania nazw plików. Zweryfikowano identyczność bajtów źródła i zapisanej kopii.
- Trwałe polubienie, usuwanie zasobu audio, pomijanie innych rozszerzeń i obsługa uszkodzonego pliku bez przerwania importu poprawnego.

## Ograniczenia weryfikacji

- Nie wykonano kompilacji ani uruchomienia natywnego EXE na Windows. Windows wymaga osobnego środowiska Windows i narzędzi Visual Studio. Kod tego celu przeszedł analizę Dart, a jego czytnik metadanych testy na plikach.
- Skrypt PowerShell do uruchamiania paczki przygotowano dla Windows 11; nie był uruchamiany na fizycznym komputerze Windows w tym środowisku. Sama aplikacja była testowana przez lokalny serwer HTTP.
- Nie wykonano testów APK, Android Auto, fizycznego DAC, napędu CD ani wejścia analogowego. Te funkcje mają osobne iteracje w planie.
- Nie wykonano pomiarów bit-perfect, gapless ani wielogodzinnego odtwarzania. Nie są deklarowane jako potwierdzone funkcje 0.1.
- Testy używają krótkich, własnych sygnałów pomiarowych. Nie potwierdzają zgodności ze wszystkimi wariantami kodeków i tagów występującymi w kolekcjach użytkowników.

Narzędzia: Flutter 3.50.1 / Dart 3.14.0, Node.js 24, Python / Playwright, Chrome Headless 145. Testy i skrypty odtworzenia znajdują się w źródłach.
