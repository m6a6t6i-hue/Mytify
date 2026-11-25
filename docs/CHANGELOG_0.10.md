# Mytify 0.10, 25.11.2026

Redesign interfejsu, etapy P0 do P2 (Android i Windows), plus poprawki z 0.9.1 i 0.9.2.

## Poprawki z 0.9.x
- Windows: start kończył się `os error 5`. `persist()` synchronizował plik na uchwycie
  tylko do odczytu, a `FlushFileBuffers` na Windows wymaga prawa zapisu.
- Android Auto: nieskończone ładowanie. `onGetSession` odrzucał legacy MediaBrowser,
  kontrola dostępu została w `onConnectAsync`.
- Android Auto: foldery (albumy, playlisty, ostatnio dodane) mają okładki zamiast
  ikony błędu.

## Wspólne
- Design system: tokeny kolorów, odstępów, promieni, czasów animacji i typografii
  (`design.dart`). Zielony tylko dla stanów aktywnych i głównych akcji.
- Jeden kontroler stanu dla biblioteki, odtwarzania, kolejki, polubionych, playlist
  i nawigacji (`LibraryScreenState`). Indeks albumów i artystów (`library_index.dart`).
- Lokalna historia słuchania (ostatnio słuchane, najczęściej słuchane) liczona
  z rzeczywistego odtwarzania na tym urządzeniu. Utwór liczy się po 30 s lub połowie.
- Ustawienia widoku zapamiętywane (`shared_preferences`).
- Kolejka: odtwórz jako następny, dodaj do kolejki, usuwanie, zmiana kolejności,
  czyszczenie. Na PC przez `restore`, na Androidzie przez `load` + `seek`.
- Playlisty: tworzenie, zmiana nazwy, usuwanie, przypinanie, dodawanie wielu utworów,
  zmiana kolejności, usuwanie z playlisty.
- Menu kontekstowe utworu, albumu i playlisty. Na PC prawym przyciskiem, na telefonie
  przez przytrzymanie lub przycisk.
- Pasek postępu: dokładne przewijanie, czas pod kursorem, bez suwaka na 100%
  przy nieznanej długości. Głębia bitowa tylko dla formatów bezstratnych.
- Odznaki Lossless / Hi-Res tylko gdy wszystkie pliki spełniają warunek.
- Tło odtwarzacza i nagłówków z koloru okładki.

## Android
- Trzy zakładki: Start, Szukaj, Biblioteka. Źródła i import w ustawieniach i pod plusem.
- Start: duży odtwarzacz na górze, skróty Polubione i Losowo, półki. Mini-player
  pojawia się dopiero po przewinięciu dużego odtwarzacza.
- Biblioteka z filtrami (Wszystkie, Albumy, Artyści, Utwory, Playlisty), sortowaniem,
  widokiem listy/siatki i filtrem lokalnym. Polubione przypięte.
- Album: centralna okładka, akcje, lista bez powtarzania okładek i artysty.
- Pełnoekranowy odtwarzacz, także w poziomie. Mini-player 64 dp, przesunięcie zmienia utwór.

## Windows
- Sidebar (zwijany, regulowany), toolbar z historią i wyszukiwarką, dolny pasek
  odtwarzania, prawy panel (Odtwarzane, Kolejka, Informacje), regulowany i zamykany.
- Tabela utworów: zaznaczanie (Ctrl, Shift, Ctrl+A), podwójne kliknięcie odtwarza,
  sortowanie nagłówkiem, przeciąganie utworów na playlisty w sidebarze.
- Skróty klawiaturowe, przyciski myszy wstecz/dalej, tryb pełnoekranowy z
  ukrywaniem kontrolek.
- EXE ze statycznym CRT.

## Ograniczenia
- Wizualizacje audio (spectrum, waveform) nie zostały dodane: dźwięk dekoduje silnik
  Rust lub Media3, interfejs nie ma dostępu do sygnału, a atrapy są wykluczone.
- Ekran urządzeń, import CD/winyl, edycja metadanych i parowanie telefonu zachowują
  układ z 0.9 w nowej kolorystyce (P4).
- Brak zmiany szerokości kolumn tabeli i wyboru kolumn, kompaktowego okna, ikony w tray,
  kontrolek multimedialnych Windows i drag & drop plików z Eksploratora.
- 3 testy TLS transferu PC→telefon nie przechodzą na prawdziwym Windows
  (`os error 10053`). Do sprawdzenia przed poleganiem na parowaniu.
