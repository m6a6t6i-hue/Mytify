# Mytify 0.12, 25.11.2026

## Ruch i reakcje (P5)
- Play/Pause z płynnym morphem ikony zamiast podmiany.
- Krótkie sprężyste ugięcie przycisków przy naciśnięciu; akcja nie czeka na animację.
- Wszystkie animacje respektują systemowe ograniczenie animacji.
- Lżejszy cień okienka wyboru urządzenia na PC.

## Tabela utworów na PC (P6)
- Kolumny do wyboru: Artysta, Album, Format, Bitrate, Dodano, Odtworzenia, Czas.
  Prawy przycisk na nagłówku lub ikona kolumn. Domyślnie Album i Czas.
- Szerokość kolumn zmieniana przeciąganiem separatora, zapamiętywana.
- Sortowanie po kliknięciu nagłówka (Tytuł, Artysta, Album, Czas, Dodano, Odtworzenia).
- Tryb kompaktowy: niższe wiersze bez okładek (menu kolumn lub Ustawienia > Wygląd).

## Wydajność
- Klucze sortowania liczone raz na wersję biblioteki, posortowane listy zapamiętywane
  między przebudowami (odtwarzanie nie wywołuje ponownego sortowania).
- Test 20 000 utworów (tryb debug na CI): indeks 311 ms, wyszukiwanie 9 ms,
  sortowanie 62 ms, tabela buduje tylko widoczne wiersze.
