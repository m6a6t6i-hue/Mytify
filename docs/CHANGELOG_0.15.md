# Mytify 0.15, 25.11.2026: źródła sieciowe, etap A (SMB)

## Wspólny model źródeł
- Każde źródło opisuje protokół, adres bez danych logowania i swoje możliwości
  (przeglądanie, skanowanie, tagi, okładki, odtwarzanie, przewijanie).
- Tożsamość utworu bez zmian: suma SHA-256 zawartości. Ten sam plik z NAS-a i z dysku
  to jeden utwór z kilkoma lokalizacjami. Odtwarzanie wybiera najpierw kopię lokalną.
- Niedostępny NAS nie usuwa kolekcji: utwory, polubienia i playlisty zostają, źródło ma
  stan „Źródło niedostępne”. Stan sprawdzany w tle, interfejs nie czeka na serwer.
- Migracje katalogu tylko dodają tabele i kolumny. PC zapisuje kopię katalogu przed migracją.

## SMB 2/3
- PC: wbudowany klient SMB Windows, bez litery dysku. Hasło w Menedżerze poświadczeń Windows.
- Android: biblioteka smbj (tylko SMB 2/3). Hasło szyfrowane kluczem z Android Keystore.
- Test połączenia, wybór folderu, rekurencyjne skanowanie, tagi i okładki.
- Odtwarzanie z odczytem fragmentów pliku (przewijanie bez pobierania całości),
  ponowne logowanie po zerwanej sesji.
- Ponowny skan pomija pliki o niezmienionym rozmiarze i dacie.
- Android Auto: utwór z niedostępnego NAS-a zgłasza błąd od razu, bez kręcącego się kółka.
  Stan NAS-a odświeża się przy zmianie sieci.

## Interfejs
- Plus w Bibliotece i w Ustawieniach: „Dodaj źródło” (muzyka na urządzeniu, pliki,
  folder sieciowy SMB). Pokazywane są tylko działające rodzaje źródeł.
- Formularz połączenia z testem, wyborem folderu, edycją i czytelnymi komunikatami błędów.

## Testy (CI, prawdziwe serwery)
- Windows: lokalny udział SMB z kontem testowym. Złe hasło, test, przeglądanie folderu
  z polskimi znakami, skan, brak duplikatu z kopią lokalną, odtwarzanie, ponowne połączenie.
- Android: serwer Samba (SMB2+). Złe hasło, test, skan, ponowny skan bez czytania plików,
  odczyt od dowolnego miejsca (przewijanie), ponowne logowanie, stan offline i powrót.

## Jeszcze nie w tej wersji
- WebDAV (etap B), OpenSubsonic/Navidrome (etap C), pobieranie offline i zarządzanie
  pobraniami (etap D).
