package app.alextran.immich.sync

import android.provider.MediaStore
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaMimePolicyTest {
  @Test
  fun `source file in image row is rejected`() {
    assertFalse(MediaMimePolicy.isSupported(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE, "text/plain"))
  }

  @Test
  fun `matching image and video MIME types are accepted`() {
    assertTrue(MediaMimePolicy.isSupported(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE, "image/jpeg"))
    assertTrue(MediaMimePolicy.isSupported(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO, "video/mp4"))
  }

  @Test
  fun `missing MIME type remains compatible with older providers`() {
    assertTrue(MediaMimePolicy.isSupported(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE, null))
  }

  @Test
  fun `unsupported media type is rejected even without MIME type`() {
    assertFalse(MediaMimePolicy.isSupported(0, null))
  }
}
