# Mytify 0.17, 25.11.2026: źródła sieciowe, etapy C i D

## OpenSubsonic / Navidrome (PC i Android)
- Adres, użytkownik, hasło, test połączenia z nazwą i wersją serwera oraz wykryciem OpenSubsonic.
- Biblioteka z indeksu serwera (search3, a gdy serwer go nie obsługuje: album po albumie),
  bez ponownego skanowania folderów. Ponowne odświeżenie czyta tylko indeks.
- Okładki pobierane raz na okładkę serwera.
- Odtwarzanie oryginalnego pliku z przewijaniem (HTTP Range).
- Android: opcjonalna konwersja osobno dla Wi-Fi i sieci komórkowej
  (MP3 192 kb/s), domyślnie wyłączona. PC zawsze odtwarza oryginał.
- Polubione: lokalna zmiana trafia na serwer od razu albo po odzyskaniu połączenia.
  Stan z serwera wygrywa tylko wtedy, gdy nic nie czeka na wysłanie.
- Odtworzenia zgłaszane serwerowi (scrobble), także te z czasu bez połączenia.
- Playlisty: playlisty serwera pojawiają się w Mytify, lokalne zmiany wracają na serwer.
  Gdy obie strony coś zmieniły, nic nie jest nadpisywane: wersja z serwera przychodzi
  jako kopia „(z serwera)”. Playlista usunięta lokalnie nie wraca.
- MP3 i inne formaty stratne nie mają głębi bitowej PCM.

## Pobieranie offline (PC i Android)
- „Pobierz offline” dla utworu, albumu i playlisty; przed startem liczba utworów,
  rozmiar i wolne miejsce. „Utrzymuj offline” dla playlisty: nowe pozycje pobierają się
  same po edycji, synchronizacji i odzyskaniu sieci.
- Kolejka, postęp, pauza, anulowanie, ponawianie po przerwanym połączeniu,
  kontynuacja po ponownym uruchomieniu aplikacji.
- Częściowy plik nigdy nie jest odtwarzany. Plik częściowy innej wersji pliku źródłowego
  nie jest doklejany, pobieranie zaczyna się od nowa.
- Weryfikacja: utwory z SMB po sumie SHA-256 zawartości, z WebDAV i serwerów muzycznych
  po rozmiarze. Zapis przez plik tymczasowy, synchronizację z dyskiem i zmianę nazwy.
- Sprawdzanie miejsca przed i w trakcie zapisu, czytelny komunikat o braku miejsca.
- Pobranie to kolejna lokalizacja tego samego utworu: bez duplikatów utworów i albumów.
  Jeden plik w kilku playlistach zajmuje miejsce raz.
- „Usuń pobranie” usuwa tylko kopię lokalną: plik na NAS-ie, polubienie i playlisty zostają.
- Pliki w folderze danych aplikacji (nie w folderze tymczasowym).
- Android: pobieranie w usłudze pierwszoplanowej z powiadomieniem i przyciskiem pauzy,
  domyślnie tylko Wi-Fi, przełącznik „Pobieraj przez sieć komórkową”.
- Biblioteka: filtr „Pobrane”. Ustawienia: „Pobrane i miejsce” (kolejka, zajęte i wolne miejsce).

## Testy (CI, prawdziwe serwery)
- Navidrome 0.58 na Windows i Linux: złe hasło, opis serwera, import biblioteki,
  ponowne odświeżenie, odtwarzanie od dowolnego miejsca, polubione w obie strony,
  oczekująca zmiana nienadpisana, scrobble, playlisty: import, wysłanie zmiany, konflikt.
- Pobieranie z HTTPS WebDAV (PC i Android) i Samby (Android): brak drugiego utworu,
  weryfikacja, odtwarzanie przy niedostępnym serwerze, usunięcie pobrania,
  odrzucenie pliku częściowego innej wersji, playlista utrzymywana offline.
