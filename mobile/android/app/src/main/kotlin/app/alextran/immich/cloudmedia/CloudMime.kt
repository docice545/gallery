package app.alextran.immich.cloudmedia

/** Exact filename extensions, never filename-based asset identity. */
internal object CloudMime {
  private val types = linkedMapOf(
    "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "jpe" to "image/jpeg",
    "png" to "image/png", "webp" to "image/webp", "gif" to "image/gif",
    "heic" to "image/heic", "heif" to "image/heif", "avif" to "image/avif",
    "tif" to "image/tiff", "tiff" to "image/tiff", "bmp" to "image/bmp", "dng" to "image/x-adobe-dng",
    "mp4" to "video/mp4", "m4v" to "video/mp4", "mov" to "video/quicktime",
    "mkv" to "video/x-matroska", "webm" to "video/webm", "avi" to "video/x-msvideo",
    "3gp" to "video/3gpp", "3g2" to "video/3gpp2", "mts" to "video/mp2t", "m2ts" to "video/mp2t",
  )
  fun mime(name: String, type: Int): String? = types[name.substringAfterLast('.', "").lowercase()]
    ?.takeIf { if (type == 1) it.startsWith("image/") else type == 2 && it.startsWith("video/") }

  fun condition(filters: Array<String>?): Pair<String, List<String>> {
    val patterns = filters?.toList()?.takeIf { it.isNotEmpty() } ?: listOf("*/*")
    val extensions = types.filter { (_, mime) -> patterns.any { it == "*/*" || it == mime || it == "${mime.substringBefore('/')}/*" } }.keys
    if (extensions.isEmpty()) return "0" to emptyList()
    return extensions.joinToString(" OR ", "(", ")") { "LOWER(name) LIKE ?" } to extensions.map { "%.$it" }
  }
}
