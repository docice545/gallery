package app.alextran.immich.cloudmedia

import org.junit.Assert.*
import org.junit.Test

class CloudMimeTest {
  @Test fun originalsHavePhotoAndVideoMimes() {
    assertEquals("image/jpeg", CloudMime.mime("photo.JPEG", 1))
    assertEquals("image/heic", CloudMime.mime("live.heic", 1))
    assertEquals("video/mp4", CloudMime.mime("video.MP4", 2))
    assertEquals("video/quicktime", CloudMime.mime("motion.mov", 2))
    assertNull(CloudMime.mime("video.jpg", 2))
    assertNull(CloudMime.mime("file.unknown", 1))
  }
  @Test fun systemMimeFiltersAreSqlBoundAndExact() {
    val photo = CloudMime.condition(arrayOf("image/jpeg"))
    assertEquals(listOf("%.jpg", "%.jpeg", "%.jpe"), photo.second)
    assertFalse(photo.first.contains("jpeg"))
    assertEquals(listOf("%.mp4", "%.m4v"), CloudMime.condition(arrayOf("video/mp4")).second)
    assertEquals("0", CloudMime.condition(arrayOf("image/jpeg' OR 1=1")).first)
    assertTrue(CloudMime.condition(arrayOf("*/*")).second.size > 10)
  }
}
