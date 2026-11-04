package app.alextran.immich.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaGenerationCheckpointTest {
  @Test
  fun `screenshot published during scan remains eligible for next delta`() {
    val media = mutableMapOf("external_primary" to 10L)
    var version = "first"
    val checkpoint = MediaGenerationCheckpoint { MediaGenerationSnapshot(version, media) }
    var saved: MediaGenerationSnapshot? = null
    checkpoint.begin() // cursor will see through generation 10
    media["external_primary"] = 11L // screenshot arrives after that cursor
    checkpoint.ensureStarted() // album reads must not move the baseline
    checkpoint.commit { saved = it }
    assertEquals(10L, saved!!.generations["external_primary"])
    assertTrue(media.getValue("external_primary") > saved!!.generations.getValue("external_primary"))
    checkpoint.begin() // queued observer pass sees generation 11
    version = "rebuilt" // MediaStore reset during this pass
    checkpoint.commit { saved = it }
    assertEquals(11L, saved!!.generations["external_primary"])
    assertEquals("first", saved!!.version) // next shouldFullSync detects reset
  }

  @Test
  fun `failed persistence retains baseline and clear starts a fresh scan`() {
    var generation = 10L
    val checkpoint = MediaGenerationCheckpoint { MediaGenerationSnapshot("v", mapOf("external" to generation)) }
    checkpoint.ensureStarted() // full scans start at the first album query
    try {
      checkpoint.commit { error("write failed") }
    } catch (_: IllegalStateException) {}
    generation = 12
    checkpoint.commit { assertEquals(10L, it.generations["external"]) }
    checkpoint.clear()
    checkpoint.ensureStarted()
    checkpoint.commit { assertEquals(12L, it.generations["external"]) }
  }
}
