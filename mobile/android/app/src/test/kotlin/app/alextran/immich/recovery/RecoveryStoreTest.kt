package app.alextran.immich.recovery

import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RecoveryStoreTest {
  @get:Rule val temporary = TemporaryFolder()
  private fun sync(directory: File) { FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) } }
  private fun source(): File = File(temporary.root, "immich.sqlite").apply { writeText("original database evidence") }
  private fun root(): File = File(temporary.root, "recovery")
  private fun candidate(): File = File(root(), "attempt/candidate/immich.sqlite").apply { parentFile!!.mkdirs(); writeText("validated candidate") }
  private fun refuses(action: () -> Unit) {
    try { action(); fail("unsafe operation was accepted") } catch (_: IllegalStateException) { }
  }

  @Test fun allLeasesMustCloseAndNoNewPoolCanStart() {
    RecoveryStore(root(), source(), ::sync).use { store ->
      val first = store.acquire(); store.probeComplete(first.getValue("token")); val second = store.acquire()
      refuses { store.begin() }
      refuses { store.acquire() }
      store.release(first.getValue("token"))
      refuses { store.begin() }
      store.release(second.getValue("token"))
      val recovery = store.begin()
      refuses { store.acquire() }
      store.finish(recovery.getValue("token"))
      refuses { store.acquire() }
    }
  }
  @Test fun parallelEnginesWaitForFirstReadOnlyProbe() {
    RecoveryStore(root(), source(), ::sync).use { store ->
      val first = store.acquire()
      assertEquals("true", first["probe"])
      assertEquals("true", store.acquire()["wait"])
      store.probeComplete(first.getValue("token"))
      val second = store.acquire()
      assertEquals("false", second["probe"])
      store.release(first.getValue("token")); store.release(second.getValue("token"))
    }
  }
  @Test fun failedAttemptSurvivesRestartAndKeepsOriginal() {
    val original = source()
    RecoveryStore(root(), original, ::sync).use { store -> store.begin(); candidate() }
    RecoveryStore(root(), original, ::sync).use { store ->
      refuses { store.acquire() }
      assertEquals(original.path, store.selected().path)
      assertTrue(candidate().exists())
      store.begin()
    }
    assertEquals("original database evidence", original.readText())
  }
  @Test fun selectionCommitsAtomicallyAndSurvivesRestart() {
    val original = source()
    val replacement = candidate()
    RecoveryStore(root(), original, ::sync).use { store ->
      val session = store.begin()
      store.promote(session.getValue("token"), replacement.path, RecoveryStore.hash(replacement))
      val connection = store.acquire()
      assertEquals(replacement.path, connection["path"])
      store.release(connection.getValue("token"))
    }
    RecoveryStore(root(), original, ::sync).use { store -> assertEquals(replacement.path, store.selected().path) }
    assertEquals("original database evidence", original.readText())
  }
  @Test fun changedCandidateOrWalNeverPromotes() {
    val original = source()
    RecoveryStore(root(), original, ::sync).use { store ->
      val session = store.begin()
      val replacement = candidate()
      refuses { store.promote(session.getValue("token"), replacement.path, "bad hash") }
      File("$replacement-wal").writeText("uncheckpointed")
      refuses { store.promote(session.getValue("token"), replacement.path, RecoveryStore.hash(replacement)) }
      assertEquals(original.path, store.selected().path)
    }
  }
  @Test fun missingSelectedDatabaseFailsInsteadOfCreatingEmptyDatabase() {
    val original = source()
    val replacement = candidate()
    RecoveryStore(root(), original, ::sync).use { store ->
      val session = store.begin()
      store.promote(session.getValue("token"), replacement.path, RecoveryStore.hash(replacement))
    }
    replacement.delete()
    refuses { RecoveryStore(root(), original, ::sync) }
    assertTrue(original.exists())
  }
  @Test fun fsyncFailureRetainsAdmissionBarrier() {
    val original = source()
    var failSync = false
    RecoveryStore(root(), original) { if (failSync) error("disk full") else sync(it) }.use { store ->
      failSync = true
      refuses { store.begin() }
      refuses { store.acquire() }
      assertEquals(original.path, store.selected().path)
    }
  }
  @Test fun orphanSelectionNextIsNeverInterpretedAsCommitted() {
    val original = source()
    root().mkdirs()
    File(root(), "selection.next").writeText("torn pointer")
    RecoveryStore(root(), original, ::sync).use { store -> assertEquals(original.path, store.selected().path) }
  }
}
