package app.alextran.immich.cloudmedia

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.os.CancellationSignal
import android.os.Build
import app.alextran.immich.R
import io.flutter.util.PathUtils
import java.io.File
import java.security.MessageDigest

internal fun cloudDigest(value: String): String = MessageDigest.getInstance("SHA-256")
  .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

internal data class CloudSession(val endpoint: String, val owner: String, val token: String) {
  // Never expose credentials, email or an unscoped server asset ID to the picker.
  val scope: String get() = cloudDigest("$endpoint\n$owner\n${cloudDigest(token)}").take(24)
}

internal data class CloudItem(
  val assetId: String, val name: String, val type: Int, val size: Long,
  val date: Long, val width: Int, val height: Int, val duration: Long,
  val favorite: Boolean, val orientation: Int, val localId: String?,
) {
  val mime: String? get() = CloudMime.mime(name, type)
}

/** Reads the existing WAL database. No second REST/sync/checkpoint or library mirror. */
internal class CloudMediaCatalog(private val context: Context) {
  companion object {
    // Provider and notification instances share the same preferences. Publish a
    // snapshot version once, even when both discover a DB change concurrently.
    private val collectionLock = Any()
  }
  private val prefs = context.getSharedPreferences("gallery.cloudmedia", Context.MODE_PRIVATE)
  private val file get() = File(PathUtils.getDataDirectory(context), "immich.sqlite")
  private val projection by lazy {
    context.resources.openRawResource(R.raw.gallery_cloud_media).bufferedReader().use { it.readText() }
  }
  private var snapshotCache: Triple<String, String, Pair<String, Long>>? = null
  private fun revision(): String {
    val wal = File("${file.path}-wal")
    return "${CloudMediaChanges.revision.get()}:${file.lastModified()}:${file.length()}:${wal.lastModified()}:${wal.length()}"
  }

  private fun <T> read(block: (SQLiteDatabase) -> T): T? {
    if (!file.isFile) return null
    return SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
      // Never read a migration's half-built schema. No PRAGMA/schema writes.
      val ready = db.rawQuery("PRAGMA user_version", null).use { it.moveToFirst() && it.getInt(0) == 38 }
      if (!ready) return@use null
      if (Build.VERSION.SDK_INT < 35) return@use null
      db.beginTransactionReadOnly()
      try { block(db).also { db.setTransactionSuccessful() } } finally { db.endTransaction() }
    }
  }

  fun session(requireEnabled: Boolean = true): CloudSession? = read { db ->
    val values = mutableMapOf<Int, String>()
    db.rawQuery("SELECT id, string_value FROM store_entity WHERE id IN (2,11,12)", null).use { c ->
      while (c.moveToNext()) if (!c.isNull(1)) values[c.getInt(0)] = c.getString(1)
    }
    val owner = values[2]?.takeIf { it.isNotBlank() } ?: return@read null
    val token = values[11]?.takeIf { it.isNotBlank() } ?: return@read null
    val endpoint = values[12]?.trimEnd('/')?.takeIf { it.startsWith("https://") || it.startsWith("http://") }
      ?: return@read null
    CloudSession(endpoint, owner, token).takeIf { !requireEnabled || prefs.getString("enabledScope", null) == it.scope }
  }

  fun requireSession(scope: String): CloudSession = session()?.takeIf { it.scope == scope }
    ?: throw SecurityException("Cloud media account is inactive")

  fun setEnabled(session: CloudSession?) {
    check(prefs.edit().putString("enabledScope", session?.scope).commit())
    snapshotCache = null
  }

  fun isEnabled(): Boolean = session() != null

  /**
   * Versioned full snapshots intentionally avoid guessing deletion deltas from
   * counts/timestamps. Hash rows incrementally; bounded cursors never materialize
   * 30k items in RAM. A changed snapshot makes Android reset its prior collection.
   * Stable media IDs are separate from this snapshot version.
   */
  fun collection(session: CloudSession): Pair<String, Long> = synchronized(collectionLock) {
    requireSession(session.scope)
    val revision = revision()
    snapshotCache?.takeIf { it.first == session.scope && it.second == revision }?.let { return@synchronized it.third }
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update(session.scope.toByteArray())
    read { db ->
      db.rawQuery("WITH eligible AS ($projection) SELECT * FROM eligible ORDER BY asset_id", arrayOf(session.owner))
        .use { cursor ->
          while (cursor.moveToNext()) for (i in 0 until cursor.columnCount) {
            val value = if (cursor.isNull(i)) "" else cursor.getString(i)
            digest.update(value.toByteArray()); digest.update(0)
          }
        }
      // Album labels/membership affect the same snapshot, including deletions.
      for (table in listOf("remote_album_entity", "remote_album_asset_entity", "remote_album_user_entity",
        "shared_space_album_entity", "shared_space_album_asset_entity", "shared_space_album_link_entity",
        "shared_space_album_hidden_entity", "shared_space_member_entity", "partner_entity")) {
        db.rawQuery("SELECT * FROM $table ORDER BY 1,2", null).use { cursor ->
          while (cursor.moveToNext()) for (i in 0 until cursor.columnCount) {
            digest.update((if (cursor.isNull(i)) "" else cursor.getString(i)).toByteArray()); digest.update(0)
          }
        }
      }
    } ?: throw IllegalStateException("Gallery catalog is unavailable")
    requireSession(session.scope)
    check(revision == revision()) { "Gallery catalog changed during snapshot; retry query" }
    val hash = digest.digest().joinToString("") { "%02x".format(it) }
    val key = "snapshot.${session.scope}"
    val generationKey = "generation.${session.scope}"
    if (prefs.getString(key, null) != hash) {
      val generation = maxOf(System.currentTimeMillis(), prefs.getLong(generationKey, 0) + 1)
      check(prefs.edit().putString(key, hash).putLong(generationKey, generation).commit())
    }
    val generation = prefs.getLong(generationKey, 0)
    ("${session.scope}.$hash.$generation" to generation).also {
      snapshotCache = Triple(session.scope, revision, it)
    }
  }

  fun query(session: CloudSession, condition: String = "1", args: List<String> = emptyList(),
    limit: Int = 200, offset: Int = 0, cancellation: CancellationSignal? = null,
    consume: (Cursor) -> Unit,
  ) {
    requireSession(session.scope)
    read { db ->
      db.rawQuery("WITH eligible AS ($projection) SELECT * FROM eligible WHERE $condition " +
        "ORDER BY date_taken_millis DESC, asset_id LIMIT ? OFFSET ?",
        (listOf(session.owner) + args + listOf(limit.coerceIn(1, 201).toString(), offset.coerceAtLeast(0).toString())).toTypedArray(),
        cancellation).use(consume)
    } ?: throw IllegalStateException("Gallery catalog is unavailable")
    requireSession(session.scope)
  }

  fun item(session: CloudSession, id: String): CloudItem {
    var item: CloudItem? = null
    query(session, "asset_id = ?", listOf(id), limit = 1) { c -> if (c.moveToFirst()) item = item(c) }
    return item ?: throw SecurityException("Media is no longer visible")
  }

  fun item(cursor: Cursor): CloudItem {
    fun text(name: String) = cursor.getColumnIndexOrThrow(name).let { if (cursor.isNull(it)) null else cursor.getString(it) }
    fun number(name: String) = cursor.getColumnIndexOrThrow(name).let { if (cursor.isNull(it)) 0 else cursor.getLong(it) }
    // Original EXIF orientation is not inferred from already-upright thumbnail dimensions.
    val orientation = when (text("orientation")?.substringBefore(' ')) { "6" -> 90; "3" -> 180; "8" -> 270; else -> 0 }
    return CloudItem(text("asset_id")!!, text("name")!!, number("type").toInt(), number("file_size"),
      number("date_taken_millis"), number("width").toInt(), number("height").toInt(), number("duration_ms"),
      number("is_favorite") != 0L, orientation, text("local_id"))
  }

  fun albums(session: CloudSession, mimeCondition: String, mimeArgs: List<String>, consume: (Cursor) -> Unit) {
    requireSession(session.scope)
    read { db ->
      db.rawQuery("""
        WITH all_eligible AS ($projection), eligible AS (SELECT * FROM all_eligible WHERE $mimeCondition), memberships AS (
          SELECT aa.album_id, aa.asset_id FROM remote_album_asset_entity aa
          WHERE EXISTS (SELECT 1 FROM remote_album_user_entity u WHERE u.album_id=aa.album_id AND u.user_id=?1)
          UNION
          SELECT aa.album_id, aa.asset_id FROM shared_space_album_asset_entity aa
          JOIN shared_space_album_link_entity l ON l.album_id=aa.album_id
          JOIN shared_space_member_entity m ON m.space_id=l.space_id
          WHERE m.user_id=?1 AND m.show_in_timeline=1
            AND NOT EXISTS (SELECT 1 FROM shared_space_album_hidden_entity h
              WHERE h.space_id=l.space_id AND h.album_id=aa.album_id AND h.user_id=?1)
        ), labels AS (SELECT id,name FROM remote_album_entity UNION SELECT id,name FROM shared_space_album_entity)
        SELECT a.id,a.name,MAX(e.date_taken_millis) AS date_taken_millis,
          MIN(e.asset_id) AS cover_id,COUNT(DISTINCT e.asset_id) AS media_count
        FROM labels a JOIN memberships m ON m.album_id=a.id JOIN eligible e ON e.asset_id=m.asset_id
        GROUP BY a.id,a.name ORDER BY a.name,a.id
      """.trimIndent(), (listOf(session.owner) + mimeArgs).toTypedArray()).use(consume)
    }
    requireSession(session.scope)
  }

  fun albumCondition(): String = """
    asset_id IN (SELECT asset_id FROM remote_album_asset_entity WHERE album_id=?
      AND EXISTS(SELECT 1 FROM remote_album_user_entity u WHERE u.album_id=remote_album_asset_entity.album_id AND u.user_id=?1)
      UNION SELECT aa.asset_id FROM shared_space_album_asset_entity aa
      JOIN shared_space_album_link_entity l ON l.album_id=aa.album_id
      JOIN shared_space_member_entity m ON m.space_id=l.space_id
      WHERE aa.album_id=? AND m.user_id=?1 AND m.show_in_timeline=1
      AND NOT EXISTS(SELECT 1 FROM shared_space_album_hidden_entity h WHERE h.space_id=l.space_id AND h.album_id=aa.album_id AND h.user_id=?1))
  """.trimIndent()
}
