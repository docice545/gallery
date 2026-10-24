package app.alextran.immich.localfiles

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SyncTrashPolicyTest {
  private val expected = SyncTrashAsset("42", 1, "photo.jpg", 1000, 1100)
  private val current = SyncTrashSnapshot(1, "photo.jpg", 1000, 1100, false)

  @Test fun `unchanged live media is eligible`() {
    assertNull(SyncTrashPolicy.beforeWrite(expected, current))
  }

  @Test fun `missing media is never reported as successful trash`() {
    assertEquals("missing", SyncTrashPolicy.beforeWrite(expected, null))
  }

  @Test fun `repeated trash is idempotent even if OS changed modification time`() {
    assertEquals("alreadyTrashed", SyncTrashPolicy.beforeWrite(expected,
      current.copy(isTrashed = true, updatedAt = 1200)))
  }

  @Test fun `reused ID with a different name is refused`() {
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected, current.copy(name = "new.jpg")))
  }

  @Test fun `reused ID with a different capture time is refused`() {
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected, current.copy(createdAt = 2000)))
  }

  @Test fun `media edited since queued is refused`() {
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected, current.copy(updatedAt = 1200)))
  }

  @Test fun `media of another type is refused`() {
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected, current.copy(type = 2)))
  }
}
