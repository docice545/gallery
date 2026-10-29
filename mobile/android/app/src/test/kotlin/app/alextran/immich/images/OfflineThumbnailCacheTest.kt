package app.alextran.immich.images

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class OfflineThumbnailCacheTest {
  @get:Rule val temporaryFolder = TemporaryFolder()

  private val url = "https://imm.lampax.top/api/assets/550e8400-e29b-41d4-a716-446655440000/thumbnail?size=thumbnail&edited=true&c=revision1"
  private val sessionA = mapOf("Cookie" to "immich_access_token=token-A; immich_is_authenticated=true")
  private val sessionB = mapOf("Cookie" to "immich_access_token=token-B; immich_is_authenticated=true")
  private val jpeg = byteArrayOf(
    0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xe0.toByte(),
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
  )

  @Test fun onlyVersionedAuthorizedThumbnailsQualify() {
    assertNotNull(OfflineThumbnailCache.keyFor(url, sessionA))
    assertNull(OfflineThumbnailCache.keyFor(url, emptyMap()))
    assertNull(OfflineThumbnailCache.keyFor(url.replace("&c=revision1", ""), sessionA))
    assertNull(OfflineThumbnailCache.keyFor(url.replace("thumbnail?size", "original?size"), sessionA))
    assertNull(OfflineThumbnailCache.keyFor(url.replace("size=thumbnail", "size=fullsize"), sessionA))
    assertNull(OfflineThumbnailCache.keyFor("https://untrusted.example/path?size=thumbnail&c=revision1", sessionA))
    assertNull(OfflineThumbnailCache.keyFor("file:///tmp/photo", sessionA))
  }

  @Test fun cacheNeverSharesFilesBetweenLoginSessions() {
    val keyA = OfflineThumbnailCache.keyFor(url, sessionA)!!
    val keyB = OfflineThumbnailCache.keyFor(url, sessionB)!!
    assertNotEquals(keyA, keyB)
    val cache = OfflineThumbnailCache(temporaryFolder.newFolder("offline"))
    assertTrue(cache.write(keyA, jpeg))
    assertArrayEquals(jpeg, cache.read(keyA))
    assertNull(cache.read(keyB))
    // A recreated store is able to read from app-private durable disk.
    assertArrayEquals(jpeg, OfflineThumbnailCache(File(temporaryFolder.root, "offline")).read(keyA))
  }

  @Test fun serverIdentitySeparatesPrivateAndPublicEndpoints() {
    val privateUrl = "http://10.10.10.80:2283/api/assets/550e8400-e29b-41d4-a716-446655440000/thumbnail?size=thumbnail&edited=true&c=revision1"
    val publicUrl = url
    val keyInternal = OfflineThumbnailCache.keyFor(privateUrl, sessionA)!!
    val keyExternal = OfflineThumbnailCache.keyFor(publicUrl, sessionA)!!
    assertNotEquals(keyInternal, keyExternal)
    val cache = OfflineThumbnailCache(temporaryFolder.newFolder("endpoint-switch"))
    assertTrue(cache.write(keyInternal, jpeg))
    assertNull(cache.read(keyExternal))
    assertNotEquals(keyExternal, OfflineThumbnailCache.keyFor(publicUrl, sessionB))
  }

  @Test fun serverIdentitySeparatesReverseProxyBasePaths() {
    val nested = url.replace("/api/assets", "/gallery/api/assets")
    assertNotEquals(
      OfflineThumbnailCache.keyFor(url, sessionA),
      OfflineThumbnailCache.keyFor(nested, sessionA),
    )
  }

  @Test fun changedRevisionNeverReadsStalePixels() {
    val oldKey = OfflineThumbnailCache.keyFor(url, sessionA)!!
    val newKey = OfflineThumbnailCache.keyFor(url.replace("revision1", "revision2"), sessionA)!!
    assertNotEquals(oldKey, newKey)
    val cache = OfflineThumbnailCache(temporaryFolder.newFolder("revisions"))
    assertTrue(cache.write(oldKey, jpeg))
    assertNull(cache.read(newKey))
  }

  @Test fun refusesMalformedImagesAndPathTraversal() {
    val key = OfflineThumbnailCache.keyFor(url, sessionA)!!
    val cache = OfflineThumbnailCache(temporaryFolder.newFolder("invalid"))
    assertFalse(cache.write(key, "not-an-image-at-all".toByteArray()))
    assertFalse(cache.write("../escape", jpeg))
    assertNull(cache.read("../escape"))
    assertTrue(cache.write(key, jpeg))
  }

  @Test fun corruptedEntryIsRemovedAndNeverPresentedAsAnImage() {
    val key = OfflineThumbnailCache.keyFor(url, sessionA)!!
    val cache = OfflineThumbnailCache(temporaryFolder.newFolder("corrupted"))
    val file = File(temporaryFolder.root, "corrupted/$key")
    file.parentFile!!.mkdirs()
    file.writeBytes("broken-image".toByteArray())

    assertNull(cache.read(key))
    assertFalse(file.exists())
  }

  @Test fun truncatedEntryIsRemovedAndNeverPresentedAsAnImage() {
    val key = OfflineThumbnailCache.keyFor(url, sessionA)!!
    val cache = OfflineThumbnailCache(temporaryFolder.newFolder("truncated"))
    val file = File(temporaryFolder.root, "truncated/$key")
    file.parentFile!!.mkdirs()
    file.writeBytes(byteArrayOf(0xff.toByte(), 0xd8.toByte()))

    assertNull(cache.read(key))
    assertFalse(file.exists())
  }

  @Test fun evictsOldestEntriesUnderStorageBudget() {
    val directory = temporaryFolder.newFolder("limited")
    val cache = OfflineThumbnailCache(directory, maxBytes = jpeg.size.toLong())
    val first = OfflineThumbnailCache.keyFor(url, sessionA)!!
    val second = OfflineThumbnailCache.keyFor(url.replace("revision1", "revision2"), sessionA)!!
    assertTrue(cache.write(first, jpeg))
    File(directory, first).setLastModified(System.currentTimeMillis() - 60_000)
    assertTrue(cache.write(second, jpeg))
    assertNull(cache.read(first))
    assertArrayEquals(jpeg, cache.read(second))
  }
}
