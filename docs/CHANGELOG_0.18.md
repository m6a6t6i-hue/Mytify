# Mytify 0.18, 25.11.2026: panele audio, importu, nawigacja źródeł, wizualizator

## Nawigacja źródeł (PC)
- W sidebarze jedna pozycja „Źródła muzyki”. Osobna pozycja „Dodaj źródło” usunięta.
- „Źródła muzyki” to osobny widok (trasa `sources`) z przyciskiem „Dodaj źródło”,
  który otwiera to samo menu co plus w pasku narzędzi i na Androidzie.
- Stara trasa `settings/sources` prowadzi do tego samego widoku.
- Ustawienia na PC: Audio, Import, Wygląd, Informacje (źródła i telefon są w sidebarze).

## Ustawienia → Audio
- Sekcja „Wyjście” na stronie, bez modala: urządzenie, odświeżanie, głośność, wyciszenie.
- Popover urządzeń w playerze i ustawienia korzystają z jednego stanu (`OutputDevices`).
  Samo otwarcie panelu tylko wyszukuje urządzenia, nie zmienia wyjścia.
- „Zaawansowane”: zwijana „Diagnostyka dźwięku” (wiersze etykieta/wartość, parametry
  wyjścia i źródła tylko przy załadowanym utworze) i „Protokoły i zgodność”.

## Import (PC)
- Widok „Import” w normalnym układzie zamiast ekranu „Z fizycznej kolekcji”.
  Zakładki tekstowe „Audio CD” i „Winyl i kaseta”, bez „Gotowe”.
- Stan importu żyje przez całą sesję: zmiana zakładki lub widoku nie kasuje formularza
  ani nie przerywa pracy. Trwająca operacja jest widoczna w pasku narzędzi.
- Otwarcie widoku nie pauzuje muzyki i nic nie uruchamia. Pauza dopiero przy
  „Sprawdź poziom” i „Nagraj”.
- Audio CD: osobne stany (szukanie, brak napędu, brak płyty, nieobsługiwana płyta,
  odczyt, utwory, import, koniec, błąd), nazwa napędu z Windows, czasy utworów,
  zaznaczanie utworów, folder zapisu, „Obsługiwane płyty” zwinięte.
- Winyl i kaseta: kolumny „Wejście” i „Nagranie”, pod nimi „Podział i eksport”.
  Miernik L/R (lub M dla wejścia mono) z prawdziwych szczytów na kanał,
  „Podgląd wyłączony” poza pomiarem, ostrzeżenie o przesterowaniu.
  Częstotliwość, format (tylko do odczytu) i folder w „Zaawansowanych”. Bez pauzy
  nagrania (silnik jej nie ma).
- Prawy panel ukryty domyślnie w ustawieniach, źródłach i imporcie.

## Wizualizator w pasku postępu
- PC: słupki z prawdziwego sygnału wyjścia (40 pasm, FFT 2048 z bufora renderera,
  liczone na żądanie, nie w wątku audio). Bez danych (pauza, DLNA, AirPlay, Android)
  statyczna linia postępu zamiast animacji.
- Bez kreski pośrodku i bez minimalnej wysokości słupków.
- Słupki 80% dawnej grubości, wygaszanie 38% końców każdej połowy i 10% szerokości na krańcach.
- Narastanie 30 ms, opadanie 380 ms, przejście pauza/odtwarzanie 200 ms, liczone od czasu.
- Parametry w `VisualizerStyle`. Reduced motion, tło i minimalizacja: brak animacji i odpytywania.

## Silnik (Rust)
- `GET /api/player/levels`, `ingest: folders`, nazwy napędów (IOCTL_STORAGE_QUERY_PROPERTY),
  „Brak płyty w napędzie”, wybór utworów przy imporcie CD, szczyty na kanał, liczba kanałów wejścia.
