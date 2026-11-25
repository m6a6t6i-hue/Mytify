# Mytify 0.8.1 — pass UI

- Nowy system wizualny na Windows i Androidzie na podstawie dostarczonych referencji: czerń, soczysta zieleń, kontrastowa typografia, zaokrąglone karty, delikatne światło w tle.
- Ikona użytkownika: nagłówek, launcher Android (w tym adaptive icon), web favicon/manifest, zasób PE i ikona okna Windows. Zachowany kształt znaku.
- Duża karta odtwarzania na stronie głównej telefonu; na szerokim PC osobny panel z okładką i sterowaniem. Pełny odtwarzacz dostępny z paska.
- Przenikanie okładek, przejścia ekranów, play/pause, polubienia, reakcje kafelków na mysz i dotyk, animowana poświata i wskaźnik grania. Wskaźnik oznacza aktywność; nie udaje pomiaru dźwięku.
- Animacje dekoracyjne: pauza po zatrzymaniu muzyki, wyłączenie w tle i poza aktywnym TickerMode, tryb statyczny przy ograniczeniu animacji w systemie. Odrębne RepaintBoundary dla stale animowanych fragmentów.
- Wygaszane ekrany są wyłączone z odczytu dostępności, fokusu i dotyku. Przyciski play/pause obsługują klawiaturę i mają jawne działanie dostępności.
- Albumy: prawdziwe okładki, format pliku, zielone oznaczenie grającego albumu; istniejące grupowanie i poprawki metadanych zachowane.
- Prawdziwe playlisty Androida w sekcji głównej; pusty stan prowadzi do utworzenia pierwszej. Na PC nie dodano pozorowanej obsługi playlist.
- Zachowane import CD i analogu, katalog, sieciowe wyjścia audio i jedna sesja Android Auto. Interfejs Android Auto rysuje host samochodu; dekoracyjne animacje dotyczą telefonu/PC.
- APK 0.8.1 (10), ten sam identyfikator aplikacji i certyfikat. Bez migracji schematu bazy i bez ponownego importu muzyki.
