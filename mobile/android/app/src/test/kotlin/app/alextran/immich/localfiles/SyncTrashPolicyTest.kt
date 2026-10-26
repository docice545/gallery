package app.alextran.immich.localfiles

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SyncTrashPolicyTest {
  private val expected = SyncTrashAsset("42", 1, "photo.jpg", 1000, 1100)
  private val current = SyncTrashSnapshot(1, "photo.jpg", 1000, 1100, false)

  @Test fun `foreground user request may obtain system consent without MANAGE_MEDIA`() {
    assertEquals(true, SyncTrashPolicy.mayRequestTrash(true, false))
    assertEquals(true, SyncTrashPolicy.mayRequestTrash(true, true))
  }

  @Test fun `automatic sync cannot ask for consent after MANAGE_MEDIA is missing or revoked`() {
    assertEquals(false, SyncTrashPolicy.mayRequestTrash(false, false))
    assertEquals(true, SyncTrashPolicy.mayRequestTrash(false, true))
  }

  @Test fun `system trash is supported from API30 for user operations and API31 for sync`() {
    assertEquals(false, SyncTrashPolicy.supportsTrash(29, true))
    assertEquals(false, SyncTrashPolicy.supportsTrash(30, false))
    assertEquals(true, SyncTrashPolicy.supportsTrash(30, true))
    assertEquals(true, SyncTrashPolicy.supportsTrash(36, false))
  }

  @Test fun `trashed replacement with reused id never completes the original intent`() {
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected,
      current.copy(isTrashed = true, name = "replacement.jpg")))
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected,
      current.copy(isTrashed = true, createdAt = 2000)))
    assertEquals("assetChanged", SyncTrashPolicy.beforeWrite(expected,
      current.copy(isTrashed = true, type = 2)))
  }

  @Test fun `identity diagnostic distinguishes stale fingerprints without disclosing original name`() {
    assertEquals("phase=identity typeMatches=true nameMatches=false createdAtMatches=true " +
      "updatedAtMatches=false isTrashed=false", SyncTrashPolicy.identityDiagnostic(expected,
      current.copy(name = "private-replacement.jpg", updatedAt = 3000)))
    assertEquals("phase=identity: MediaStore row missing or no longer visible",
      SyncTrashPolicy.identityDiagnostic(expected, null))
  }

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
