# Mytify 0.8.2 — weryfikacja poprawki

- Analiza Dart bez uwag.
- 42 testy Flutter: dotychczasowe regresje oraz cztery nowe próby układu.
- Cała karta (łącznie z play i suwakiem) mieści się między wyszukiwarką a nawigacją bez przewijania: 320×700 przy skali tekstu 1.0, 360×800 i 412×915 przy skali 1.3. Próby używają dłuższego tytułu i wykonawcy oraz danych formatu audio.
- Po przewinięciu kolekcji przycisk Start przywraca odtwarzacz na górze.
- Release APK ARM64, Android 8+, 0.8.2 (11), sprawdzony podpis aktualizacji i integralność archiwum.
- Weryfikacja wyglądu na uruchomionym wspólnym UI w rozmiarze mobilnym.

Nie zmieniano Kotlinowej usługi audio ani kodu Rust/DSP i protokołów sieciowych. Ich wyniki i ograniczenia pozostają opisane w TESTY_0.8.md oraz TESTY_0.8.1.md; nie raportujemy ponownego wykonania tych prób. Test fizycznego telefonu pozostaje po stronie instalacji aktualizacji.
