# Mytify 0.5 — walidacja

## Wykonane

- `flutter analyze --no-pub`: bez uwag.
- `flutter test --no-pub`: 23 testy, wszystkie przechodzą.
- Kotlin/JUnit/Robolectric 4.16.1, Android API 35: 16 testów bez błędów i pominięć.
- Zbudowany zoptymalizowany APK release ARM64, pakiet pl.mytify.app,
  wersja 0.5.0 (5), minimum API 26, target API 35, compile API 36.
- Kontrola podpisu developerskiego, struktury ZIP/CRC, uprawnień manifestu
  i obecności bibliotek ARM64. Brak broad storage permission i cleartext HTTP.

Dart: 13 testów domeny biblioteki, 3 kontrolera odtwarzania,
4 adaptera Android oraz 3 mobilnego UI. Ekrany 320×700, 360×800 i 780×360:
import, brak migracji PC, mini odtwarzacz i pełny odtwarzacz bez overflow.
Pierwsza próba wykryła przycinanie podpisów albumów na wąskich ekranach;
wysokość kafelków została poprawiona i testy powtórzono z wynikiem pozytywnym.

Kotlin, 12 testów katalogu: hash i zachowanie oryginału, duplikaty wielu
lokalizacji, ponowny skan i trwałość polubień/poprawek, cofnięcie uprawnienia
i odzyskanie, ignorowanie zapomnianych plików, zmiana treści, anulowanie,
atomowość batcha, zapomnienie źródła bez kasowania muzyki, odrzucenie obcego ID,
nieprawidłowej okładki oraz brak jednego pliku bez wyłączenia pozostałych.
Użyto prawdziwego SQLite pod Robolectric, kontrolowanego ContentProvider,
własnych danych testowych i natywnego trybu grafiki do walidacji obrazów.

Kotlin, 4 testy usługi: pojedynczy odtwarzacz bez autoplay, zapisane volume,
nieprawidłowa zapisana kolejka oraz zachowanie bieżącego utworu/pozycji/repeat/
shuffle po pominięciu wcześniejszej brakującej pozycji. Ostatni przypadek
zabezpiecza poprawkę przywracania stanu, podczas którego listener mógł
nadpisać zapisane tryby przed ich odczytaniem.

Pierwsze konfiguracje testów natywnych wymagały korekt: AGP 9 domyślnie
nie tworzy release unit tests, więc włączono je jawnie. Usunięto również
błędną zależność testów od ApplicationProvider; używają RuntimeEnvironment.
Te nieudane uruchomienia nie są liczone jako testy pozytywne.

Dokładne nazwy przypadków i wyniki: TEST_RESULTS_0.5.json oraz pliki TEST-*.xml.

## Granice

Robolectric nie jest fizycznym telefonem ani emulatorem odtwarzającym audio.
Testy używają kontrolowanych providerów i cieni API Androida; nie potwierdzają
odczytu tagów każdego kodeka, reakcji prawdziwego systemowego pickera, jakości
DAC, fokusowania podczas połączenia ani zachowania One UI po wygaszeniu ekranu.
Nie wykonano testu audio na Windows ani S21 Ultra w tej iteracji.

Nie potwierdzono sprzętowo: wielogodzinnej sesji, przerw/gapless, bit-perfect,
24-bitowego wyjścia, USB/Bluetooth, powiadomień i sterowania ze słuchawek.
Włączenie float output w Media3 jest konfiguracją, nie wynikiem pomiaru.
Żywy MusicBrainz/CAA z telefonu wymaga testu; przypadki Kotlin nie weryfikują
zewnętrznych serwisów. Android Auto, CD i nagrywanie analogowe nie są dostarczone.

## Próba na S21 Ultra

1. Dodaj mały folder z własnymi MP3 i FLAC, również album z osadzoną okładką.
2. Zamknij i otwórz aplikację: katalog i polubienia powinny pozostać.
3. Uruchom album, zablokuj ekran na kilka minut i sprawdź przyciski systemowe.
4. Sprawdź połączenie telefoniczne, słuchawki i odłączenie Bluetooth.
5. Przesuń lub usuń jeden plik, wykonaj skan i sprawdź pozostałe utwory.
6. Uruchom telefon ponownie: sprawdź dostęp do wybranego folderu.
7. Sprawdź ręczne opisy oraz opcjonalne wyszukanie wydania/okładki online.

Problemy z tych prób mają pierwszeństwo przed iteracją 0.6 (Android Auto).
