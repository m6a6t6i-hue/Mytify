# Mytify 0.3 — weryfikacja

Środowisko: Linux, Flutter 3.50.1 / Dart 3.14, Rust 1.100, Chrome Headless Shell. Własne sygnały audio 440 Hz i własny obraz testowy, bez dołączania cudzych nagrań lub okładek.

| Kontrola | Wynik |
| --- | --- |
| Rust: katalog, poprawki, migracja, protokół metadanych | 26/26 |
| Dart: model, kolejka i dopasowanie utworów | 13/13 |
| flutter analyze | bez uwag |
| Flutter Web release z lokalnymi zasobami | zbudowany |
| Rust Windows x64 desktop + embed-ui | skompilowany |
| Integracja UI/API | 19/19 |
| Start EXE i wyjście audio na prawdziwym Windows | otwarte |
| Żywy MusicBrainz / CAA | otwarte: próba MusicBrainz zwróciła 403 |

## Rust

14 testów regresji katalogu 0.2: import rzeczywistych MP3/FLAC/M4A/WAV, tagi Unicode, osadzona okładka, SHA-256 i wiele lokalizacji, szybki rescan, brakujące pliki, odłączony dysk, rename, zachowanie polubień, zapomnienie wpisu i źródła bez kasowania muzyki, przerwanie skanu, FTS, relink, migracja 0.1 i HTTP Range.

5 nowych testów integracji SQLite: poprawki zachowane po wymuszonym skanie i ponownym otwarciu, przywrócenie danych pliku, wyszukiwanie efektywnych opisów i niezmienione bajty muzyki; transakcyjne wycofanie błędnej grupy; walidacja numerów/tytułów/okładek i odrzucanie dowolnych ścieżek/URL; przeniesienie poprawek przy zmianie tożsamości pliku po zewnętrznej edycji; spójna kopia schematu 2 przed migracją do 3; usunięcie własnej okładki i przywrócenie osadzonej. Niektóre testy pokrywają kilka powiązanych warunków.

7 nowych testów klienta metadanych: wielopłytowe wydanie i złożone artist credits; cache i escapowanie zapytań; obsługa 503 bez zapisywania błędu do cache; walidacja MBID i odrzucanie przekierowań do obcych hostów; podniesienie przekierowania Archive.org do HTTPS, dekodowanie i lokalny zapis obrazu; opcjonalny brak okładki 404 i odrzucanie nieobrazów/przekroczonych limitów; nieprawidłowe odpowiedzi JSON. Używają kontrolowanego transportu, nie prawdziwego serwisu.

## Dart

10 testów modelu/kolejki z poprzedniej wersji oraz 3 nowe przypadki dopasowania utworów: prawidłowa para płyta+utwór niezależnie od indeksu, powtarzające się/brakujące numery, niepełny album i brak automatycznego dopasowania nieistniejącej pozycji. Nie jest to fingerprinting audio.

## UI i API

Test Playwright uruchamia rzeczywisty Rust, SQLite i zbudowany interfejs Flutter. Wybór ścieżek Windows oraz odpowiedzi wyszukiwania/wydania/okładki online są kontrolowane. Zapisy poprawek, reset, lokalne przesyłanie PNG, dekodowanie i serwowanie obrazu, FTS, odtwarzanie, import i migracja korzystają z prawdziwego rdzenia. Przebieg zakończył się 19/19 scenariuszami: ochrona API; migracja 0.1; import folderu bez kopiowania; oryginalne bajty audio/Range/HEAD/okładka/FTS; rzeczywisty start i pauza audio; wyszukiwanie bez polskich znaków; odłączone źródło; relink; zapomnienie wpisu bez kasowania pliku; restart backendu i profilu; ręczna edycja albumu z własną okładką; zachowanie poprawek przy force rescan i w FTS; przywrócenie danych pliku; walidacja i edycja tytułu; podgląd/anulowanie bez zmian; zatwierdzenie propozycji z ochroną własnych opisów i pominięciem niejednoznacznych pozycji; jawne zastąpienie poprawek i dialog przy 390 px; źródła przy 390 px; brak błędów przeglądarki i zewnętrznych żądań w tym kontrolowanym przebiegu.

## Granice weryfikacji

Próba bezpośredniego wyszukania Nevermind / Nirvana przez rzeczywisty klient zwróciła upstream HTTP 403 „Site Unavailable”; lokalne API poprawnie zgłosiło błąd. Nie potwierdzono dostępności MusicBrainz ani pobrania prawdziwej okładki CAA z komputera użytkownika. Testy kontrolowane nie są przedstawiane jako testy dostępności zewnętrznych usług.

Skompilowanie PE x64 nie dowodzi działania WebView2, systemowego pickera ani kodeków/sterownika na Windows. Nie testowano długiej sesji, bibliotek 100 tys.+, gapless, bit-perfect, WASAPI exclusive, Androida, Android Auto, Audio CD ani analogowego nagrywania. Źródła i raport pozwalają oddzielić dostarczony kod od otwartych testów sprzętowych.

## Pierwszy test użytkownika

Zamknij 0.2 i uruchom Mytify.exe z rozpakowanej paczki. Sprawdź zachowanie źródeł i polubień, zmień tytuł jednego utworu, wykonaj rescan i uruchom program ponownie. Użyj własnej okładki PNG/JPEG, a następnie przywróć dane z pliku. Dla znanego albumu spróbuj wyszukiwania MusicBrainz, przejrzyj wydanie, anuluj i sprawdź brak zmian; dopiero potem zapisz świadomie wybrane pola. Odsłuch oraz połączenie z serwisami wymagają tego rzeczywistego testu Windows.
