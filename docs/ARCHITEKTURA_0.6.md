# Android Auto 0.6

PlaybackService zachowuje nazwę komponentu i jednego ExoPlayera, ale dziedziczy
po MediaLibraryService. MediaLibrarySession udostępnia także legacy
android.media.browse.MediaBrowserService; manifest deklaruje media Android Auto.
Nie renderujemy Fluttera na ekranie samochodu. UI zapewnia host Android Auto.

Root jest natychmiastowy i nie odczytuje bazy — legacy browser może blokować
wątek główny. Pozostałe callbacki SQL/rozwiązywania ID działają w executorze.
Drzewo: Albumy, Playlisty, Polubione, Utwory. Ostatnio dodane jest kolekcją
w sekcji Playlisty. Więcej niż 100 dzieci tworzy foldery zakresów; stronicowanie
używa Long, by uniknąć overflow dla legacy pageSize = Int.MAX_VALUE.

Przeglądany utwór ma ID zawierające hash i zakodowany kontekst. onSetMediaItems
rozwija album/playlistę/kolekcję i zachowuje wybrany indeks. Faktyczne ID kolejki
to te same SHA-256, których używa telefon. Wszystkie URI przychodzące od
kontrolera są odrzucane jako źródło danych; URI odtwarzania pochodzi z katalogu.
Wyszukiwanie: normalizacja polskich znaków, przecięcie słów, limit 200 wyników.
Kolejka samochodowa ma okno do 10 000 wpisów zawierające wybrany utwór.

Uprawnione kontrolery: UID aplikacji, kontrolery zaufane przez Android oraz
pakiet Android Auto potwierdzony dla UID przez PackageManager. onConnectAsync
jawnie nadaje komendy biblioteki i odtwarzania również Android Auto.

Okładki używają FileProvider o ścieżce ograniczonej do files/covers/. Zaufany
host otrzymuje prawo odczytu tego prefiksu; pliki audio i baza nie są udostępnione.
Dzięki temu host może odczytać okładkę również przy odtwarzaniu z wyszukiwania.

Schemat Android SQLite 1 → 2: playlists oraz playlist_tracks. Zapisy playlist
są transakcyjne. Kolejność jest jawna, brak duplikatów w playliście, edycja nie
modyfikuje plików audio. Powiadomienia childrenChanged odświeżają root i kategorie
po imporcie, skanie, polubieniu, opisie, zapomnieniu lub zmianie playlisty.

APK zachowuje applicationId i testowy klucz 0.5, co umożliwia aktualizację.
Wydanie nie jest publikowane ani zatwierdzone w Google Play.

Źródła:
- https://developer.android.com/media/media3/session/serve-content
- https://developer.android.com/media/implement/surfaces/cars
- https://developer.android.com/training/cars/testing
