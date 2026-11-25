# Mytify 0.9 — muzyka z PC na telefon (wersja testowa)

Paczka zawiera Windows x64, Android ARM64 z obsługą Android Auto i komplet źródeł.
Nowość: parowanie kodem QR i pobieranie wybranych albumów oraz playlist z PC
na telefon w sieci lokalnej. Ukończone kopie działają po wyłączeniu komputera.
Zachowany interfejs w czerni i zieleni, ikona Mytify i duża karta odtwarzania
na telefonie jako pierwsza sekcja bezpośrednio pod wyszukiwarką.

## Instalacja

**Windows 10/11 x64:** wypakuj całą paczkę i uruchom Windows/Mytify.exe.
Zachowaj obok mytify_airplay.dll oraz WebView2Loader.dll. Potrzebny WebView2 Runtime.
Katalog pozostaje w %LOCALAPPDATA%/Mytify/library-v2. Nie usuwaj danych poprzedniej wersji.

**Android 8+ ARM64:** zainstaluj Android/Mytify_0.9_Android_Auto.apk jako aktualizację.
Nie odinstalowuj poprzedniej wersji: zachowasz bibliotekę, playlisty i uprawnienia
folderów. Pakiet pl.mytify.app, wersja 0.9.0 (12), ten sam certyfikat rozwojowy.
To APK do testów, bez publikacji w Google Play.

## PC → telefon, krok po kroku

1. Podłącz oba urządzenia do tej samej prywatnej sieci lokalnej IPv4.
   Zaimportuj lub przeskanuj muzykę w Mytify na PC.
2. PC: „Połącz telefon” → włącz parowanie. Jeżeli komputer ma kilka interfejsów,
   wybierz adres sieci, z której korzysta telefon. Zezwól aplikacji na dostęp
   w sieci prywatnej w Zaporze Windows (transfer domyślnie TCP 47479).
3. Telefon: Dodaj → „Z komputera” → zeskanuj QR. Alternatywnie wklej kod parowania.
   Kod jest jednorazowy i ważny przez 120 sekund; można wygenerować nowy.
4. Wybierz albumy lub playlisty i „Pobierz na telefon”. Lista pokazuje rozmiar
   wyboru. Aplikacja sprawdza dostępne miejsce przed rozpoczęciem.
5. Pobieranie można wstrzymać i wznowić. Po przerwaniu aplikacji otwórz ten
   ekran i wybierz wznowienie. Można też usunąć niedokończone pobranie:
   znikają pliki częściowe, ukończone utwory pozostają w bibliotece.
6. Po zakończeniu muzyka jest dostępna lokalnie, również po wyłączeniu PC.
   Android Auto korzysta z tej samej biblioteki i usługi odtwarzania.

Przesyłane są oryginalne pliki, bez konwersji audio. Każdy ukończony plik przechodzi
kontrolę SHA-256; częściowe pliki nie trafiają do biblioteki. Pobieramy metadane
i dostępne okładki z katalogu PC. Brak okładki nie blokuje utworu. Istniejące
polubienia i poprawki metadanych na telefonie są zachowane. Identyczne pliki
nie tworzą kolejnych utworów. Playlisty z PC są kopiami; ich ponowny import
nie nadpisuje istniejącej kopii edytowanej na telefonie.

To kopiowanie wybranego stanu kolekcji, bez automatycznej synchronizacji w obie
strony. Zmiany i usunięcia na PC nie usuwają kopii z telefonu. Kopie znajdują się
w prywatnych danych aplikacji: odinstalowanie Mytify je usuwa. Do usunięcia kopii
konkretnego PC służy przycisk na ekranie transferu; oryginały na PC i własne pliki
telefonu pozostają. Usunięcie samego utworu z katalogu nie usuwa pliku kopii.

Parowanie przypina certyfikat TLS konkretnego PC; dane parowania na Androidzie
są szyfrowane kluczem Android Keystore. Serwer transferu uruchamiasz jawnie;
przycisk zatrzymania zamyka udostępnianie. Na PC można cofnąć dostęp telefonu.
Nie jest potrzebne konto ani chmura. Zmiana adresu IP PC może wymagać ponownego
zeskanowania kodu. Sieć gościnna lub izolacja klientów może blokować połączenie.

Szczegóły w docs/CHANGELOG_0.9.md, docs/TESTY_0.9.md i docs/CO_DALEJ_0.9.md.

## Podwójny album

Nazwy albumu i wykonawcy albumu porównujemy bez rozróżniania wielkości liter
i zbędnych odstępów. Kafelki łączą się również w istniejącej bibliotece,
bez ponownego importu. Nie zmieniamy tagów, plików ani polubień.
Różni wykonawcy, akcenty i interpunkcja nadal mogą oznaczać różne albumy.

## Odtwarzanie na amplitunerze

1. Telefon/PC i odbiornik podłącz do tej samej sieci lokalnej IPv4.
2. Naciśnij ikonę głośników na dolnym pasku lub ikonę Cast u góry telefonu.
   W dużym panelu PC i pełnym odtwarzaczu dostępne jest także „Odtwarzaj na”.
3. Odśwież urządzenia i wybierz odbiornik oraz protokół.
4. Jeżeli odbiornik wyświetli PIN AirPlay, wpisz go w tym samym oknie.
5. Powrót: wybierz „Ten telefon” lub systemowe wyjście komputera.

**Yamaha / MusicCast:** sterowanie jednym odbiornikiem/strumieniem przez
DLNA AVTransport i dodatkowy przycisk wybudzenia Yamaha Extended Control.
W ustawieniach Yamahy może być wymagane DMC Control = Enable oraz Network
Standby do wybudzenia. Samo odtwarzanie plików z NAS nie gwarantuje obsługi
zdalnego sterowania DLNA. Grupy MusicCast ustawisz w aplikacji Yamahy;
Mytify 0.8 nie tworzy własnych grup ani zsynchronizowanego multiroom.

DLNA przesyła oryginalny plik, również FLAC, z obsługą przewijania/Range.
Odbiornik musi obsługiwać jego kodek. Nie ma automatycznego transkodowania.
Pozycja odtwarzania pochodzi z odbiornika. Nie ustawiamy jego głośności przy
łączeniu; jeśli nie udostępnia odczytu głośności, suwak jest niedostępny.

**AirPlay:** własny nadajnik AP1/AP2, parowanie HAP i PIN oraz zapamiętanie
parowania w prywatnych danych aplikacji. Stereo 16 bit / 44,1 kHz; AP2 ALAC,
AP1 niezaszyfrowany L16 dla zgodnych odbiorników. Źródła o innych parametrach
przechodzą konwersję. Suwak reguluje poziom sygnału aplikacji, nie głośność
amplitunera. Możliwe opóźnienie i przerwa przy przewijaniu/pauzie.
Tryb hasła RTSP oraz starszy Legacy PIN nie są obsługiwane przez Mytify 0.8.
Nie deklarujemy zgodności ze wszystkimi urządzeniami oznaczonymi AirPlay.

Sieć gościnna/izolacja klientów może uniemożliwiać wykrywanie. Na Windows
zezwól Mytify na dostęp w sieci prywatnej, jeśli zapyta Zapora Windows.
Przy utracie odbiornika aplikacja nie przełącza samoczynnie na głośniki PC.
Android Auto nadal korzysta z jednej usługi MediaLibrarySession; wybór
urządzeń wykonuj w telefonie, poza prowadzeniem pojazdu.

## Audio CD — Windows, zakres 0.7

Dodaj → Płyta Audio CD → napęd → Odczytaj płytę. Opcjonalnie rozpoznaj Disc ID
w MusicBrainz i wybierz właściwe wydanie/krążek, sprawdź tytuły i importuj.
Otrzymasz opisane FLAC 16 bit / 44,1 kHz w bibliotece i raport odczytu.
Ukończone utwory pozostają po anulowaniu lub błędzie kolejnej ścieżki.

Powtarzane odczyty porównujemy; rozbieżności wymagają dodatkowych prób
i są raportowane. Cache napędu może zmniejszać niezależność prób. Brak
AccurateRip, korekcji offsetu napędu, pełnej korekcji jitter/C2 i obsługi
CD-Extra/mixed-mode. Nie oznaczamy tego jako zweryfikowanego „secure rip”.
Gotowe pliki są w danych aplikacji, podfolder cd-imports. Raport ostatniej
operacji: last-ingest-report.json, dodatkowo READ_REPORT.json przy zakończeniu.

## Winyl i kaseta — Windows, zakres 0.8

1. Dodaj → Winyl, kaseta lub inne urządzenie.
2. Gramofon: USB albo LINE po przedwzmacniaczu PHONO. Magnetofon: LINE OUT
   do wejścia liniowego interfejsu audio. Wybierz wejście i częstotliwość.
3. Sprawdź poziom na najgłośniejszym fragmencie: szczyty około −12 do −6 dBFS,
   bez czerwonego przesterowania. Kontrola poziomu nie włącza odsłuchu wejścia.
4. Zatrzymaj kontrolę, nazwij stronę A/B i rozpocznij nagranie. Możesz dodawać
   znaczniki początku kolejnych utworów. Zatrzymaj i zachowaj stronę.
5. Wybierz nagranie, opcjonalnie zaproponuj podział według ciszy, popraw
   czasy i tytuły, zastosuj znaczniki oraz eksportuj FLAC do biblioteki.

Zachowujemy pełny oryginał WAV 24 bit; eksporty nie zmieniają mastera.
Parametry rzeczywistego ADC ograniczają jakość — kontener 24 bit nie dodaje
rozdzielczości urządzeniu 16 bit. Bez domyślnej normalizacji, odszumiania
czy korekcji RIAA w aplikacji. Limit pojedynczego WAV: około 4 GB.

„Otwórz folder nagrań” prowadzi do zapisanych masterów i eksportów. Nagranie
przerwane awarią można odzyskać z listy. Utrata próbek/błąd wejścia zatrzymuje
nagranie z komunikatem; zapisany fragment pozostaje, bez ukrywania przerwy.
Na Androidzie zaimportujesz gotowe pliki; fizyczne nośniki obsługujemy na PC.
Gotowe importy można skopiować na telefon funkcją „Połącz telefon” (0.9).

## Ograniczenia i źródła

Kompilacja Windows na Linux nie zastępuje uruchomienia EXE i odsłuchu na
Windows. Robolectric i testy protokołów nie zastępują telefonu, samochodu,
Yamahy ani przetwornika audio. Brak deklaracji bit-perfect, gapless po sieci
lub certyfikacji AirPlay/MusicCast. Dalsze platformy pozostają poza zakresem 0.9.

Źródła są w source/, instrukcje BUILD_WINDOWS.cmd i BUILD_ANDROID.cmd.
Licencje zależności i przypięte źródła: docs/ i native/network/SOURCE_PINS.md.
