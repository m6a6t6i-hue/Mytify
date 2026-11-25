package pl.mytify.mytify

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder

class OnlineMetadata(context: Context,private val catalog: Catalog) {
    private val cache=File(context.cacheDir,"metadata").apply { mkdirs() }
    companion object { private var lastRequest=0L }
    private fun validId(id: String) { require(id.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"))) }
    private fun get(url: String,limit: Int=2*1024*1024): ByteArray {
        var current=URI(url);repeat(6) {
            if(current.scheme=="http") current=URI("https"+current.toString().removePrefix("http"))
            val host=current.host?:error("Nieprawidłowy adres");require(current.scheme=="https" && (host=="musicbrainz.org" || host=="coverartarchive.org" || host=="archive.org" || host.endsWith(".archive.org")))
            if(host=="musicbrainz.org") synchronized(OnlineMetadata::class.java) { val wait=1100-(SystemClock.elapsedRealtime()-lastRequest);if(wait>0) Thread.sleep(wait);lastRequest=SystemClock.elapsedRealtime() }
            val c=current.toURL().openConnection() as HttpURLConnection;try {
                c.instanceFollowRedirects=false;c.connectTimeout=15000;c.readTimeout=20000;c.setRequestProperty("User-Agent","Mytify/0.6 (personal local music library)");c.setRequestProperty("Accept","application/json, image/*")
                val code=c.responseCode;if(code in 300..399) { current=current.resolve(c.getHeaderField("Location")?:error("Brak przekierowania"));return@repeat }
                if(code==404) error("Brak danych lub okładki tego wydania");check(code==200) { "Serwis zwrócił HTTP $code. Spróbuj ponownie później." };require(c.contentLengthLong<=limit) { "Odpowiedź jest za duża" };return c.inputStream.use { readLimited(it,limit) }
            } finally { c.disconnect() }
        };error("Zbyt wiele przekierowań")
    }
    private fun json(url: String,ttl: Long): JSONObject {
        val f=File(cache,sha(url.toByteArray())+".json");if(f.isFile && System.currentTimeMillis()-f.lastModified()<ttl) return JSONObject(f.readText())
        val data=get(url).toString(Charsets.UTF_8);val parsed=JSONObject(data);val tmp=File(cache,f.name+".tmp");tmp.writeText(data);check(tmp.renameTo(f));return parsed
    }
    private fun artist(j: JSONObject): String { val a=j.optJSONArray("artist-credit")?:return "";return (0 until a.length()).joinToString("") { i->val c=a.getJSONObject(i);c.optString("name",c.optJSONObject("artist")?.optString("name")?:"")+c.optString("joinphrase") } }
    private fun candidate(j: JSONObject): JSONObject {
        val media=j.optJSONArray("media")?:JSONArray();var count=j.optInt("track-count");if(count==0) for(i in 0 until media.length()) count+=media.getJSONObject(i).optInt("track-count")
        val labels=j.optJSONArray("label-info");val label=if(labels!=null && labels.length()>0) labels.getJSONObject(0).optJSONObject("label")?.optString("name")?:"" else ""
        return obj("id" to j.getString("id"),"title" to j.optString("title"),"artist" to artist(j),"date" to j.optString("date"),"country" to j.optString("country"),"format" to if(media.length()>0) media.getJSONObject(0).optString("format") else "","label" to label,"barcode" to j.optString("barcode"),"disambiguation" to j.optString("disambiguation"),"trackCount" to count,"score" to j.optInt("score"))
    }
    fun search(album: String,artist: String): JSONArray {
        require(album.trim().isNotEmpty() || artist.trim().isNotEmpty());require(album.length+artist.length<1024)
        fun quoted(s: String)="\""+s.replace("\\","\\\\").replace("\"","\\\"")+"\""
        val q=listOf(if(album.isBlank()) "" else "release:"+quoted(album.trim()),if(artist.isBlank()) "" else "artist:"+quoted(artist.trim())).filter { it.isNotEmpty() }.joinToString(" AND ")
        val data=json("https://musicbrainz.org/ws/2/release/?fmt=json&limit=20&query="+URLEncoder.encode(q,"UTF-8"),86400000);val releases=data.optJSONArray("releases")?:JSONArray();return JSONArray((0 until releases.length()).map { candidate(releases.getJSONObject(it)) })
    }
    fun details(id: String): JSONObject {
        validId(id);val data=json("https://musicbrainz.org/ws/2/release/$id?fmt=json&inc=artists+recordings+labels",7*86400000L);val songs=JSONArray();val media=data.optJSONArray("media")?:JSONArray()
        for(i in 0 until media.length()) { val disc=media.getJSONObject(i);val tracks=disc.optJSONArray("tracks")?:JSONArray();for(k in 0 until tracks.length()) {
            val t=tracks.getJSONObject(k);val r=t.optJSONObject("recording");songs.put(obj("title" to t.optString("title",r?.optString("title")?:""),"artist" to artist(t).ifEmpty { r?.let { artist(it) }?:artist(data) },"discNumber" to disc.optInt("position",i+1),"trackNumber" to t.optInt("position",k+1),"durationMs" to t.optInt("length",r?.optInt("length")?:0)))
        } };return obj("release" to candidate(data),"tracks" to songs)
    }
    fun cover(id: String): JSONObject {
        validId(id);val images=json("https://coverartarchive.org/release/$id",7*86400000L).optJSONArray("images")?:return JSONObject()
        for(i in 0 until images.length()) { val image=images.getJSONObject(i);if(image.optBoolean("front")) { val url=image.optJSONObject("thumbnails")?.optString("large")?.takeIf { it.isNotEmpty() }?:image.optString("image");return catalog.storeCover(get(url,8*1024*1024)) } };return JSONObject()
    }
}
