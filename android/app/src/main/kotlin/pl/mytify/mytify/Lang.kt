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
