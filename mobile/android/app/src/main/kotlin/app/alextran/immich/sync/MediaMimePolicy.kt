package app.alextran.immich.sync

import android.provider.MediaStore

/** Guards against MediaStore rows whose media_type disagrees with their actual MIME type. */
internal object MediaMimePolicy {
  fun isSupported(mediaType: Int, mimeType: String?): Boolean {
    return when (mediaType) {
      MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> mimeType.isNullOrBlank() || mimeType.startsWith("image/", ignoreCase = true)
      MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> mimeType.isNullOrBlank() || mimeType.startsWith("video/", ignoreCase = true)
      else -> false
    }
  }
}
