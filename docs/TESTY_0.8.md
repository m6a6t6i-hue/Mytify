# Mytify 0.8 — zakres weryfikacji

Wydanie testowe, 24 listopada 2026. Kompilacja krzyżowa na Linux.
Wyniki dotyczą oprogramowania; nie są potwierdzeniem odsłuchu na sprzęcie.

| Kontrola | Wynik |
| --- | --- |
| Rust, logika + integracje katalogu/audio/importu/sieci | 53 testy |
| Flutter, w tym mobile UI, albumy, kreator CD i blokada nieznanej głośności | 33 testy |
| Kotlin/Robolectric: katalog, odtwarzanie, Android Auto i HTTP Range | 38 testów |
| AirPlay upstream: protokół/crypto oraz TCP/UDP loopback | 2 zestawy CTest |
| Wspólne UI Flutter Web + rzeczywisty Rust/SQLite | 22 scenariusze Playwright |
| Analiza Dart | Bez uwag |
| Windows x64 | EXE Wry/WebView2 z osadzonym UI + DLL AirPlay |
| Android ARM64 | APK pl.mytify.app, versionName 0.8.0, versionCode 9; release lint |

## Co sprawdzają testy

- Zgłoszony album: osiem utworów z różną wielkością liter daje jeden kafelek
  i jedną kolejkę Android Auto. Białe znaki, fallback wykonawcy, różni
  wykonawcy i nieopisane pliki mają osobne regresje.
- WAV → FLAC → dekoder: dokładnie te same próbki dla 16 i 24 bitów, włącznie
  z niepełnym ostatnim blokiem. Master WAV zachowuje identyczne bajty.
- Odzyskanie WAV po awarii odcina wyłącznie niepełną ramkę; podział nie może
  mieć cofniętych/pustych zakresów. Krótkie przerwy nie są uznawane za utwory.
  Anulowanie kodowania nie publikuje nieukończonego FLAC ani nie zmienia mastera.
- CD: oficjalny wektor Disc ID MusicBrainz; powtórne odczyty, większość,
  niejednoznaczne wyniki i niepełne sektory. Bez fizycznego napędu.
- DLNA: kontrolowany transport SOAP i rzeczywisty serwer Range na PC,
  rzeczywisty serwer SAF/HTTP na Androidzie, HEAD oraz odmowa dostępu do
  niezatwierdzonego pliku. Odczyt pozycji i głośności z odbiornika;
  brak SetVolume przy połączeniu i brak aktywnego suwaka bez odczytu.
- AirPlay: testowy odbiornik protokołu AP1/AP2, HAP/PIN, ścisłe sprawdzenie
  proof/signature, audio/sync/timing/retransmit oraz loopback. JNI i docelowa
  DLL kompilują się; test protokołu nie jest testem całej ścieżki na telefonie.
- UI/API: import plików, FTS, odłączanie źródła, relink, polubienia, zachowanie
  danych po restarcie, metadane/okładki, kolejka/seek/repeat/shuffle,
  odtwarzanie po zamknięciu przeglądarki oraz widok mobilny 390 px.
  Systemowy picker i odpowiedzi serwisów metadanych są w tych testach kontrolowane.

Test samodzielnego zakończenia kolejki ma 3 s oczekiwania na 1 s audio,
bez odpytywania UI; zachowuje dokładne asercje liczby próbek i utworu.
Poprzedni margines 250 ms był zbyt krótki przy równoległych kompilacjach
oraz dla grubszej rozdzielczości zegara testowego na Windows. Nie zmieniono
kryteriów zawartości audio. Testy programowe nie mierzą opóźnień DAC.

## Pozostałe testy sprzętowe

- Uruchomienie i odsłuch EXE na Windows 10/11, WASAPI i rzeczywisty DAC.
- Telefon/S21 Ultra: JNI AirPlay, praca w tle, połączenia, słuchawki/Bluetooth.
- Konkretny model Yamahy: wykrywanie, DMC, formaty FLAC/WAV/AAC, przewijanie,
  utrata Wi-Fi i zachowanie głośności. Brak deklaracji wszystkich modeli.
- PIN/sterowanie i wielogodzinny odsłuch rzeczywistego odbiornika AirPlay.
- Płyta CD w napędzie, uszkodzone płyty, cache/offset/jitter. Brak AccurateRip.
- Fizyczny interfejs: poziomy, przesterowanie, długie nagranie, słuchowy
  podział stron i odzyskanie po przerwaniu zasilania.
- Android Auto Desktop Head Unit i samochód. Jedna sesja jest sprawdzona
  programowo; nie wykonano połączenia z rzeczywistym hostem.

Kolejny etap sprzętowy zaczynamy od zainstalowania aktualizacji, sprawdzenia
połączonego albumu i wybrania dostępnego odbiornika. iOS/CarPlay/macOS/Linux
nie są dostarczane w tym wydaniu; transfer PC → telefon jest zakresem 0.9.
