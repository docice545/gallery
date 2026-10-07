package app.alextran.immich.cloudmedia

import android.content.ContentResolver
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.provider.CloudMediaProvider
import android.provider.CloudMediaProviderContract as Contract
import android.system.ErrnoException
import android.system.OsConstants
import androidx.annotation.RequiresApi
import app.alextran.immich.core.HttpClientManager
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** System-picker-only, opt-in, API-gated. Normal media reads never invoke Shizuku. */
@RequiresApi(35)
class GalleryCloudMediaProvider : CloudMediaProvider() {
  private lateinit var catalog: CloudMediaCatalog
  private val streams = Semaphore(4)
  private val previews = Semaphore(4)
  private val columns = arrayOf("id", "date_taken_millis", "sync_generation", "mime_type",
    "standard_mime_type_extension", "size_bytes", "media_store_uri", "duration_millis", "is_favorite",
    "width", "height", "orientation")

  override fun onCreate(): Boolean {
    val ctx = context ?: return false
    catalog = CloudMediaCatalog(ctx)
    HttpClientManager.initialize(ctx)
    CloudMediaChanges.start(ctx)
    return true
  }

  private fun id(session: CloudSession, assetId: String) = "${session.scope}:$assetId"
  private fun assetId(session: CloudSession, id: String): String {
    if (!id.startsWith("${session.scope}:")) throw SecurityException("Media belongs to an inactive account")
    return id.substringAfter(':').takeIf { Regex("[a-fA-F0-9-]{36}").matches(it) }
      ?: throw SecurityException("Invalid cloud media identifier")
  }

  override fun onGetMediaCollectionInfo(extras: Bundle): Bundle {
    val session = catalog.session()
    val snapshot = session?.let { catalog.collection(it) }
    return Bundle().apply {
      putString(Contract.MediaCollectionInfo.MEDIA_COLLECTION_ID, snapshot?.first ?: "disabled")
      putLong(Contract.MediaCollectionInfo.LAST_MEDIA_SYNC_GENERATION, snapshot?.second ?: 0)
      // No email, owner ID or credentials in this system-visible account label.
      putString(Contract.MediaCollectionInfo.ACCOUNT_NAME, context?.getString(app.alextran.immich.R.string.app_name))
      putParcelable(Contract.MediaCollectionInfo.ACCOUNT_CONFIGURATION_INTENT,
        context?.packageManager?.getLaunchIntentForPackage(context!!.packageName))
    }
  }

  private fun attachExtras(cursor: MatrixCursor, collection: String, args: Bundle, next: String? = null) {
    cursor.extras = Bundle().apply {
      putString(Contract.EXTRA_MEDIA_COLLECTION_ID, collection)
      if (next != null) putString(Contract.EXTRA_PAGE_TOKEN, next)
      putStringArrayList(ContentResolver.EXTRA_HONORED_ARGS, ArrayList(listOf(Contract.EXTRA_SYNC_GENERATION,
        Contract.EXTRA_ALBUM_ID, Contract.EXTRA_PAGE_SIZE, Contract.EXTRA_PAGE_TOKEN, Intent.EXTRA_MIME_TYPES).filter { args.containsKey(it) }))
    }
  }

  override fun onQueryMedia(extras: Bundle): Cursor {
    val result = MatrixCursor(columns)
    val session = catalog.session() ?: return result.also { attachExtras(it, "disabled", extras) }
    val (collection, generation) = catalog.collection(session)
    val limit = extras.getInt(Contract.EXTRA_PAGE_SIZE, 200).coerceIn(1, 200)
    val token = extras.getString(Contract.EXTRA_PAGE_TOKEN)
    val offset = if (token == null) 0 else {
      if (!token.startsWith("$collection:")) throw IllegalArgumentException("Obsolete cloud media page")
      token.substringAfterLast(':').toIntOrNull()?.takeIf { it >= 0 }
        ?: throw IllegalArgumentException("Invalid cloud media page")
    }
    val album = extras.getString(Contract.EXTRA_ALBUM_ID)?.let { assetId(session, it) }
    val conditions = mutableListOf<String>()
    val args = mutableListOf<String>()
    val mime = CloudMime.condition(extras.getStringArray(Intent.EXTRA_MIME_TYPES))
    conditions.add(mime.first); args.addAll(mime.second)
    if (album != null) { conditions.add(catalog.albumCondition()); args.addAll(listOf(album, album)) }
    // System standard sync is unfiltered; rendering MIME comes from actual file extension.
    if (extras.getLong(Contract.EXTRA_SYNC_GENERATION, -1) >= generation) conditions.add("0")
    var read = 0
    catalog.query(session, conditions.joinToString(" AND ").ifEmpty { "1" }, args, limit + 1, offset) { cursor ->
      while (cursor.moveToNext()) {
        if (read >= limit) { read++; break }
        read++
        val item = catalog.item(cursor)
        val itemMime = item.mime ?: continue
        val localUri = item.localId?.takeIf { it.all(Char::isDigit) }?.let { "content://media/external/file/$it" }
        result.addRow(arrayOf(id(session, item.assetId), item.date, generation, itemMime,
          Contract.MediaColumns.STANDARD_MIME_TYPE_EXTENSION_NONE, item.size, localUri, item.duration,
          if (item.favorite) 1 else 0, item.width, item.height, item.orientation))
      }
    }
    attachExtras(result, collection, extras, if (read > limit) "$collection:${offset + limit}" else null)
    return result
  }

  override fun onQueryDeletedMedia(extras: Bundle): Cursor = MatrixCursor(arrayOf("id")).also {
    // Collection changes force a full reset. Never claim count-derived deletion deltas.
    attachExtras(it, catalog.session()?.let { s -> catalog.collection(s).first } ?: "disabled", extras)
  }

  override fun onQueryAlbums(extras: Bundle): Cursor {
    val result = MatrixCursor(arrayOf("id", "display_name", "date_taken_millis", "album_media_cover_id", "album_media_count"))
    val session = catalog.session() ?: return result.also { attachExtras(it, "disabled", extras) }
    val collection = catalog.collection(session).first
    val limit = extras.getInt(Contract.EXTRA_PAGE_SIZE, 200).coerceIn(1, 200)
    val token = extras.getString(Contract.EXTRA_PAGE_TOKEN)
    val offset = token?.let {
      require(it.startsWith("$collection:")) { "Obsolete cloud album page" }
      it.substringAfterLast(':').toIntOrNull()?.takeIf { n -> n >= 0 } ?: throw IllegalArgumentException("Invalid album page")
    } ?: 0
    var read = 0
    val mime = CloudMime.condition(extras.getStringArray(Intent.EXTRA_MIME_TYPES))
    catalog.albums(session, mime.first, mime.second) { cursor ->
      if (cursor.moveToPosition(offset)) do {
        if (read >= limit) { read++; break }
        result.addRow(arrayOf(id(session, cursor.getString(0)), cursor.getString(1), cursor.getLong(2),
          id(session, cursor.getString(3)), cursor.getLong(4)))
        read++
      } while (cursor.moveToNext())
    }
    attachExtras(result, collection, extras, if (read > limit) "$collection:${offset + limit}" else null)
    return result
  }

  private fun request(session: CloudSession, path: String): Request.Builder {
    catalog.requireSession(session.scope)
    val url = "${session.endpoint}/assets/$path"
    return Request.Builder().url(url).apply {
      val headers = HttpClientManager.getAuthHeaders(url)
      // A cached native cookie must belong to the same current Drift session.
      val token = headers["Cookie"]?.split(';')?.map { it.trim() }
        ?.firstOrNull { it.startsWith("immich_access_token=") }?.substringAfter('=')
      check(token == session.token) { "Native session has not synchronized" }
      for ((key, value) in headers) header(key, value)
    }
  }

  private fun client() = HttpClientManager.getClient().newBuilder().cache(null)
    // Gallery originals/playback are served by the authenticated endpoint.
    // Fail safely on redirects rather than forward custom credentials to a CDN.
    .followRedirects(false).followSslRedirects(false).callTimeout(30, TimeUnit.SECONDS).build()

  /** A descriptor open must recheck current server ACL/trash, not trust a stale picker index. */
  private fun authorize(session: CloudSession, item: CloudItem, signal: CancellationSignal?) {
    signal?.throwIfCanceled()
    val call = client().newCall(request(session, item.assetId).build())
    signal?.setOnCancelListener { call.cancel() }
    try {
      call.execute().use { response ->
        if (!response.isSuccessful) throw IOException("Cloud media access HTTP ${response.code}")
        val body = response.body ?: throw IOException("Missing media authorization response")
        val buffer = okio.Buffer()
        val source = body.source()
        while (true) {
          signal?.throwIfCanceled()
          val n = source.read(buffer, minOf(8192L, 128 * 1024 + 1L - buffer.size))
          if (n < 0) break
          if (buffer.size > 128 * 1024) throw IOException("Media authorization response exceeds limit")
        }
        val asset = JSONObject(buffer.readUtf8())
        if (!asset.has("isTrashed") || asset.getBoolean("isTrashed") || asset.optString("visibility") != "timeline" ||
          asset.optString("id") != item.assetId) throw SecurityException("Media is no longer visible")
      }
      catalog.requireSession(session.scope)
      signal?.throwIfCanceled()
    } finally { signal?.setOnCancelListener(null) }
  }

  private fun openRemote(session: CloudSession, item: CloudItem, path: String, signal: CancellationSignal?): ParcelFileDescriptor {
    if (!streams.tryAcquire()) throw FileNotFoundException("Too many active cloud media reads")
    val reader = CloudRangeReader(client(), { request(session, path) }, {
      signal?.throwIfCanceled(); catalog.item(catalog.requireSession(session.scope), item.assetId)
    })
    val thread = HandlerThread("gallery-cloud-read").apply { start() }
    val released = AtomicBoolean(false)
    val descriptor = AtomicReference<ParcelFileDescriptor?>()
    fun release() {
      if (released.compareAndSet(false, true)) {
        reader.close()
        // Calling setOnCancelListener from inside its own cancellation callback
        // deadlocks CancellationSignal waiting for that callback to return.
        if (signal?.isCanceled != true) signal?.setOnCancelListener(null)
        thread.quitSafely(); streams.release()
      }
    }
    signal?.setOnCancelListener { reader.close(); runCatching { descriptor.get()?.close() }; release() }
    try {
      signal?.throwIfCanceled()
      reader.size() // Fail open promptly on inaccessible/range-incompatible content.
      val storage = context!!.getSystemService(StorageManager::class.java)
      val fd = storage.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY, object : ProxyFileDescriptorCallback() {
        override fun onGetSize(): Long = try {
          reader.size()
        } catch (_: Exception) { throw ErrnoException("Cloud media size", OsConstants.EIO) }
        override fun onRead(offset: Long, size: Int, data: ByteArray): Int = try {
          reader.read(offset, size, data)
        } catch (_: Exception) { throw ErrnoException("Cloud media read", OsConstants.EIO) }
        override fun onRelease() = release()
      }, Handler(thread.looper))
      descriptor.set(fd)
      if (signal?.isCanceled == true) { fd.close(); throw IOException("Cloud media read cancelled") }
      return fd
    } catch (e: Exception) { release(); throw e }
  }

  override fun onOpenMedia(mediaId: String, extras: Bundle?, signal: CancellationSignal?): ParcelFileDescriptor {
    try {
      val session = catalog.session() ?: throw SecurityException("Cloud media is disabled")
      val item = catalog.item(session, assetId(session, mediaId))
      authorize(session, item, signal)
      return openRemote(session, item, "${item.assetId}/original", signal)
    } catch (e: Exception) { throw FileNotFoundException("Unable to open cloud media").apply { initCause(e) } }
  }

  override fun onOpenPreview(mediaId: String, size: Point, extras: Bundle?, signal: CancellationSignal?): AssetFileDescriptor {
    val session = catalog.session() ?: throw FileNotFoundException("Cloud media is disabled")
    val item = catalog.item(session, assetId(session, mediaId))
    authorize(session, item, signal)
    if (item.type == 2 && extras?.getBoolean(Contract.EXTRA_PREVIEW_THUMBNAIL, false) != true) {
      return AssetFileDescriptor(openRemote(session, item, "${item.assetId}/video/playback", signal), 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }
    if (!previews.tryAcquire()) throw FileNotFoundException("Too many active cloud previews")
    val dir = File(context!!.cacheDir, "gallery-cloud-previews").apply { mkdirs() }
    // Only this directory is owned here. Unlinked descriptors remain readable by
    // Android; no systemTemp/share/upload/Live Photo handoff cleanup is involved.
    dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > TimeUnit.HOURS.toMillis(1) }?.forEach { it.delete() }
    val file = File.createTempFile("preview-", ".media", dir)
    val thumbnail = if (maxOf(size.x, size.y) <= 250) "thumbnail" else "preview"
    val call = client().newCall(request(session, "${item.assetId}/thumbnail?size=$thumbnail").build())
    signal?.setOnCancelListener { call.cancel() }
    try {
      call.execute().use { response ->
        if (!response.isSuccessful) throw IOException("Cloud preview HTTP ${response.code}")
        val body = response.body ?: throw IOException("Missing cloud preview")
        body.byteStream().use { input -> file.outputStream().use { output ->
          val buffer = ByteArray(32 * 1024)
          var total = 0L
          while (true) {
            signal?.throwIfCanceled(); catalog.requireSession(session.scope)
            val n = input.read(buffer)
            if (n < 0) break
            total += n
            if (total > 16 * 1024 * 1024) throw IOException("Cloud preview exceeds size limit")
            output.write(buffer, 0, n)
          }
        } }
      }
      catalog.item(catalog.requireSession(session.scope), item.assetId)
      signal?.throwIfCanceled()
      val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
      file.delete()
      return AssetFileDescriptor(fd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    } catch (e: Exception) { throw FileNotFoundException("Unable to open cloud preview").apply { initCause(e) } }
    finally { signal?.setOnCancelListener(null); file.delete(); previews.release() }
  }
}
