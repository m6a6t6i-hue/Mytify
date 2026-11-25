# Mytify 0.4 — wykonane testy i granice potwierdzenia

Środowisko: Linux, Rust 1.100, Flutter 3.50.1 / Dart 3.14, Chrome Headless Shell. Audio: własne sygnały referencyjne, native Rust i jawny test output bez karty dźwiękowej. Windows EXE jest skompilowany, a rzeczywisty Windows/WASAPI nie został tutaj uruchomiony.

| Kontrola | Wynik |
| --- | --- |
| Rust: katalog/metadane/audio | 43/43 |
| Dart: domena/kolejka/kontroler audio | 16/16 |
| Interfejs + API | 22/22 |
| flutter analyze | bez uwag |
| Flutter Web release, lokalne zasoby | zbudowany |
| Windows x64 desktop + native WASAPI code | skompilowany |
| Pętla 180 s, 44,1 → 48 kHz, test output | zaliczona po optymalizacji DSP |
| Odsłuch, DAC/USB/Bluetooth, hardware gapless | otwarte |
| Bit-perfect / exclusive | nie są deklarowane ani dostarczone |

## Pomiary przed systemowym wyjściem

- WAV/FLAC 24-bit, 96 kHz: dekodowane próbki są zgodne ze sobą bez resamplingu.
- ALAC/M4A 16-bit: próbki są zgodne z wejściowym WAV PCM.
- Testowe MP3: liczba próbek po odcięciu encoder delay/paddingu odpowiada wejściowemu WAV.
- Granica WAV → FLAC przy 48 kHz: brak dodatkowych próbek/zer; złożony wynik odpowiada niesplitowanemu plikowi.
- Granica WAV → FLAC przy 44,1 → 48 kHz: współdzielony filtr sinc daje identyczny wynik jak konwersja niesplitowanego nagrania. To sprawdza historię i fazę na granicy, nie tylko długość plików.
- Zmiana źródła 48 → 44,1 kHz przy wyjściu 48 kHz: dokładna suma długości bez sztucznego bloku dopełniającego.
- SRC 96 → 48 kHz: zachowana składowa 1 kHz (~0,500000 amplitudy), testowa składowa 30 kHz nie pojawia się jako istotny alias 18 kHz; próg testu <0,0001 amplitudy, zmierzono około -158,9 dBFS dla tego jednego sygnału. Nie jest to pomiar DAC, szumu urządzenia ani całości charakterystyki filtra.
- Impulsy na początku, wewnątrz i na końcu oraz sygnał DC potwierdzają wyrównanie, prawidłową długość i zachowanie końcówki SRC.
- Instrumentacja alokatora w testowanym callbacku: 0 alokacji i 0 zwolnień sterty. Test obejmuje granicę plików i koniec kolejki.

Pomiary wykryły i usunęły błąd dodatkowego odcinania output_delay przy użytym SincFixedIn. Testy pierwszej/ostatniej próbki i impulsu zabezpieczają tę poprawkę.

## Przebieg czasowy

Pierwsza próba 180 s na całkowicie nieoptymalizowanym buildzie debug **nie przeszła**: 250 624 klatki niedoboru bufora. Nie traktujemy jej jako potwierdzenia jakości.

Dodano jawne optymalizacje dla kodu rdzenia i Rubato także w profilu dev/test (gorąca część audio w release ma optymalizację 3 i LTO). Powtórna próba 180 s: **8 401 408 wyrenderowanych klatek, 0 klatek niedoboru bufora**. Po rozgrzaniu RSS rdzenia: **14 123 008–14 229 504 bajty** (~13,47–13,57 MiB). Dane z próby: AUDIO_SOAK_0.4.json; narzędzie: tools/audio_soak.py.

Test clock nie jest zegarem urządzenia: jego planowanie zależy od środowiska i nie mierzy rzeczywistej częstotliwości DAC ani opóźnienia WASAPI. Potwierdza działanie rdzenia w pętli i ograniczoną pamięć w tej próbie. Nie zastępuje wielogodzinnego odsłuchu na Windows.

## Scenariusze funkcjonalne

43 testy Rust obejmują 26 kontroli poprzedniego katalogu/metadanych oraz 17 nowych kontroli audio: prawdziwe dekodery WAV/FLAC/MP3/AAC-LC/ALAC/Vorbis; próby PCM/SRC/granic; pause i odrzucanie starej epoki po seek; działanie kolejki bez pytań z UI; repeat/shuffle/stop; brakujący plik bez nieskończonej pętli; niedostępne urządzenie bez zmiany zapisanego wyboru; odtworzenie ustawień i ich zapis przy zamknięciu.

16 testów Dart: poprzednie 13 oraz spóźniona odpowiedź stanu nie cofająca nowego polecenia, serializacja poleceń po błędzie oraz zastąpienie opóźnionych wartości głośności końcową wartością suwaka.

22 scenariusze UI/API: ochrona API; migracja 0.1; import bez kopiowania i Unicode/duplikaty; Range/HEAD/okładki/FTS; realne dekodowanie przez Rust bez wywołania HTMLMediaElement.play; natywne seek/repeat/shuffle; pokazanie wybranego wyjścia/częstotliwości; wyszukiwanie; brakujące źródło; relink; zapomnienie wpisu; restart; ręczne opisy i własna okładka; rescan/FTS; reset; walidacja tytułu; podgląd/anulowanie; zatwierdzenie wydania z ochroną poprawek; jawny overwrite i układ 390 px; źródła 390 px; dalsze odtwarzanie po zamknięciu całego testowego Chrome; brak błędów przeglądarki i zewnętrznych żądań w kontrolowanym przebiegu.

Picker Windows i odpowiedzi MusicBrainz/CAA są kontrolowane w UI testach. Zapisy do katalogu, dekodowanie własnego PNG, audio Rust i render testowy są rzeczywiste. Zamykanie Chrome w teście headless nie oznacza, że muzyka ma grać po zamknięciu całej aplikacji Mytify — zamknięcie właściwego programu kończy odtwarzanie.

## Pierwszy test na Windows 11

Uruchom Mytify.exe po rozpakowaniu całej paczki, z WebView2Loader.dll obok. Otwórz album MP3/FLAC, sprawdź pauzę, przewijanie, next/previous i głośność. W ustawieniach zmień wyjście, odtwórz pauzę i pozycję; zamknij/otwórz program i sprawdź zapamiętanie wyjścia/głośności. Przetestuj wyjęcie USB DAC i ponowne wybranie urządzenia. Do oceny przejść użyj rzeczywistego albumu koncertowego i odsłuchu. Te punkty pozostają otwarte, podobnie jak kodeki spoza macierzy i wielogodzinna sesja.

Metadane online zachowują ograniczenie 0.3: wcześniejsza próba MusicBrainz z tego środowiska zwracała 403; żywy serwis nie jest w tym raporcie zaliczony jako działający na komputerze użytkownika.
