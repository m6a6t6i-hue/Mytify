package pl.mytify.mytify

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class PlaylistStore(private val catalog: Catalog) {
    companion object {
        fun create(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE IF NOT EXISTS playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL)")
            db.execSQL("CREATE TABLE IF NOT EXISTS playlist_tracks(playlist TEXT NOT NULL,track TEXT NOT NULL,position INTEGER NOT NULL,PRIMARY KEY(playlist,track))")
        }
    }
    fun list(): JSONArray {
        val out=JSONArray();catalog.readableDatabase.rawQuery("SELECT id,name FROM playlists ORDER BY name COLLATE NOCASE,id",null).use { c -> while(c.moveToNext()) {
            val ids=ids(c.getString(0));out.put(obj("id" to c.getString(0),"name" to c.getString(1),"ids" to JSONArray(ids)))
        } };return out
    }
    fun ids(id: String): List<String> {
        val out=mutableListOf<String>();catalog.readableDatabase.rawQuery("SELECT track FROM playlist_tracks WHERE playlist=? ORDER BY position",arrayOf(id)).use { c->while(c.moveToNext()) out.add(c.getString(0)) };return out
    }
    fun save(id: String?,name: String,ids: List<String>): String {
        val title=name.trim();require(title.isNotEmpty() && title.length<=100) { "Nazwa playlisty: 1–100 znaków" }
        require(ids.size<=10000 && ids.distinct().size==ids.size) { "Nieprawidłowa lista utworów" }
        val db=catalog.writableDatabase;val key=id?:UUID.randomUUID().toString();db.beginTransaction();try {
            if(id!=null) require(db.rawQuery("SELECT id FROM playlists WHERE id=?",arrayOf(id)).use { it.moveToFirst() }) { "Playlista nie istnieje" }
            ids.forEach { require(db.rawQuery("SELECT id FROM tracks WHERE id=?",arrayOf(it)).use { c->c.moveToFirst() }) { "Utwór nie istnieje" } }
            db.insertWithOnConflict("playlists",null,ContentValues().apply { put("id",key);put("name",title) },SQLiteDatabase.CONFLICT_REPLACE)
            db.delete("playlist_tracks","playlist=?",arrayOf(key));ids.forEachIndexed { i,t->db.insertOrThrow("playlist_tracks",null,ContentValues().apply { put("playlist",key);put("track",t);put("position",i) }) };db.setTransactionSuccessful()
        } finally { db.endTransaction() };return key
    }
    fun delete(id: String) { val db=catalog.writableDatabase;db.beginTransaction();try { db.delete("playlist_tracks","playlist=?",arrayOf(id));db.delete("playlists","id=?",arrayOf(id));db.setTransactionSuccessful() } finally { db.endTransaction() } }
}
