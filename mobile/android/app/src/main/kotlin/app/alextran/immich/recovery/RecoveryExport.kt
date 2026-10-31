package app.alextran.immich.recovery

import java.io.File
import java.io.OutputStream
import java.io.InputStream
import java.security.DigestOutputStream
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Streams directly to SAF: no cache archive, network, media or credentials in
 * the report. The explicitly exported SQLite files retain their original data. */
object RecoveryExport {
  /** Byte-for-byte readback from the user's SAF URI; a successful write/close
   * alone cannot authorize starting over. No network destination is opened here. */
  fun writeVerified(store: RecoveryStore, output: OutputStream, reopen: () -> InputStream): Map<String, String> {
    val before = store.sourceChecksums()
    val written = MessageDigest.getInstance("SHA-256")
    write(store, DigestOutputStream(output, written))
    val expected = written.digest()
    val actual = MessageDigest.getInstance("SHA-256")
    reopen().use { input ->
      val buffer = ByteArray(1024 * 1024)
      while (true) { val count = input.read(buffer); if (count < 0) break; actual.update(buffer, 0, count) }
    }
    check(MessageDigest.isEqual(expected, actual.digest())) { "export readback mismatch" }
    return store.recordVerifiedExport(before, expected.joinToString("") { "%02x".format(it) })
  }

  fun write(store: RecoveryStore, output: OutputStream) {
    check(store.canExport())
    ZipOutputStream(output).use { zip ->
      fun add(file: File, name: String) {
        zip.putNextEntry(ZipEntry(name)); file.inputStream().use { it.copyTo(zip) }; zip.closeEntry()
      }
      val source = store.exportSource()
      val files = listOf(source, File("$source-wal"), File("$source-shm"), File("$source-journal")).filter { it.isFile }
      files.forEach { add(it, "source/${it.name}") }
      val original = store.originalSource()
      if (original.canonicalPath != source.canonicalPath) {
        listOf(original, File("$original-wal"), File("$original-shm"), File("$original-journal"))
          .filter { it.isFile }.forEach { add(it, "original/${it.name}") }
      }
      store.root.walkTopDown().filter { it.isFile && it.name !in listOf("owner.lock", "selection", "selection.next") }.forEach {
        check(it.canonicalPath.startsWith(store.root.canonicalPath + File.separator))
        add(it, "recovery/${it.relativeTo(store.root).path}")
      }
      // Build 22 may have retained the only complete older WAL snapshot. Make
      // that evidence available without USB/ADB, especially after WAL refusal.
      val legacy = store.legacySnapshots()
      if (legacy.isDirectory) legacy.walkTopDown().filter { it.isFile }.forEach {
        check(it.canonicalPath.startsWith(legacy.canonicalPath + File.separator))
        add(it, "build22-recovery/${it.relativeTo(legacy).path}")
      }
      // Available even when disk-space preflight failed before a report could
      // be saved internally. Detailed attempt reports, when present, are above.
      val hashes = files.joinToString(",") { "\"${it.name}\":\"${RecoveryStore.hash(it)}\"" }
      zip.putNextEntry(ZipEntry("export-report.json"))
      zip.write("{\"format\":24,\"reason\":\"${store.exportReason()}\",\"tablesChecked\":0,\"sourceChecksums\":{$hashes}}".toByteArray())
      zip.closeEntry()
    }
  }
}
