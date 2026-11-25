# Mytify 0.9 — 25.11.2026

- PC: jawnie włączany serwer TLS w LAN, jednorazowy QR, wybór adresu sieciowego,
  lista sparowanych telefonów, cofanie dostępu i zatrzymywanie udostępniania.
- Android: skanowanie QR lub wklejenie kodu, wybór albumów i playlist z PC,
  sprawdzanie miejsca, pobieranie w tle z postępem i możliwością wstrzymania.
- Trwały zapis kolejki i wznowienie plików przez HTTP Range; kontrola rozmiaru
  i SHA-256 przed dodaniem do biblioteki. Bez konwersji muzyki.
- Pliki prywatne offline i ich bezpieczne usuwanie; usuwanie niedokończonego
  pobrania zachowuje ukończone pliki. Rejestr własności niezależny od metadanych.
- Zmiany biblioteki są przekazywane do interfejsu i usługi odtwarzania.
- Polecenie systemowe MEDIA_PLAY_FROM_SEARCH trafia do wspólnej sesji Media3;
  naprawione deklaracje API wykryte przez pełny lint Androida.
- Playlisty PC zapisują się trwale i można pobrać je razem z utworami.
  Kopia istniejącej playlisty na telefonie nie jest nadpisywana.
- Metadane/okładki PC z ochroną zmian i polubień istniejących utworów telefonu.
- Zachowane: poprawione grupowanie albumów, UI 0.8.1, układ mobilny 0.8.2,
  odtwarzanie lokalne, Android Auto, odbiorniki sieciowe i import nośników.

Nie dodano synchronizacji dwukierunkowej ani transkodowania transferów.
Nie zmieniano natywnego nadajnika AirPlay; DLL Windows zachowana z 0.8.1.
