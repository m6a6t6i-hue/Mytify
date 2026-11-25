# Mytify 0.6 — zakres walidacji

Wynik: 26 testów Flutter i 34 Kotlin/Robolectric, bez błędów i pominięć.
Analiza Flutter bez uwag.

Wyniki końcowe oraz dokładne nazwy przypadków zapisano w TEST_RESULTS_0.6.json
i raportach XML. Kompilacja release ARM64, analiza Flutter, testy Flutter oraz
Kotlin/JUnit/Robolectric są wykonywane przed spakowaniem wydania.

Nowe testy obejmują root i biblioteki bez Activity, kontekst albumu i playlisty,
porządek dysków/utworów, brakujące pliki, wyszukiwanie polskich nazw,
stronicowanie i zakresy dużych kolekcji, odrzucenie obcych URI, CRUD playlist,
atomowość zmian, migrację bazy 0.5 → 0.6 i ścieżki FileProvider okładek.

Integracja Media3 jest sprawdzana rzeczywistym obiektem MediaBrowser połączonym
z tokenem sesji pod Robolectric: pobranie root/dzieci, ustawienie utworu,
rozwinięcie playlisty w pojedynczej kolejce i sterowanie tą samą instancją
odtwarzacza. To test protokołu i stanu; nie oznacza renderowania Android Auto.

Zachowano regresję katalogu i odtwarzania 0.5 oraz testy mobilnego UI.
Sprawdzany jest też zgodny certyfikat APK, umożliwiający aktualizację 0.5
bez odinstalowania i utraty katalogu.

## Otwarte kryteria sprzętowe

Nie wykonano testu DHU z podłączonym telefonem, rzeczywistego Android Auto,
samochodu ani dźwięku na S21 Ultra. Środowisko nie ma podłączonego telefonu.
Robolectric nie zastępuje tych prób ani certyfikacji Google Play.
Nie potwierdzono sprzętowo USB/Bluetooth, focus podczas połączeń, wielogodzinnej
sesji, gapless, bit-perfect, wszystkich kodeków ani komend głosowych asystenta.
Muzyka lokalna działa bez pobierania opisów; pliki chmurowe mogą wymagać sieci.
Żywe MusicBrainz/CAA pozostają do sprawdzenia z telefonu.

## Próba użytkownika

1. Zainstaluj APK jako aktualizację 0.5; zachowaj aplikację i jej dane.
2. Dodaj kilka własnych albumów, polub utwór i utwórz playlistę na ekranie Start.
3. Włącz „Nieznane źródła” w ustawieniach deweloperskich Android Auto,
   zgodnie z instrukcją README (dotyczy testowego APK spoza Google Play).
4. Połącz telefon ze zgodnym hostem i wybierz Mytify. Sprawdź cztery kategorie,
   okładki, wybór środkowego utworu, następny/poprzedni, pauzę i przewijanie.
5. Zmień utwór z telefonu i z auta; obie strony powinny wskazywać tę samą kolejkę.
6. Sprawdź dostęp po restarcie telefonu i przy wygaszonym ekranie oraz lokalne
   pliki bez Internetu. Sprawdź wyszukiwanie udostępniane przez hosta.
7. Edytuj playlistę na telefonie i sprawdź odświeżenie jej zawartości w aucie.

Pierwsza kompilacja wymagała doprecyzowania generycznego typu future w Kotlin;
nieudana próba nie jest zaliczana do pozytywnych testów.
