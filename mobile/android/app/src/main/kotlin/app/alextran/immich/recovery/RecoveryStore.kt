package app.alextran.immich.recovery

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

/** All engines in this process share this admission owner. A process-wide OS lock
 * also excludes a second Android process. Losing an engine never releases a lease:
 * uncertain teardown requires process restart, never a guessed-safe promotion. */
class RecoveryStore(
  val root: File,
  private val original: File,
  private val syncDirectory: (File) -> Unit,
) : AutoCloseable {
  private var closed = false
  private val lockFile: RandomAccessFile
  private val processLock: java.nio.channels.FileLock
  private val leases = mutableSetOf<String>()
  private var probeOwner: String? = null
  private var validated = false
  private val stateFile = File(root, "selection")
  private var blocked = false
  private var active: String = ""
  private var selectionUncertain = false
  private var recoveryOwner: String? = null

  init {
    root.mkdirs()
    syncDirectory(root.parentFile!!)
    lockFile = RandomAccessFile(File(root, "owner.lock"), "rw")
    processLock = checkNotNull(lockFile.channel.tryLock()) { "another process owns SQLite" }
    try {
      if (stateFile.exists()) {
        val fields = stateFile.readText().split('\n')
        check(fields.size == 3 && fields[0] == "FOTO23" && fields[1] in listOf("blocked", "ready"))
        blocked = fields[1] == "blocked"
        active = fields[2]
        selected()
      } else {
        // A lost selector must never silently return to an older generation
        // and replay already acknowledged operations.
        check(root.listFiles()!!.none { it.isDirectory && it.name.startsWith("attempt-") })
      }
    } catch (_: Exception) {
      selectionUncertain = true
      blocked = true
    }
  }

  @Synchronized fun selected(): File {
    check(!selectionUncertain) { "selected database cannot be established" }
    return if (active.isEmpty()) original else safeFile(active).also {
      check(it.isFile) { "selected database missing" }
    }
  }
  fun legacySnapshots(): File = File(original.parentFile!!, "sqlite-recovery")
  @Synchronized fun exportSource(): File = if (selectionUncertain) original else selected()
  @Synchronized fun exportReason(): String = if (selectionUncertain) "selection_unavailable" else "recovery_blocked"

  private fun safeFile(relative: String): File {
    val file = File(root, relative).canonicalFile
    check(relative.isNotEmpty() && !File(relative).isAbsolute && file.path.startsWith(root.canonicalPath + File.separator))
    return file
  }

  private fun persist(nextBlocked: Boolean, nextActive: String) {
    // One atomic record commits BOTH the pointer and the admission barrier.
    val temporary = File(root, "selection.next")
    FileOutputStream(temporary).use {
      it.write("FOTO23\n${if (nextBlocked) "blocked" else "ready"}\n$nextActive".toByteArray())
      it.fd.sync()
    }
    check(temporary.renameTo(stateFile)) { "selection rename failed" }
    syncDirectory(root)
    active = nextActive
    blocked = nextBlocked
  }

  @Synchronized fun acquire(): Map<String, String> {
    check(!closed && !blocked && recoveryOwner == null) { "SQLite recovery required" }
    if (probeOwner != null) return mapOf("wait" to "true")
    val path = selected().path
    val token = UUID.randomUUID().toString()
    leases.add(token)
    if (!validated) probeOwner = token
    return mapOf("token" to token, "path" to path, "probe" to (!validated).toString())
  }

  /** Native read-only consumers must not bypass the startup WAL/health probe. */
  @Synchronized fun acquireNativeRead(): Map<String, String>? {
    if (closed || blocked || selectionUncertain || !validated || probeOwner != null || recoveryOwner != null) return null
    return acquire()
  }

  @Synchronized fun probeComplete(token: String) {
    check(probeOwner == token && leases.contains(token) && !blocked)
    validated = true
    probeOwner = null
  }
  @Synchronized fun release(token: String) {
    check(leases.remove(token))
    if (probeOwner == token) probeOwner = null
  }

  @Synchronized fun halt() {
    blocked = true // Even a failed fsync must stop this process.
    check(!selectionUncertain) { "manual selection recovery required" }
    persist(true, active)
  }

  @Synchronized fun begin(): Map<String, String> {
    halt()
    check(leases.isEmpty()) { "SQLite connections have not drained" }
    check(recoveryOwner == null) { "recovery already running" }
    val token = UUID.randomUUID().toString()
    recoveryOwner = token
    return mapOf("token" to token, "source" to selected().path, "root" to root.path)
  }

  @Synchronized fun finish(token: String) {
    check(recoveryOwner == token)
    recoveryOwner = null // Keep the durable stop marker after failure.
  }

  @Synchronized fun promote(token: String, path: String, expectedHash: String) {
    check(recoveryOwner == token && leases.isEmpty() && blocked)
    val file = File(path).canonicalFile
    // Android /data/user/0 can alias /data/data at a different path depth.
    // Compute the persisted relative pointer in one canonical coordinate space.
    val relative = file.relativeTo(root.canonicalFile).path
    check(file == safeFile(relative) && file.name == "immich.sqlite")
    check(file != selected().canonicalFile)
    check(!File("$path-wal").exists() || File("$path-wal").length() == 0L)
    check(!File("$path-journal").exists())
    check(hash(file) == expectedHash) { "candidate changed" }
    syncTree(file.parentFile!!)
    // All ancestors were created during this attempt; persist their entries too.
    var parent: File? = file.parentFile
    while (parent != null && parent.canonicalPath.startsWith(root.canonicalPath)) {
      syncDirectory(parent)
      parent = parent.parentFile
    }
    validated = false
    persist(false, relative)
    recoveryOwner = null
  }

  fun syncTree(directory: File) {
    check(directory.canonicalPath.startsWith(root.canonicalPath + File.separator))
    directory.listFiles()!!.forEach {
      check(it.canonicalPath.startsWith(directory.canonicalPath + File.separator))
      if (it.isDirectory) syncTree(it) else RandomAccessFile(it, "rw").use { handle -> handle.fd.sync() }
    }
    syncDirectory(directory)
    syncDirectory(directory.parentFile!!)
  }

  @Synchronized fun canExport(): Boolean = blocked && leases.isEmpty() && recoveryOwner == null

  /** Process owner shutdown; never used to bypass an outstanding connection. */
  @Synchronized override fun close() {
    check(leases.isEmpty())
    closed = true
    processLock.release()
    lockFile.close()
  }

  companion object {
    fun hash(file: File): String {
      val digest = MessageDigest.getInstance("SHA-256")
      file.inputStream().use { input ->
        val buffer = ByteArray(1024 * 1024)
        while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
      }
      return digest.digest().joinToString("") { "%02x".format(it) }
    }
  }
}
