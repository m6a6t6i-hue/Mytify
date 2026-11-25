# Mytify 0.16, 25.11.2026: źródła sieciowe, etap B (WebDAV)

## WebDAV przez HTTPS (PC i Android)
- Adres serwera, login, wybór folderu, test połączenia, edycja i usuwanie źródła.
- Tylko HTTPS. Certyfikaty zawsze sprawdzane systemowym magazynem zaufania; serwer
  z niezaufanym certyfikatem dostaje czytelny komunikat, nic nie jest wyłączane.
- Przekierowania tylko w obrębie tego samego serwera: login nie trafia do innego hosta.
- Polskie znaki, spacje i kodowanie ścieżek zgodnie z odpowiedzią serwera.
- Skanowanie folder po folderze (PROPFIND Depth 1), tagi i okładki z fragmentów pliku
  (HTTP Range). Zmiana pliku wykrywana po ETag (lub dacie) i rozmiarze.
- Odtwarzanie i przewijanie przez Range. Serwer bez Range: plik pobierany raz do
  pamięci podręcznej (wolniejszy start, potem normalne przewijanie).
- Utwory z WebDAV mają stały identyfikator z adresu na serwerze (pełne liczenie sumy
  przez internet byłoby za drogie). Nie są łączone z kopiami z innych źródeł.

## Testy (CI, prawdziwe serwery HTTPS)
- PC (Windows, Menedżer poświadczeń) i Android: złe hasło, niezaufany certyfikat, foldery
  z polskimi znakami, skan, ponowny skan bez czytania plików, odczyt od dowolnego miejsca,
  serwer bez Range, stan offline i powrót.
