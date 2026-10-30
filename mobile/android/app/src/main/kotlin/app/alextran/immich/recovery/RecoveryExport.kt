package app.alextran.immich.recovery

import java.io.File
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Streams directly to SAF: no cache archive, network, media or credentials in
 * the report. The explicitly exported SQLite files retain their original data. */
object RecoveryExport {
  fun write(store: RecoveryStore, output: OutputStream) {
    check(store.canExport())
    ZipOutputStream(output).use { zip ->
      fun add(file: File, name: String) {
        zip.putNextEntry(ZipEntry(name)); file.inputStream().use { it.copyTo(zip) }; zip.closeEntry()
      }
      val source = store.exportSource()
      val files = listOf(source, File("$source-wal"), File("$source-shm"), File("$source-journal")).filter { it.isFile }
      files.forEach { add(it, "source/${it.name}") }
      store.root.walkTopDown().filter { it.isFile && it.name !in listOf("owner.lock", "selection", "selection.next") }.forEach {
        check(it.canonicalPath.startsWith(store.root.canonicalPath + File.separator))
        add(it, "recovery/${it.relativeTo(store.root).path}")
      }
      // Available even when disk-space preflight failed before a report could
      // be saved internally. Detailed attempt reports, when present, are above.
      val hashes = files.joinToString(",") { "\"${it.name}\":\"${RecoveryStore.hash(it)}\"" }
      zip.putNextEntry(ZipEntry("export-report.json"))
      zip.write("{\"format\":23,\"reason\":\"${store.exportReason()}\",\"tablesChecked\":0,\"sourceChecksums\":{$hashes}}".toByteArray())
      zip.closeEntry()
    }
  }
}
