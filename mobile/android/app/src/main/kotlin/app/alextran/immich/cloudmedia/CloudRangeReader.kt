package app.alextran.immich.cloudmedia

import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.Closeable
import java.io.IOException
import java.util.LinkedHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** A seekable, bounded HTTP byte source. No original is buffered or mirrored. */
internal class CloudRangeReader(
  private val client: OkHttpClient,
  private val request: () -> Request.Builder,
  private val checkAccess: () -> Unit,
  private val chunkBytes: Int = 512 * 1024,
) : Closeable {
  private val closed = AtomicBoolean(false)
  @Volatile private var call: Call? = null
  private var length: Long = -1
  private var etag: String? = null
  private val chunks = object : LinkedHashMap<Long, ByteArray>(4, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, ByteArray>?) = size > 4
  }

  private fun guard() {
    if (closed.get() || Thread.currentThread().isInterrupted) throw IOException("Cloud media read cancelled")
    checkAccess()
  }

  @Synchronized
  fun size(): Long {
    guard()
    if (length < 0) fetch(0, 1)
    return length
  }

  @Synchronized
  fun read(offset: Long, size: Int, data: ByteArray): Int {
    guard()
    if (offset < 0 || size < 0 || size > data.size) throw IOException("Invalid cloud media byte range")
    val length = size()
    if (offset >= length || size == 0) return 0
    var copied = 0
    val wanted = minOf(size.toLong(), length - offset).toInt()
    while (copied < wanted) {
      guard()
      val at = offset + copied
      val start = at / chunkBytes * chunkBytes
      val chunk = chunks[start] ?: fetch(start, minOf(chunkBytes.toLong(), length - start).toInt())
        .also { chunks[start] = it }
      val inside = (at - start).toInt()
      val count = minOf(wanted - copied, chunk.size - inside)
      if (count <= 0) throw IOException("Truncated cloud media response")
      chunk.copyInto(data, copied, inside, inside + count)
      copied += count
    }
    guard()
    return copied
  }

  private fun fetch(start: Long, count: Int): ByteArray {
    guard()
    val request = request().header("Range", "bytes=$start-${start + count - 1}")
      .header("Accept-Encoding", "identity").build()
    val current = client.newCall(request)
    call = current
    try {
      // close may run while the request/session builder is preparing the call.
      // Once published, recheck before execute: earlier cancellation prevents
      // network work, and later cancellation can now cancel this exact call.
      guard()
      current.execute().use { response ->
        guard()
        if (!response.isSuccessful) throw IOException("Cloud media HTTP ${response.code}")
        val body = response.body ?: throw IOException("Empty cloud media response")
        val range = response.header("Content-Range")?.let { Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(it) }
        val total = if (response.code == 206) {
          if (range == null || range.groupValues[1].toLong() != start ||
            range.groupValues[2].toLong() != start + count - 1) throw IOException("Invalid cloud media Content-Range")
          range.groupValues[3].toLong()
        } else {
          if (start != 0L) throw IOException("Server does not support seekable media ranges")
          body.contentLength().takeIf { it > 0 } ?: throw IOException("Unknown cloud media length")
        }
        if (total <= 0 || (length >= 0 && total != length)) throw IOException("Cloud media changed during transfer")
        val newEtag = response.header("ETag")
        if (etag != null && newEtag != etag) throw IOException("Cloud media changed during transfer")
        etag = newEtag
        length = total
        val bytes = ByteArray(minOf(count.toLong(), total - start).toInt())
        body.byteStream().use { input ->
          var read = 0
          while (read < bytes.size) {
            if (closed.get() || Thread.currentThread().isInterrupted) throw IOException("Cloud media read cancelled")
            val n = input.read(bytes, read, minOf(32 * 1024, bytes.size - read))
            if (n < 0) throw IOException("Truncated cloud media response")
            read += n
          }
        }
        guard()
        return bytes
      }
    } finally {
      call = null
    }
  }

  override fun close() {
    closed.set(true)
    call?.cancel()
    synchronized(this) { chunks.clear() }
  }
}
