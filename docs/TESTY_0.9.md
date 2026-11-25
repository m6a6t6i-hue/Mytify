# Mytify 0.9 — zakres sprawdzenia, 25.11.2026

## Wykonane w tej iteracji

- `cargo test --locked`: 57 testów, bez błędów (23 biblioteka, 15 audio,
  14 katalog, 5 edycje). W tym TLS, jednorazowy QR, uwierzytelnianie,
  cofanie dostępu, Range, okładki, trwałość tożsamości i playlist.
- `flutter analyze --no-pub`: bez uwag.
- `flutter test --no-pub`: 46 testów, bez błędów. W tym układ mobilny,
  karta odtwarzania przed treścią, ekran parowania, wybór albumów/playlist,
  wznowienie i powiadomienie UI o zmianie biblioteki z usługi pobierania.
- `tools/browser_e2e.py`: 22 scenariusze UI/API, bez błędów, na prawdziwym
  Rust/SQLite i zbudowanym Flutterze. Import, duplikaty, wyszukiwanie,
  źródła, edycja/okładki, reset i ochrona własnych zmian, restart danych,
  kolejka i odtwarzanie po zamknięciu interfejsu. Atrapy: wybór plików Windows,
  odpowiedzi MusicBrainz/CAA oraz testowe wyjście audio bez karty dźwiękowej.
  Brak błędów JS i nieoczekiwanych żądań zewnętrznych.
- `tools/transfer_ui_e2e.py`: rzeczywisty ekran PC, jawne włączenie TLS,
  render QR, klient przypinający certyfikat, aktualizacja listy telefonów,
  cofnięcie dostępu, zatrzymanie transferu i zapis playlisty przez edytor.
  Brak błędów JS. To klient testowy, bez fizycznego skanowania aparatem.

## Android i pliki wynikowe

- Android `assembleRelease`, `lintRelease`: zakończone powodzeniem.
- Android/Robolectric: 44 testy, bez błędów i pominięć, z rzeczywistym
  serwerem Rust uruchamianym przez `tools/transfer_e2e.py`. Sprawdzono dekodowanie
  prawdziwego QR, przypięty certyfikat i odrzucenie błędnego, wstrzymanie,
  odtworzenie menedżera i kolejki, wznowienie przez HTTP Range, SHA-256 i odrzucenie
  uszkodzonego prefiksu, deduplikację, ochronę zmian telefonu i kopię playlisty.
  Dwa testy polecenia głosowego sprawdzają filtr manifestu oraz bezpieczne
  przekazanie zapytania do sesji bez akceptowania ścieżek plików.
  Po pełnym zakończeniu procesu PC wszystkie pobrane pliki odczytano i porównano
  ich SHA-256. Sprawdzono bezpieczne usuwanie kopii oraz plików częściowych.
- APK: `apksigner verify` poprawny, pakiet pl.mytify.app, wersja 0.9.0 (12),
  tylko ARM64. Certyfikat SHA-256 identyczny z 0.8.2:
  `f965e8d645b6fce458affe5e986e072c5ce5ef9edc4b7634d2b20782b253f90b`.
- Windows: zbudowany PE x64, zasoby ikony i wersji 0.9.0, osadzony dokładnie
  końcowy main.dart.js i logo. DLL AirPlay i WebView2Loader zgodne sumą z 0.8.1.
  Szczegóły: BINARY_VERIFICATION_0.9.json, APK_VERIFICATION_0.9.json,
  TEST_RESULTS_0.9.json i raporty TEST-*.xml.

## Granice testów

Kompilacja Windows x64 na Linux nie zastępuje uruchomienia EXE na Windows 11.
Robolectric nie zastępuje fizycznego Androida: nie potwierdza zachowania aparatu,
Android Keystore, powiadomień i oszczędzania baterii Samsunga. Transfery testowe
wykorzystują lokalny interfejs testowy; działanie w realnym Wi-Fi i Zapora Windows
wymagają testu na urządzeniach. Produkcyjne QR akceptują prywatne adresy LAN;
loopback jest dopuszczony wyłącznie jawnie w teście i w serwerze debug.

Nie wykonano w tej iteracji odsłuchu na urządzeniach, testu Android Auto w aucie/DHU,
Yamahy, AirPlay, napędu CD ani interfejsu nagrywania. Te ścieżki zachowują kod
poprzedniego wydania. DLL nadajnika Windows jest identyczna z 0.8.1.
Brak nowej deklaracji bit-perfect, secure rip, certyfikacji lub zgodności każdego
odbiornika. Animacje oznaczają aktywne odtwarzanie, nie analizę widma audio.
