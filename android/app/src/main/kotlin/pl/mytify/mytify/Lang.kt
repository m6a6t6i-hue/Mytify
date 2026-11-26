package pl.mytify.mytify

import android.content.Context

/** Language of texts Android shows itself (Android Auto, notification, widget). */
object Lang {
    @Volatile var code = "pl"
        private set

    fun load(context: Context) {
        code = context.getSharedPreferences("ui", 0).getString("lang", "pl") ?: "pl"
    }

    fun set(context: Context, value: String) {
        code = if (value == "en") "en" else "pl"
        context.getSharedPreferences("ui", 0).edit().putString("lang", code).apply()
    }

    private val en =
        mapOf(
            "Albumy" to "Albums",
            "Radio" to "Radio",
            "Serwer z muzyką nie odpowiada. Sprawdź, czy NAS jest włączony i w tej samej sieci." to "The music server is not responding. Check that the NAS is on and in the same network.",
            "Ulubione stacje" to "Favourite stations",
            "Ostatnio słuchane" to "Recently played",
            "Popularne w Polsce" to "Popular in Poland",
            "Popularne stacje" to "Popular stations",
            "Klasyka" to "Classical",
            "Elektronika" to "Electronic",
            "Wiadomości" to "News",
            "Rozmowy" to "Talk",
            "Stacja jest niedostępna" to "The station is unavailable",
            "Nieprawidłowa stacja." to "Invalid station.",
            "Katalog stacji radiowych nie odpowiada. Sprawdź internet" to "The radio directory is not responding. Check your internet connection",
            "Adres stacji musi zaczynać się od http:// lub https://" to "The station address must start with http:// or https://",
            "Stacja odpowiedziała błędem HTTP {0}." to "The station answered with HTTP error {0}.",
            "Lista stacji nie zawiera adresu strumienia." to "The playlist contains no stream address.",
            "Za dużo przekierowań list stacji." to "Too many nested playlists.",
            "Pod tym adresem jest strona internetowa, a nie strumień radia." to "This address is a web page, not a radio stream.",
            "Nie można odtworzyć stacji ({0}). Sprawdź internet lub wybierz inną stację." to "Cannot play the station ({0}). Check your internet connection or pick another station.",
            "Playlisty" to "Playlists",
            "Polubione" to "Liked",
            "Utwory" to "Tracks",
            "Ostatnio dodane" to "Recently added",
            "Brak wyników" to "No results",
            "Album niedostępny" to "Album unavailable",
            "Plik jest niedostępny" to "The file is unavailable",
            "Usuń z polubionych" to "Remove from liked",
            "Polub" to "Like",
            "Wyłącz losową kolejność" to "Turn off shuffle",
            "Losowa kolejność" to "Shuffle",
            "Nic nie gra. Dotknij, aby otworzyć." to "Nothing is playing. Tap to open.",
            "Pauza" to "Pause",
            "Odtwarzaj" to "Play",
            "Kopiowanie muzyki" to "Copying music",
            "Mytify · Pobieranie na telefon" to "Mytify · Downloading to the phone",
            "Wstrzymaj" to "Pause",
        )

    fun t(pl: String): String = if (code == "en") en[pl] ?: pl else pl
}
