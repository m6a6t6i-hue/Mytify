# Mytify 0.11, 25.11.2026

## Poprawki
- Windows: parowanie i transfer PC→telefon nie działały. Gniazda przyjęte z nieblokującego
  nasłuchu dziedziczą na Windows tryb nieblokujący, pierwszy odczyt TLS kończył się
  `WouldBlock`, a telefon dostawał `os error 10053`. Testy TLS przechodzą teraz na Windows.
- Android: tło z koloru okładki nie działało dla okładek `file:`.
- Okładki `data:` mają stały klucz cache (pełnoekranowy odtwarzacz nie pokazuje pustego pola).
- Test katalogu porównuje kanoniczne ścieżki (Windows `\\?\`). Pełny `cargo test` gatuje build Windows.

## Wybór urządzenia (P4)
- Telefon: bottom sheet. PC: popover nad paskiem odtwarzania.
- Aktualne i dostępne urządzenia, ikona rodzaju, status (Łączenie, Połączono, Odtwarza,
  Wymaga PIN, Niedostępne), głośność z wyciszeniem, odświeżanie, PIN AirPlay inline,
  włączanie amplitunera Yamaha.
- Nazwy silników, protokołów i diagnostyka przeniesione do Ustawienia > Dźwięk > Diagnostyka.

## Teksty
- Krótsze komunikaty na ekranach transferu, importu CD i winyli oraz metadanych.
- Poprawna odmiana liczebników. Bez długich myślników w całej aplikacji, także w Android Auto.
