package pl.mytify.mytify

import java.util.concurrent.ConcurrentHashMap
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

/**
 * "Buy music": prices from the iTunes Search API, the only store with a public price
 * lookup. Other stores are offered by the app as search links, without prices.
 */
object Shop {
    private val cache = ConcurrentHashMap<String, Pair<Long, JSONArray>>()

    private fun storeUrl(u: String) = u.startsWith("https://music.apple.com/") || u.startsWith("https://itunes.apple.com/")

    fun offers(v: JSONObject): List<JSONObject> {
        val a = v.optJSONArray("results") ?: return emptyList()
        return (0 until a.length()).mapNotNull { i ->
            val r = a.optJSONObject(i) ?: return@mapNotNull null
            val album = r.optString("wrapperType") == "collection"
            val song = r.optString("wrapperType") == "track" && r.optString("kind") == "song"
            if (!album && !song) return@mapNotNull null
            val url = r.optString(if (album) "collectionViewUrl" else "trackViewUrl")
            if (!storeUrl(url)) return@mapNotNull null
            val price = r.optDouble(if (album) "collectionPrice" else "trackPrice", -1.0)
            JSONObject()
                .put("store", "iTunes Store")
                .put("kind", if (album) "album" else "song")
                .put("title", r.optString(if (album) "collectionName" else "trackName"))
                .put("artist", r.optString("artistName"))
                .put("price", if (price > 0) price else JSONObject.NULL)
                .put("currency", r.optString("currency"))
                .put("tracks", r.optInt("trackCount"))
                .put("year", r.optString("releaseDate").take(4))
                .put("url", url)
        }
    }

    /** Network thread. Answers are kept for ten minutes (Apple allows about 20 lookups a minute). */
    fun search(query: String, country: String): JSONArray {
        val q = query.trim().take(100)
        if (q.length < 2) return JSONArray()
        val c = country.takeIf { it.length == 2 && it.all(Char::isLetter) }?.uppercase() ?: "PL"
        val key = "$c|${q.lowercase()}"
        cache[key]?.takeIf { System.currentTimeMillis() - it.first < 600_000 }?.let { return it.second }
        val all = JSONArray()
        for ((entity, limit) in listOf("album" to "8", "song" to "5")) {
            val url =
                "https://itunes.apple.com/search".toHttpUrl().newBuilder()
                    .addQueryParameter("term", q)
                    .addQueryParameter("country", c)
                    .addQueryParameter("media", "music")
                    .addQueryParameter("entity", entity)
                    .addQueryParameter("limit", limit)
                    .build()
            Radio.client.newCall(Request.Builder().url(url).build()).execute().use { r ->
                if (!r.isSuccessful) throw java.io.IOException(Lang.t("Sklep odpowiedział błędem HTTP {0}.").replace("{0}", "${r.code}"))
                offers(JSONObject(r.body?.string() ?: "{}")).forEach { all.put(it) }
            }
        }
        if (cache.size > 200) cache.clear()
        cache[key] = System.currentTimeMillis() to all
        return all
    }
}
