package app.alextran.immich.images

import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.security.MessageDigest
import java.util.Locale

/**
 * Private, bounded, best-effort snapshot of server thumbnails.
 *
 * Unlike the HTTP cache this lives in filesDir: Android's routine cache eviction
 * must not make a previously visited library appear empty in airplane mode.
 * Keys include the authenticated session. The cookie itself is never written.
 *
 * This is deliberately NOT a cache for originals, video, or arbitrary URLs.
 */
internal class OfflineThumbnailCache(
  private val directory: File,
  private val maxBytes: Long = 1024L * 1024L * 1024L,
) {
  companion object {
    const val MAX_ITEM_BYTES = 4 * 1024 * 1024
    private val uuid = Regex("^[a-fA-F0-9-]{36}$")
    private val shaName = Regex("^[a-f0-9]{64}$")

    fun keyFor(url: String, requestHeaders: Map<String, String>): String? {
      val uri = try { URI(url) } catch (_: Exception) { return null }
      if (uri.scheme !in listOf("https", "http") || uri.host.isNullOrBlank()) return null

      val path = uri.path ?: return null
      val segments = path.split('/').filter { it.isNotEmpty() }
      if (segments.size < 3 || segments[segments.size - 3] != "assets" ||
          !uuid.matches(segments[segments.size - 2]) || segments.last() != "thumbnail") return null
      val assetsMarker = "/assets/"
      val assetsIndex = path.lastIndexOf(assetsMarker)
      if (assetsIndex < 0) return null

      val params = uri.rawQuery?.split('&')?.associate {
        it.substringBefore('=') to it.substringAfter('=', "")
      } ?: return null
      if (params["size"] !in listOf("thumbnail", "preview")) return null
      // Server's revision key prevents stale image reuse after an edit.
      if (params["c"].isNullOrBlank()) return null

      val cookie = requestHeaders.entries.firstOrNull { it.key.equals("cookie", true) }?.value
      val token = cookie?.split(';')?.map { it.trim() }
        ?.firstOrNull { it.startsWith("immich_access_token=") }
        ?.substringAfter('=')?.takeIf { it.isNotBlank() }
      val authorization = requestHeaders.entries.firstOrNull { it.key.equals("authorization", true) }?.value
      val principal = token ?: authorization?.takeIf { it.isNotBlank() } ?: return null
      // Never write a username, token, endpoint, URL or account ID to the filesystem.
      // The endpoint identity is only an input to the digest, so private/public
      // server switches cannot accidentally present one server's pixels under
      // another server's identity while no sensitive value is persisted.
      val assetId = segments[segments.size - 2].lowercase(Locale.ROOT)
      val contentIdentity = listOf(
        assetId, params.getValue("size"),
        params["edited"] ?: "true", params.getValue("c")
      ).joinToString("\n")
      // Include the server base path as well as host/port. Two Gallery
      // instances can intentionally share a host while living behind
      // different reverse-proxy prefixes; their thumbnails must not collide.
      val serverBasePath = path.substring(0, assetsIndex).trimEnd('/').ifBlank { "/" }
      val serverIdentity = listOf(
        uri.scheme.lowercase(Locale.ROOT), uri.host.lowercase(Locale.ROOT), uri.port, serverBasePath,
      )
        .joinToString(":")
      return MessageDigest.getInstance("SHA-256").digest(
        ("foto-offline-v4\n" + serverIdentity + "\n" + principal + "\n" + contentIdentity)
          .toByteArray(Charsets.UTF_8)
      ).joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }
    }

    private fun isSupportedImage(bytes: ByteArray): Boolean {
      if (bytes.size < 12 || bytes.size > MAX_ITEM_BYTES) return false
      val jpeg = (bytes[0].toInt() and 0xff) == 0xff &&
        (bytes[1].toInt() and 0xff) == 0xd8 && (bytes[2].toInt() and 0xff) == 0xff
      val png = bytes.copyOfRange(0, 8).contentEquals(
        byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
      )
      val webp = String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" &&
        String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP"
      val iso = String(bytes, 4, 4, Charsets.US_ASCII) == "ftyp" &&
        String(bytes, 8, 4, Charsets.US_ASCII) in
        setOf("avif", "avis", "mif1", "heic", "heix", "hevc", "hevx")
      return jpeg || png || webp || iso
    }
  }

  @Synchronized
  fun read(key: String): ByteArray? {
    if (!shaName.matches(key)) return null
    val file = File(directory, key)
    if (!file.isFile) return null
    if (file.length() !in 12L..MAX_ITEM_BYTES.toLong()) {
      file.delete()
      return null
    }
    return try {
      val bytes = file.readBytes()
      if (!isSupportedImage(bytes)) {
        file.delete()
        return null
      }
      // Access-based eviction, without trusting server dates or HTTP cache headers.
      file.setLastModified(System.currentTimeMillis())
      bytes
    } catch (_: Exception) {
      null
    }
  }

  @Synchronized
  fun write(key: String, bytes: ByteArray): Boolean {
    if (!shaName.matches(key) || !isSupportedImage(bytes)) return false
    return try {
      if (!directory.isDirectory && !directory.mkdirs()) return false
      val destination = File(directory, key)
      if (destination.isFile) return true
      val temp = File.createTempFile("writing-", ".tmp", directory)
      try {
        FileOutputStream(temp).use { output ->
          output.write(bytes)
          output.fd.sync()
        }
        if (!temp.renameTo(destination)) return false
      } finally {
        temp.delete()
      }
      trim()
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun trim() {
    val entries = directory.listFiles()?.filter { it.isFile && shaName.matches(it.name) } ?: return
    var total = entries.sumOf { it.length() }
    if (total <= maxBytes) return
    for (entry in entries.sortedBy { it.lastModified() }) {
      val size = entry.length()
      if (entry.delete()) total -= size
      if (total <= maxBytes) break
    }
  }
}
