# Mytify 0.19, 26.11.2026: mini odtwarzacz i wizualizacje

## Mini odtwarzacz (PC)
- Ctrl+M lub przycisk w pasku playera: okno zmienia się w pływający odtwarzacz bez ramki,
  zawsze na wierzchu (przypinka do wyłączenia).
- Dwa rozmiary: 244×82 (okładka, tytuł, wykonawca, poziomy, poprzedni, odtwarzaj, następny)
  i 196×44 (okładka, tytuł, odtwarzaj). Pasek postępu na dole, kliknięcie przewija.
- Przeciąganie za dowolne miejsce, dwuklik lub przycisk wraca do pełnej aplikacji
  w poprzednim położeniu i rozmiarze. Położenie mini odtwarzacza jest zapamiętywane.

## Wizualizacje na pełnym ekranie (PC i Android)
- Cztery sceny w jednym shaderze GPU: Plazma (linie warstwic), Wstęgi, Wir, Retro.
- Ruch z prawdziwych poziomów dźwięku: bas, środek, góra, energia i impuls na uderzeniach basu.
  Bez danych (DLNA, AirPlay) tylko powolny dryf i komunikat, pauza zatrzymuje obraz.
- PC: Ctrl+Shift+V lub przycisk w playerze, okno na pełny ekran; Esc, spacja, strzałki.
- Android: przycisk w ekranie odtwarzania, tryb immersyjny, ekran nie gaśnie,
  przesunięcie w bok zmienia scenę, dotknięcie pokazuje sterowanie.

## Android: prawdziwe poziomy dźwięku
- Kopia zdekodowanego dźwięku w drodze do głośnika (bez zmiany brzmienia), zsynchronizowana
  z pozycją głośnika. Pasek postępu na telefonie znowu ma equalizer z prawdziwego sygnału.
