# Mytify — plan iteracji

Zakres uzgodniony: Windows, Android, Android Auto. Interfejs Flutter; katalog PC Rust + SQLite od 0.2; katalog Android Kotlin + SQLite/SAF od 0.5. Import fizycznych nośników odbywa się początkowo na PC. iOS, CarPlay, macOS i Linux pozostają poza pierwszym wydaniem.

Każda iteracja kończy się paczką do uruchomienia, źródłami, informacją o wykonanych testach i listą ograniczeń. Funkcji nie uznajemy za gotową na podstawie samego wyglądu przycisków.

| Wersja | Zakres | Kryterium odbioru |
| --- | --- | --- |
| 0.1 | Fundament Flutter: import plików/folderu, lokalna biblioteka, tagi i osadzone okładki, wyszukiwanie, albumy, polubione, kolejka, odtwarzanie | Własne pliki da się zaimportować, odsłuchać i odnaleźć po ponownym uruchomieniu. Wersja testowa PC w przeglądarce oraz kod celu Windows. |
| 0.2 | Rust + SQLite: trwały katalog, źródła wskazywane bez kopiowania, ponowny skan, duplikaty i brakujące pliki; natywna paczka Windows | Duża biblioteka nie wymaga ponownego importu; odłączony dysk nie usuwa albumów. Natywny build sprawdzony na Windows. |
| 0.3 | MusicBrainz, okładki online, propozycje metadanych i ręczne poprawki | Niepewne wydania wymagają wyboru; własne poprawki przetrwają skan. |
| 0.4 | Odtwarzanie PC: walidacja gapless, urządzeń wyjściowych, błędów i stabilności | Pomiary przejść i długiej sesji, testy MP3/FLAC/AAC/ALAC/WAV. Jawny zakres zweryfikowanych formatów. |
| 0.5 | Android: import lokalny, Media3, praca w tle i sterowanie systemowe | APK sprawdzony na telefonie, również po zgaszeniu ekranu i przy przerwaniach audio. |
| 0.6 | Android Auto: biblioteka, playlisty, wyszukiwanie, kolejka, tryb offline | Test Desktop Head Unit i samochodu. Ten sam właściciel odtwarzania co w aplikacji telefonu. |
| 0.7 | Kreator Audio CD: wykrycie napędu, wydanie albumu, FLAC, błędy odczytu, weryfikacja | Import prawdziwej płyty do gotowego albumu; raport niepewnych odczytów. |
| 0.8 | Kreator winylu/kasety: podłączenie, kalibracja, strony A/B, zachowanie oryginału, podział na utwory | Test rzeczywistego interfejsu audio; poprawienie podziału bez ponownego nagrywania. |
| 0.9 | Transfer PC → telefon: parowanie i kopie offline | Album pobrany na telefon gra także po wyłączeniu PC i sieci. |

**Status 0.1:** implementacja i zbudowana paczka testowa PC ukończone. Testy: 12 Dart, 8 importera web oraz 8 scenariuszy interfejsu. Natywny EXE Windows nie jest jeszcze zweryfikowany.

## Decyzje dla 0.1

- UI od początku w Flutterze; wersja przeglądarkowa służy do testów na PC i wykorzystuje ten sam kod ekranów.
- Prototyp używa adapterów lokalnego katalogu i metadanych. Integracja Rust/SQLite ma wyraźny etap 0.2; nie jest przedstawiana jako już działająca.
- Import 0.1 tworzy zarządzaną kopię plików. Oryginały pozostają bez zmian. Na Windows kopia znajduje się w danych aplikacji, a w wersji testowej web w magazynie przeglądarki. Źródła wskazywane bez kopiowania dochodzą w 0.2.
- Działa lokalnie; żadne audio nie jest wysyłane do zewnętrznego serwera. Brak zapytań o metadane online w tej wersji.
- Zachowujemy oryginalne bajty muzyki. Odtwarzanie korzysta z dostępnego backendu; brak deklaracji bit-perfect lub zweryfikowanego gapless w 0.1.
- Wynik importu pokazuje liczbę dodanych, pominiętych i błędnych plików. Użytkownik może odsłuchać bibliotekę przed dodaniem kolejnych źródeł.
- Przy braku tagów używamy nazwy pliku i oznaczamy brakujące dane. Nie wymyślamy wykonawcy ani albumu.

## Weryfikacja i granice środowiska

Build 0.2 został skompilowany do Windows x64 z Linux przez llvm-mingw i zawiera okno Wry/WebView2. Lokalny skrypt MSVC wymaga Windows i Visual Studio Build Tools. Kompilacja nie zastępuje testu gotowego EXE na Windows. APK i integracja samochodowa mają osobne etapy, ponieważ wymagają sprawdzenia usług w tle i urządzeń.

Daty następnych wydań nie są deklarowane automatycznie. Kolejna iteracja kontynuuje ten sam projekt na podstawie kodu i wyników poprzedniej, a zakres można skorygować po testach użytkownika.

## Status 0.2

Zaimplementowano katalog Rust/SQLite, wskazywane źródła bez kopiowania, rescan, duplikaty, brakujące pliki, relink, zachowanie polubień oraz migrację 0.1. Dostarczany jest Windows EXE z osadzonym Flutter Web we własnym oknie WebView2. Testy: 14 Rust, 10 Dart, 12 integracji API/UI; analiza Dart bez uwag. Otwarty punkt kryterium odbioru: uruchomienie i odsłuch na prawdziwym Windows. Pełna walidacja jakości odtwarzania pozostaje w 0.4.

Następna iteracja 0.3: odczyt kandydatów wydań MusicBrainz, propozycje okładek, wybór użytkownika, ręczne poprawki zapisywane osobno od odczytanych tagów. Pliki źródłowe domyślnie bez zmian.

## Status 0.3

Dodano warstwę poprawek niezależną od tagów, edycję utworu/albumu, własne PNG/JPEG, cofanie do danych pliku, wyszukiwanie wydań MusicBrainz, podgląd ścieżek i wybiórcze zatwierdzanie, pobieranie przedniej okładki CAA, ochronę własnych poprawek i cache offline. Nowy schemat bazy 3 zachowuje dane 0.2 i zapisuje spójną kopię przed migracją.

Testy 0.3: 26 Rust, 13 Dart, 19 scenariuszy UI/API; analiza Dart bez uwag.

Otwarta walidacja: start Windows i żywe połączenie z MusicBrainz/CAA. W środowisku wykonania MusicBrainz zwrócił 403; kontrolowane testy nie są zastępstwem testu dostępności serwisów z komputera użytkownika.

Następny etap 0.4: natywne wyjście audio na PC, pomiary jakości/ciągłości i obsługa urządzeń. Dopiero później Android + Media3 (0.5) i Android Auto (0.6). CD i kreator analogowego nagrywania nadal mają własne iteracje 0.7–0.8.

## Status 0.4

Odtwarzanie przeniesiono z WebView2 do Rust: Symphonia + CPAL/WASAPI, stały bufor, SRC sinc f64, jedna kolejka niezależna od UI, wybór urządzenia, zapamiętanie wyjścia/głośności i diagnostyka. Zweryfikowano granice WAV/FLAC również przy 44,1 → 48 kHz oraz brak alokacji callbacku w testowanym przebiegu. Zachowane funkcje katalogu i opisów 0.3.

Testy 0.4: 43 Rust, 16 Dart, 22 UI/API oraz powtórna pętla 180 s bez niedoboru bufora w wyjściu testowym. Pierwszy nieoptymalizowany debug nie przeszedł próby czasowej; profil DSP został poprawiony.

Otwarte kryteria: rzeczywisty Windows/WASAPI, DAC/USB/Bluetooth, wielogodzinna sesja i szersza macierz kodeków. Tryb wyłączny/bit-perfect nie są dostarczone. AAC odtwarza, ale bez potwierdzenia gapless; OPUS/APE/WavPack/DSD bez natywnego dekodera w tej wersji.

Następny etap 0.5: Android (Media3, pliki telefonu, praca w tle i kontrola systemowa). Android Auto pozostaje osobnym etapem 0.6. Ewentualne problemy testu PC mają pierwszeństwo przed rozszerzaniem platform.


## Status 0.5 — Android, wersja testowa

Dodano import SAF, trwały katalog SQLite, deduplikację, rescan, relink, postęp
i anulowanie. Osobna usługa Media3 odpowiada za kolejkę, focus, sterowanie
systemowe i pracę w tle; wspólne UI ma odtwarzacz mobilny. Dostępne ręczne
poprawki i opcjonalne MusicBrainz/CAA. Wyniki w TESTY_0.5.md.

Kryterium sprzętowe pozostaje otwarte: S21 Ultra, wygaszony ekran, przerwania,
słuchawki/Bluetooth, dostęp do plików po restarcie. Kompilacja i Robolectric
nie są zastępstwem testu odsłuchu. Następna iteracja 0.6: Android Auto;
błędy instalacji/odsłuchu 0.5 mają pierwszeństwo.


## Status 0.6 — Android Auto, wersja testowa integracji

Dodano MediaLibraryService i legacy browser, cztery kategorie, kontekstowe
rozwijanie kolejki, wyszukiwanie, okładki przez wąski FileProvider oraz playlisty
edycyjne na telefonie. Jeden ExoPlayer obsługuje telefon i host samochodowy.
Schemat Android 1 → 2 zachowuje katalog. Wyniki: TESTY_0.6.md.

Otwarte kryterium: DHU z połączonym telefonem i rzeczywisty samochód.
Nie oznaczamy tej części kryterium odbioru jako ukończonej na podstawie
kompilacji ani Robolectric. Kolejny planowany zakres: kreator Audio CD (0.7),
z pierwszeństwem poprawek instalacji i odsłuchu zgłoszonych przez użytkownika.

## Status implementacji 0.7–0.8 (wersja testowa)

0.6.1 naprawia grupowanie jednego albumu różniącego się wielkością liter i odstępami.
Dodano wybór odbiorników AirPlay oraz DLNA/Yamaha na Windows i Androidzie.
0.7 implementuje kreator CD, TOC/Disc ID, wybór wydania, powtórne odczyty i FLAC.
0.8 implementuje wejścia/poziomy, WAV stron A/B, odzyskanie, znaczniki/ciszę i FLAC.

Kryteria sprzętowe pozostają otwarte: Windows/WASAPI/ADC/napęd, Yamaha,
telefon w tle i samochód/DHU. MusicCast obsługiwany jako pojedynczy odbiornik
DLNA plus sterowanie YXC, bez własnego grupowania multiroom. Nie zmieniamy
kryteriów odbioru na „zaliczone” na podstawie samego builda.
Szczegóły wykonanych testów: TESTY_0.8.md. Następny zakres: 0.9 transfer PC → telefon.


## Status 0.8.1 — interfejs i animacje

Nowa identyfikacja zielono-czarna i ikona, duży odtwarzacz, panel PC, animacje
aktywności i przejść, ograniczenie ruchu i poprawki dostępności. Bez zmiany
schematu katalogu. Szczegóły: CHANGELOG_0.8.1.md, TESTY_0.8.1.md.
Kolejna funkcjonalna iteracja nadal 0.9: transfer PC → telefon. Otwarta
walidacja sprzętowa oraz dalsze rozszerzenia: CO_DALEJ_0.8.1.md.

## Status implementacji 0.9 — transfer PC → telefon

Jednorazowy QR, przypięty TLS, wybór albumów i playlist, pobieranie oryginalnych
plików do prywatnej pamięci telefonu, wstrzymanie/wznowienie, SHA-256 i zarządzanie
kopiami. Playlisty PC zapisują się trwale. To kopia kolekcji, bez synchronizacji
w obie strony. Zachowano UI 0.8.1 i odtwarzacz jako pierwszą sekcję mobile 0.8.2.
Aktualny zakres sprawdzenia i otwarte testy sprzętowe: TESTY_0.9.md.
Dalsze kroki: CO_DALEJ_0.9.md.
