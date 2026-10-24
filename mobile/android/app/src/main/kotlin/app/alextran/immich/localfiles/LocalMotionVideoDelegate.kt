package app.alextran.immich.localfiles

import android.content.ContentUris
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Local MediaStore reads only; writes are confined to the app's disposable cache. */
internal class LocalMotionVideoDelegate(context: Context) {
  private val ctx = context.applicationContext
  private val main = Handler(Looper.getMainLooper())
  private val executor = Executors.newSingleThreadExecutor()
  private val operations = ConcurrentHashMap<String, Operation>()
  private val directory = File(ctx.cacheDir, "foto-local-motion-v1")

  private class Operation(val result: MethodChannel.Result) {
    val cancelled = AtomicBoolean()
    val delivered = AtomicBoolean()
    val signal = CancellationSignal()
  }

  fun resolve(arguments: Any?, result: MethodChannel.Result) {
    val args = arguments as? Map<*, *>
    val requestId = args?.get("requestId") as? String
    val id = args?.get("id") as? String
    val expectedName = args?.get("name") as? String
    val expectedCreated = (args?.get("createdAt") as? Number)?.toLong()
    val expectedUpdated = (args?.get("updatedAt") as? Number)?.toLong()
    val expectedChecksum = args?.get("checksum") as? String
    if (requestId.isNullOrEmpty() || id == null || id.toLongOrNull() == null || id.toLong() <= 0 ||
      expectedName == null || expectedCreated == null || expectedUpdated == null) {
      result.error("INVALID_ARGS", "A local image identity is required", null)
      return
    }
    if (operations.size >= 2 || operations.containsKey(requestId)) {
      result.error("LOCAL_MOTION_BUSY", "A local motion extraction is already pending", null)
      return
    }
    val operation = Operation(result)
    operations[requestId] = operation
    val timeout = Runnable {
      operation.cancelled.set(true)
      finish(operation, null, "LOCAL_MOTION_TIMEOUT")
    }
    main.postDelayed(timeout, 20_000)
    executor.execute {
      var path: String? = null
      var error: String? = null
      try {
        if (!operation.cancelled.get()) {
          path = extract(id, expectedName, expectedCreated, expectedUpdated, expectedChecksum, operation)?.absolutePath
        }
      } catch (_: SecurityException) {
        error = "LOCAL_MOTION_PERMISSION"
      } catch (_: Exception) {
        if (!operation.cancelled.get()) error = "LOCAL_MOTION_READ_FAILED"
      } finally {
        operations.remove(requestId, operation)
        main.post {
          main.removeCallbacks(timeout)
          finish(operation, if (operation.cancelled.get()) null else path, error)
        }
      }
    }
  }

  fun cancel(arguments: Any?, result: MethodChannel.Result) {
    val id = (arguments as? Map<*, *>)?.get("requestId") as? String
    val operation = id?.let(operations::get)
    if (operation != null) {
      operation.cancelled.set(true)
      finish(operation, null, null)
      // ContentResolver supports this cancellation signal; dispatch away from
      // Main because a misbehaving provider can block even its cancel callback.
      Thread { operation.signal.cancel() }.start()
    }
    result.success(operation != null)
  }

  fun dispose() {
    for (operation in operations.values) {
      operation.cancelled.set(true)
      finish(operation, null, null)
    }
    executor.shutdownNow()
  }

  private fun finish(operation: Operation, path: String?, error: String?) {
    if (!operation.delivered.compareAndSet(false, true)) return
    if (error == null) operation.result.success(path)
    else operation.result.error(error, "Local motion video unavailable", null)
  }

  private fun extract(id: String, name: String, createdAt: Long, updatedAt: Long, checksum: String?, operation: Operation): File? {
    val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLong())
    val columns = arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
      MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.DATE_TAKEN)
    fun revision(): String? = ctx.contentResolver.query(uri, columns, null, null, null, operation.signal)?.use { cursor ->
      if (!cursor.moveToFirst()) return@use null
      val taken = cursor.getLong(4)
      val created = if (taken > 0) taken / 1000 else cursor.getLong(2)
      if (cursor.getString(0) != name || created != createdAt || cursor.getLong(3) != updatedAt) return@use null
      "$id|${cursor.getLong(1)}|$created|$updatedAt|$name|${checksum ?: ""}"
    }
    val identity = revision() ?: return null
    if (operation.cancelled.get()) return null
    directory.mkdirs()
    directory.listFiles()?.filter {
      it.extension == "partial" && System.currentTimeMillis() - it.lastModified() > 24L * 60 * 60 * 1000
    }?.forEach { it.delete() }
    val key = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
    val target = File(directory, "$key.mp4")
    if (target.isFile && target.length() in 16..LocalMotionPhotoLayout.MAX_VIDEO_BYTES && hasVideo(target)) {
      if (operation.cancelled.get()) return null
      target.setLastModified(System.currentTimeMillis())
      trim(target)
      return target.takeUnless { operation.cancelled.get() }
    }
    val temporary = File.createTempFile("motion-", ".partial", directory)
    try {
      ctx.contentResolver.openAssetFileDescriptor(uri, "r", operation.signal)?.use { descriptor ->
        descriptor.createInputStream().use { input ->
          val channel = input.channel
          val start = descriptor.startOffset
          val size = if (descriptor.declaredLength >= 0) descriptor.declaredLength else channel.size() - start
          if (size <= 0) return null
          fun read(position: Long, count: Int): ByteArray {
            if (operation.cancelled.get() || position < 0 || count < 0 || position > size - count) return byteArrayOf()
            val buffer = java.nio.ByteBuffer.allocate(count)
            var offset = 0
            while (buffer.hasRemaining()) {
              if (operation.cancelled.get()) return byteArrayOf()
              val read = channel.read(buffer, start + position + offset)
              if (read <= 0) return byteArrayOf()
              offset += read
            }
            return buffer.array()
          }
          val range = LocalMotionPhotoLayout.locate(size, ::read) ?: return null
          val header = read(range.start, 12)
          if (header.size != 12 || header.copyOfRange(4, 8).toString(Charsets.US_ASCII) != "ftyp") return null
          FileOutputStream(temporary).use { output ->
            var copied = 0L
            while (copied < range.length) {
              if (operation.cancelled.get()) return null
              val count = minOf(64L * 1024, range.length - copied).toInt()
              val bytes = read(range.start + copied, count)
              if (bytes.size != count) return null
              output.write(bytes)
              copied += count
            }
          }
        }
      } ?: return null
      if (operation.cancelled.get() || revision() != identity || !hasVideo(temporary)) return null
      if (operation.cancelled.get()) return null
      if (!temporary.renameTo(target)) return null
      trim(target)
      return target
    } finally {
      temporary.delete()
    }
  }

  private fun hasVideo(file: File): Boolean {
    val extractor = MediaExtractor()
    return try {
      extractor.setDataSource(file.absolutePath)
      (0 until extractor.trackCount).any { index ->
        val format = extractor.getTrackFormat(index)
        format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true &&
          format.containsKey(MediaFormat.KEY_WIDTH) && format.getInteger(MediaFormat.KEY_WIDTH) > 0 &&
          format.containsKey(MediaFormat.KEY_HEIGHT) && format.getInteger(MediaFormat.KEY_HEIGHT) > 0
      }
    } catch (_: Exception) {
      false
    } finally {
      extractor.release()
    }
  }

  private fun trim(keep: File) {
    val files = directory.listFiles()?.filter { it.isFile && it.extension == "mp4" }?.sortedBy { it.lastModified() } ?: return
    var bytes = files.sumOf { it.length() }
    var count = files.size
    for (file in files) {
      if (file == keep) continue
      if (count <= 3 && bytes <= 128L * 1024 * 1024) break
      val length = file.length()
      if (file.delete()) { bytes -= length; count-- }
    }
  }
}
