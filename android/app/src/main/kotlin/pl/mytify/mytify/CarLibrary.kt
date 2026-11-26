package pl.mytify.mytify

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import androidx.core.content.FileProvider
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import org.json.JSONObject
import java.io.File
import java.text.Normalizer

/** Immutable content snapshot; all reads and ID resolution run on the library worker. */
@UnstableApi
class CarLibrary(private val context: Context,private val catalog: Catalog) {
    data class Song(val json: JSONObject) {
        val id=json.getString("id");val title=json.optString("title");val artist=json.optString("artist")
        val album=json.optString("album");val albumArtist=json.optString("albumArtist").ifBlank { artist }
        val liked=json.optBoolean("liked");val available=json.optBoolean("available")
        val albumId=if(albumGroupingPart(album).isEmpty()) "album:file:$id" else "album:"+sha(org.json.JSONArray(listOf(albumGroupingPart(album),albumGroupingPart(albumArtist))).toString().toByteArray())
    }
    companion object {
        fun albumGroupingPart(text: String)=text.replace(Regex("[\\s\\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]+")," ").trim().lowercase(java.util.Locale.ROOT)

        const val ROOT="root";val ROOT_IDS=listOf("albums","playlists","liked","all","radio")
        val GENRES=listOf("pop","rock","jazz","classical","electronic","dance","hip hop","news","talk","chillout")
        fun genreName(tag: String)=Lang.t(when(tag) { "pop"->"Pop";"rock"->"Rock";"jazz"->"Jazz";"classical"->"Klasyka";"electronic"->"Elektronika";"dance"->"Dance";"hip hop"->"Hip-hop";"news"->"Wiadomości";"talk"->"Rozmowy";"chillout"->"Chillout";else->tag })
        fun folder(id: String,title: String,subtitle: String="")=MediaItem.Builder().setMediaId(id).setMediaMetadata(MediaMetadata.Builder().setTitle(title).setSubtitle(subtitle).setIsBrowsable(true).setIsPlayable(false).setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED).build()).build()
        fun normalized(s: String)=Normalizer.normalize(s.lowercase().replace('ł','l'),Normalizer.Form.NFD).replace(Regex("\\p{M}+"),"")
        private fun encode(s: String)=Base64.encodeToString(s.toByteArray(),Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        private fun decode(s: String)=String(Base64.decode(s,Base64.URL_SAFE or Base64.NO_WRAP))
        fun trackId(id: String,parent: String)="song:$id:"+encode(parent)
        fun canonical(id: String): String {
            val hash=if(id.startsWith("song:")) id.substringAfter("song:").substringBefore(':') else id
            require(hash.matches(Regex("[a-f0-9]{64}"))) { "Nieprawidłowy identyfikator utworu" };return hash
        }
        fun parent(id: String): String?=if(id.startsWith("song:")) decode(id.substringAfter("song:").substringAfter(':')) else null
        fun <T> page(items: List<T>,page: Int,size: Int): List<T> {
            require(page>=0 && size>0);val start=page.toLong()*size.toLong();if(start>=items.size) return emptyList()
            return items.subList(start.toInt(),minOf(items.size.toLong(),start+size.toLong()).toInt())
        }
    }
    private fun songs(): List<Song> { val a=catalog.load(includeCover=false);return (0 until a.length()).map { Song(a.getJSONObject(it)) } }
    private val order=compareBy<Song>({ it.json.optInt("discNumber") },{ it.json.optInt("trackNumber") },{ normalized(it.title) },{ it.id })
    fun collection(parent: String,all: List<Song> = songs()): List<Song> {
        val available=all.filter { it.available }
        return when {
            parent=="all" ->available.sortedWith(compareBy({ normalized(it.artist) },{ normalized(it.title) },{ it.id }))
            parent=="liked" ->available.filter { it.liked }.sortedBy { normalized(it.title) }
            parent=="recent" ->available.sortedByDescending { it.json.optLong("addedAt") }.take(100)
            parent.startsWith("album:") ->available.filter { it.albumId==parent }.sortedWith(order)
            parent.startsWith("playlist:") -> { val byId=available.associateBy { it.id };PlaylistStore(catalog).ids(parent.removePrefix("playlist:")).mapNotNull { byId[it] } }
            parent.startsWith("search:") -> { require(parent.length<=263);val words=normalized(parent.removePrefix("search:")).split(Regex("\\s+")).filter { it.isNotBlank() };require(words.isNotEmpty());available.filter { t->val text=normalized("${t.title} ${t.artist} ${t.album} ${t.albumArtist}");words.all { text.contains(it) } }.sortedBy { normalized(it.title) }.take(200) }
            else ->error("Nie znaleziono kolekcji")
        }
    }
    fun root()=folder(ROOT,"Mytify").buildUpon().setMediaMetadata(folder(ROOT,"Mytify").mediaMetadata.buildUpon().setExtras(Bundle().apply { putBoolean("android.media.browse.SEARCH_SUPPORTED",true);putInt("android.media.browse.CONTENT_STYLE_BROWSABLE_HINT",2);putInt("android.media.browse.CONTENT_STYLE_PLAYABLE_HINT",1) }).build()).build()
    private data class Row(val id: String,val title: String,val subtitle: String="",val song: Song?=null,val parent: String="",val station: Radio.Station?=null)
    // Directory answers are kept a few minutes: the car asks for the same lists often.
    private val stationCache=java.util.concurrent.ConcurrentHashMap<String,Pair<Long,List<Radio.Station>>>()
    private fun country()=java.util.Locale.getDefault().country.takeIf { it.length==2 }?:"PL"
    fun stations(folder: String): List<Radio.Station> = when {
        folder=="stations:favorites" ->Radio.favorites(context)
        folder=="stations:recent" ->Radio.recent(context).take(30)
        else -> {
            val now=android.os.SystemClock.elapsedRealtime()
            stationCache[folder]?.takeIf { now-it.first<10*60*1000 }?.second ?: when {
                folder=="stations:popular" ->Radio.search(country=country(),limit=50)
                folder.startsWith("stations:tag:") ->Radio.search(tag=folder.removePrefix("stations:tag:"),country=country(),limit=50).ifEmpty { Radio.search(tag=folder.removePrefix("stations:tag:"),limit=50) }
                else ->error("Nie znaleziono kolekcji")
            }.also { list->stationCache[folder]=now to list;list.forEach { known[it.id]=it } }
        }
    }
    private val known=java.util.concurrent.ConcurrentHashMap<String,Radio.Station>()
    fun station(id: String): Radio.Station?=known[id]?:Radio.known(context,id)
    /** A station ready for Media3: playlists opened, address remembered for restarts. Network thread. */
    fun playableStation(id: String): MediaItem {
        val s=station(id)?:error(Lang.t("Stacja jest niedostępna"))
        val address=Radio.click(s.id)?:s.url
        val (url,hls)=Radio.resolve(address)
        val ready=s.copy(url=url,hls=hls)
        Radio.remember(context,ready)
        return Radio.item(ready)
    }
    private fun rows(parent: String): List<Row> = when {
        parent==ROOT ->listOf(Row("albums",Lang.t("Albumy")),Row("playlists",Lang.t("Playlisty")),Row("liked",Lang.t("Polubione")),Row("all",Lang.t("Utwory")),Row("radio",Lang.t("Radio")))
        parent=="radio" ->listOf(Row("stations:favorites",Lang.t("Ulubione stacje")),Row("stations:recent",Lang.t("Ostatnio słuchane")),Row("stations:popular",if(country()=="PL") Lang.t("Popularne w Polsce") else Lang.t("Popularne stacje")))+GENRES.map { Row("stations:tag:$it",genreName(it)) }
        parent.startsWith("stations:") ->stations(parent).map { Row(it.id,it.name,it.codec,station=it) }
        parent=="albums" ->songs().filter { it.available }.groupBy { it.albumId }.entries.sortedWith(compareBy({ normalized(it.value.first().album) },{ normalized(it.value.first().albumArtist) },{ it.key })).map { (id,s)->Row(id,s.first().album.ifBlank { s.first().title },s.first().albumArtist) }
        parent=="playlists" -> { val a=PlaylistStore(catalog).list();listOf(Row("recent",Lang.t("Ostatnio dodane")))+(0 until a.length()).map { val p=a.getJSONObject(it);Row("playlist:"+p.getString("id"),p.getString("name")) } }
        else ->collection(parent).map { Row(trackId(it.id,parent),it.title,it.artist,it,parent) }
    }
    fun children(parent: String,page: Int,size: Int,client: String?=null): List<MediaItem> {
        val actual: List<Row>
        if(parent.startsWith("bucket:")) {
            val parts=parent.removePrefix("bucket:").split(':');require(parts.size==2)
            val start=parts[1].toInt();require(start>=0)
            actual=rows(decode(parts[0])).drop(start).take(100)
        } else {
            val all=rows(parent)
            actual=if(all.size>100) all.indices.step(100).map { i->Row("bucket:"+encode(parent)+":$i","${i+1}-${minOf(i+100,all.size)}",all[i].title) } else all
        }
        return page(actual,page,size).map { r->when {
            r.station!=null ->MediaItem.Builder().setMediaId(r.station.id).setMediaMetadata(Radio.browse(r.station)).build()
            r.song==null ->withArt(folder(r.id,r.title,r.subtitle),client)
            else ->browse(r.song,r.parent,client)
        } }
    }
    // Siatka Android Auto wymaga okładki dla folderów; bez artworkUri pokazuje trójkąt błędu.
    // Album/playlista/ostatnio dodane dostają okładkę pierwszego utworu z okładką, inaczej logo.
    private var artSongs: List<Song>?=null;private var artTime=0L
    private fun folderArt(id: String,client: String?): Uri? = runCatching {
        val candidates: Sequence<Song> = when {
            id.startsWith("album:") -> { val now=android.os.SystemClock.elapsedRealtime();val all=artSongs?.takeIf { now-artTime<10000 }?:songs().also { artSongs=it;artTime=now };all.asSequence().filter { it.available && it.albumId==id } }
            id.startsWith("playlist:") || id=="recent" -> collection(id).asSequence()
            id.startsWith("stations:") -> return Uri.parse("android.resource://${context.packageName}/drawable/mytify_foreground")
            else -> return null
        }
        candidates.firstOrNull { catalog.artwork(it.id)!=null }?.let { metadata(it,client).artworkUri }
            ?: Uri.parse("android.resource://${context.packageName}/drawable/mytify_foreground")
    }.getOrNull()
    private fun withArt(item: MediaItem,client: String?): MediaItem {
        val art=folderArt(item.mediaId,client)?:return item
        return item.buildUpon().setMediaMetadata(item.mediaMetadata.buildUpon().setArtworkUri(art).build()).build()
    }
    fun search(query: String,page: Int,size: Int,client: String?=null): List<MediaItem> { require(query.isNotBlank() && query.length<=256);return page(collection("search:$query"),page,size).map { browse(it,"search:$query",client) } }
    fun searchCount(query: String)=collection("search:$query").size
    fun browse(song: Song,parent: String,client: String?=null)=MediaItem.Builder().setMediaId(trackId(song.id,parent)).setMediaMetadata(metadata(song,client)).build()
    private fun metadata(song: Song,client: String?): MediaMetadata {
        val cover=catalog.artwork(song.id)?.path?.let { FileProvider.getUriForFile(context,context.packageName+".covers",File(it)) }
        if(cover!=null && client!=null && client!=context.packageName) context.grantUriPermission(client,cover,Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return MediaMetadata.Builder().setTitle(song.title).setArtist(song.artist).setAlbumTitle(song.album).setAlbumArtist(song.albumArtist).setArtworkUri(cover).setIsPlayable(true).setIsBrowsable(false).setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC).build()
    }
    fun playable(id: String): MediaItem {
        // Restarts and resumption use the stream address remembered when the station last played.
        if(id.startsWith("radio:")) return Radio.item(station(id)?:error(Lang.t("Stacja jest niedostępna")))
        val hash=canonical(id);val song=Song(catalog.track(hash));require(song.available) { Lang.t("Plik jest niedostępny") }
        return MediaItem.Builder().setMediaId(hash).setUri(catalog.uri(hash)).setMediaMetadata(metadata(song,null)).build()
    }
    fun get(id: String,client: String?=null): MediaItem {
        if(id==ROOT) return root()
        if(id in ROOT_IDS || id=="recent") return children(ROOT,0,4).firstOrNull { it.mediaId==id }?:folder(id,Lang.t("Ostatnio dodane"))
        if(id.startsWith("album:")) { val s=collection(id).firstOrNull()?:error(Lang.t("Album niedostępny"));return folder(id,s.album.ifBlank { s.title },s.albumArtist) }
        if(id.startsWith("playlist:")) { val a=PlaylistStore(catalog).list();val p=(0 until a.length()).map { a.getJSONObject(it) }.first { "playlist:"+it.getString("id")==id };return folder(id,p.getString("name")) }
        if(id.startsWith("bucket:")) return folder(id,Lang.t("Utwory"))
        if(id=="radio" || id.startsWith("stations:")) return children(if(id=="radio") ROOT else "radio",0,100).firstOrNull { it.mediaId==id }?:folder(id,Lang.t("Radio"))
        if(id.startsWith("radio:")) { val s=station(id)?:error(Lang.t("Stacja jest niedostępna"));return MediaItem.Builder().setMediaId(id).setMediaMetadata(Radio.browse(s)).build() }
        val s=Song(catalog.track(canonical(id)));require(s.available);return browse(s,parent(id)?:"all",client)
    }
    fun resolve(requested: List<MediaItem>,startIndex: Int,position: Long): androidx.media3.session.MediaSession.MediaItemsWithStartPosition {
        require(requested.isNotEmpty() && requested.size<=10000)
        val first=requested.first();val query=first.requestMetadata.searchQuery
        if(query!=null) {
            require(query.length<=256)
            // "radio X" / "stacja X" asks for a station; anything else the library first, then a station.
            val asked=Regex("^(radio|stacj[aęi]|station)\\s+",RegexOption.IGNORE_CASE).find(query.trim())
            val matches=if(asked!=null) emptyList() else collection(if(query.isBlank()) "recent" else "search:$query")
            if(matches.isEmpty() && query.isNotBlank()) {
                val name=asked?.let { query.trim().substring(it.range.last+1) }?:query
                val s=(Radio.favorites(context)+Radio.recent(context)).firstOrNull { normalized(it.name).contains(normalized(name.trim())) }
                    ?:Radio.search(name=name,limit=1).firstOrNull()
                if(s!=null) { known[s.id]=s;return androidx.media3.session.MediaSession.MediaItemsWithStartPosition(listOf(playableStation(s.id)),0,0) }
            }
            require(matches.isNotEmpty()) { Lang.t("Brak wyników") }
            return androidx.media3.session.MediaSession.MediaItemsWithStartPosition(matches.map { playable(it.id) },0,0)
        }
        if(requested.size==1 && first.mediaId.startsWith("radio:")) {
            // The car's next/previous walk favourites first, then the list the station came from.
            val ready=playableStation(first.mediaId)
            val s=station(first.mediaId)!!
            val folder=stationCache.values.map { it.second }.firstOrNull { l->l.any { it.id==s.id } }.orEmpty()
            val (list,at)=Radio.queue(context,s,folder)
            Radio.see(context,list)
            return androidx.media3.session.MediaSession.MediaItemsWithStartPosition(list.mapIndexed { i,x->if(i==at) ready else Radio.item(x) },at,0)
        }
        val parent=if(requested.size==1) parent(first.mediaId) else null
        if(parent!=null) {
            val hash=canonical(first.mediaId);val contextItems=collection(parent);val index=contextItems.indexOfFirst { it.id==hash };require(index>=0)
            val from=(index/10000)*10000;val queue=contextItems.drop(from).take(10000)
            return androidx.media3.session.MediaSession.MediaItemsWithStartPosition(queue.map { playable(it.id) },index-from,if(position==C.TIME_UNSET) 0 else maxOf(0,position))
        }
        return androidx.media3.session.MediaSession.MediaItemsWithStartPosition(requested.map { playable(it.mediaId) },if(startIndex==C.INDEX_UNSET) 0 else startIndex.coerceIn(0,requested.lastIndex),if(position==C.TIME_UNSET) 0 else maxOf(0,position))
    }
}
