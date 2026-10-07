package app.alextran.immich.cloudmedia

import android.content.Context
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Process
import app.alextran.immich.BuildConfig
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock

internal fun AdmissionSnapshot.bundle() = Bundle().apply {
  putString("effective", effective); putBoolean("overridePresent", overridePresent)
  putString("overrideValue", overrideValue); putString("feature", feature)
  putString("enforcement", enforcement); putString("selected", selected); putInt("androidUser", androidUser)
}
internal fun Bundle.snapshot() = AdmissionSnapshot(getString("effective"), getBoolean("overridePresent"),
  getString("overrideValue"), getString("feature"), getString("enforcement"), getString("selected"), getInt("androidUser", -1))
internal fun AdmissionJournal.bundle() = Bundle().apply { putBundle("before", before.bundle()); putString("written", written) }
internal fun Bundle.journal() = AdmissionJournal(requireNotNull(getBundle("before")).snapshot(), requireNotNull(getString("written")))

/** Shizuku shell-UID service: only one DeviceConfig key, never session/media access. */
class CloudAdmissionService(private val context: Context) : ICloudAdmission.Stub() {
  private val ownerUid = context.packageManager.getApplicationInfo(BuildConfig.APPLICATION_ID, 0).uid
  private val lock = ReentrantLock()
  private val active = AtomicReference<java.lang.Process?>()
  private val readers = Executors.newFixedThreadPool(2) { r -> Thread(r, "gallery-admission-output").apply { isDaemon = true } }
  @Volatile private var cancelled = false

  private fun verifyCaller() {
    CloudAdmissionPolicy.requireCaller(Process.myUid(), Binder.getCallingUid(), ownerUid, Build.VERSION.SDK_INT)
  }

  private fun <T> operation(block: () -> T): T {
    verifyCaller()
    check(lock.tryLock()) { "Another admission operation is active" }
    try { cancelled = false; return block() } finally { lock.unlock() }
  }

  private fun command(vararg args: String): String {
    if (cancelled) throw IOException("Admission cancelled")
    // Every caller below supplies an absolute, fixed executable and fixed verb.
    // No shell interpreter, arbitrary command, media path or credentials.
    val process = ProcessBuilder(*args).start()
    active.set(process)
    fun output(input: java.io.InputStream) = readers.submit<String> {
      input.bufferedReader().use { reader ->
        val buffer = CharArray(2048)
        val result = StringBuilder()
        while (true) {
          val n = reader.read(buffer)
          if (n < 0) break
          if (result.length + n > 65536) { process.destroyForcibly(); throw IOException("Admission output exceeds limit") }
          result.append(buffer, 0, n)
        }
        result.toString()
      }
    }
    val stdout = output(process.inputStream)
    val stderr = output(process.errorStream)
    try {
      if (!process.waitFor(8, TimeUnit.SECONDS)) throw IOException("Admission command timed out")
      val out = stdout.get(1, TimeUnit.SECONDS).trim()
      val err = stderr.get(1, TimeUnit.SECONDS).trim()
      if (cancelled || process.exitValue() != 0 || err.isNotEmpty() ||
        Regex("(?im)^(error|exception|permission denial|unknown command)[: ]").containsMatchIn(out)) {
        throw IOException("System rejected admission operation")
      }
      return out
    } finally {
      process.destroyForcibly(); stdout.cancel(true); stderr.cancel(true); active.compareAndSet(process, null)
    }
  }

  private fun get(key: String) = command("/system/bin/device_config", "get", "mediaprovider", key).takeUnless { it == "null" }

  private fun state(): AdmissionSnapshot {
    val help = command("/system/bin/device_config", "help")
    check(help.contains("list_local_overrides") && help.contains("clear_override") && help.contains("override")) {
      "System does not support reversible local overrides"
    }
    val overrides = command("/system/bin/device_config", "list_local_overrides").lineSequence()
      .filter { it.startsWith("mediaprovider/allowed_cloud_providers=") }.toList()
    check(overrides.size <= 1) { "Inconsistent local override" }
    val previousOverride = if (overrides.isEmpty()) null else command("/system/bin/device_config", "get",
      "device_config_overrides", "mediaprovider:allowed_cloud_providers")
    val effective = get("allowed_cloud_providers")
    if (overrides.isNotEmpty()) check(previousOverride == effective) { "Local override is not applied consistently" }
    val selectedOutput = command("/system/bin/content", "call", "--uri", "content://media", "--method", "get_cloud_provider")
    check(selectedOutput.contains("get_cloud_provider_result=")) { "Unable to inspect selected provider" }
    val selected = Regex("get_cloud_provider_result=([^,} ]+)").find(selectedOutput)?.groupValues?.get(1)
      ?.takeUnless { it == "null" }
    return AdmissionSnapshot(effective, overrides.isNotEmpty(), previousOverride,
      get("cloud_media_feature_enabled"), get("cloud_media_enforce_provider_allowlist"), selected,
      command("/system/bin/am", "get-current-user").toInt())
  }

  private fun providerPackage(authority: String?): String? {
    if (authority == null) return null
    val provider = context.packageManager.resolveContentProvider(authority, 0)
      ?: throw IOException("Selected provider is not discoverable")
    check(provider.readPermission == "com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS")
    return provider.packageName
  }

  override fun inspect(): Bundle = operation {
    val snapshot = state()
    val own = context.packageManager.resolveContentProvider("${BuildConfig.APPLICATION_ID}.cloudmedia", 0)
    check(own?.packageName == BuildConfig.APPLICATION_ID && own.exported &&
      own.readPermission == "com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS") { "Cloud provider is not installed correctly" }
    check(snapshot.androidUser == ownerUid / 100000) { "Switch to this application's Android user" }
    snapshot.bundle().apply { putString("selectedPackage", providerPackage(snapshot.selected)) }
  }

  override fun admit(expected: Bundle): Bundle = operation {
    val before = expected.snapshot()
    check(state() == before) { "System settings changed before activation" }
    val journal = CloudAdmissionPolicy.plan(before, BuildConfig.APPLICATION_ID, providerPackage(before.selected))
      ?: return@operation before.bundle()
    check(expected.getString("written") == journal.written) { "Admission plan changed" }
    command("/system/bin/device_config", "override", "mediaprovider", "allowed_cloud_providers", journal.written)
    val after = state()
    check(CloudAdmissionPolicy.verifyAdmitted(after, journal.written)) { "Admission read-back failed; recovery is pending" }
    after.bundle()
  }

  override fun undo(journalBundle: Bundle): Bundle = operation {
    val journal = journalBundle.journal()
    check(journal.written == CloudAdmissionPolicy.plan(journal.before, BuildConfig.APPLICATION_ID,
      providerPackage(journal.before.selected))?.written) { "Invalid recovery journal" }
    val current = state()
    if (current.overridePresent == journal.before.overridePresent && current.overrideValue == journal.before.overrideValue) {
      return@operation current.bundle() // Idempotent recovery after a lost Binder acknowledgement.
    }
    check(CloudAdmissionPolicy.canUndo(current, journal)) { "Settings changed externally; recovery will not overwrite them" }
    if (journal.before.overridePresent) command("/system/bin/device_config", "override", "mediaprovider", "allowed_cloud_providers",
      requireNotNull(journal.before.overrideValue))
    else command("/system/bin/device_config", "clear_override", "mediaprovider", "allowed_cloud_providers")
    val after = state()
    check(after.overridePresent == journal.before.overridePresent && after.overrideValue == journal.before.overrideValue) { "Recovery read-back failed" }
    after.bundle()
  }

  override fun cancel() { verifyCaller(); cancelled = true; active.get()?.destroyForcibly() }
  override fun destroy() {
    // The reserved Shizuku lifecycle transaction originates from its shell
    // service, not necessarily from the app UID which owns normal operations.
    CloudAdmissionPolicy.requireCaller(Process.myUid(), Binder.getCallingUid(), ownerUid, Build.VERSION.SDK_INT, lifecycle = true)
    cancelled = true; active.get()?.destroyForcibly(); readers.shutdownNow(); kotlin.system.exitProcess(0)
  }
}
