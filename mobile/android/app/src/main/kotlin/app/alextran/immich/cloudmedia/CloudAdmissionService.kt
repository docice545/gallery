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
  putString("settings", CloudAdmissionPolicy.encodeValues(values))
}
internal fun Bundle.snapshot() = AdmissionSnapshot(getString("effective"), getBoolean("overridePresent"),
  getString("overrideValue"), getString("feature"), getString("enforcement"), getString("selected"),
  getInt("androidUser", -1), CloudAdmissionPolicy.decodeValues(getString("settings")))
internal fun AdmissionJournal.bundle() = Bundle().apply {
  putBundle("before", before.bundle()); putString("written", written)
  putString("changes", CloudAdmissionPolicy.encodeChanges(changes)); putString("plan", planToken)
}
internal fun Bundle.journal() = AdmissionJournal(
  requireNotNull(getBundle("before")).snapshot(), requireNotNull(getString("written")),
  CloudAdmissionPolicy.decodeChanges(getString("changes")),
)

/** Shizuku shell-UID service: only journaled DeviceConfig keys, never session/media access. */
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
      val out = CloudAdmissionPolicy.commandValue(stdout.get(1, TimeUnit.SECONDS))
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

  private fun get(namespace: String, key: String) =
    command("/system/bin/device_config", "get", namespace, key).takeUnless { it == "null" }

  private fun state(): AdmissionSnapshot {
    val help = command("/system/bin/device_config", "help")
    check(help.contains("list_local_overrides") && help.contains("clear_override") && help.contains("override")) {
      "System does not support reversible local overrides"
    }
    val listed = command("/system/bin/device_config", "list_local_overrides").lineSequence()
      .mapNotNull { line ->
        val normalized = line.trimStart()
        val separator = normalized.indexOf('=')
        if (separator <= 0) return@mapNotNull null
        val key = normalized.substring(0, separator)
        if (CloudAdmissionPolicy.settings.any { "${it.first}/${it.second}" == key }) {
          key to normalized.substring(separator + 1)
        } else null
      }.toList()
    // Read raw presence independently. An OEM list-format difference must not
    // make an existing override look absent and allow destructive clear/undo.
    val values = CloudAdmissionPolicy.settings.map { (namespace, key) ->
      val overrideValue = command("/system/bin/device_config", "get", "device_config_overrides",
        "$namespace:$key").takeUnless { it == "null" }
      DeviceConfigValue(namespace, key, get(namespace, key), overrideValue != null, overrideValue)
    }
    check(CloudAdmissionPolicy.verifyOverrideSnapshots(listed, values)) {
      "Local cloud-media overrides are not applied consistently"
    }
    val primary = values.first { it.namespace == CloudAdmissionPolicy.MEDIA_PROVIDER_NAMESPACE &&
      it.key == CloudAdmissionPolicy.ALLOWED_CLOUD_PROVIDERS }
    val feature = values.first { it.namespace == CloudAdmissionPolicy.MEDIA_PROVIDER_NAMESPACE &&
      it.key == CloudAdmissionPolicy.CLOUD_MEDIA_FEATURE_ENABLED }
    val selectedOutput = command("/system/bin/content", "call", "--uri", "content://media", "--method", "get_cloud_provider")
    check(selectedOutput.contains("get_cloud_provider_result=")) { "Unable to inspect selected provider" }
    val selected = Regex("get_cloud_provider_result=([^,} ]+)").find(selectedOutput)?.groupValues?.get(1)
      ?.takeUnless { it == "null" }
    return AdmissionSnapshot(primary.effective, primary.overridePresent, primary.overrideValue,
      feature.effective, get(CloudAdmissionPolicy.MEDIA_PROVIDER_NAMESPACE, "cloud_media_enforce_provider_allowlist"), selected,
      command("/system/bin/am", "get-current-user").toInt(), values)
  }

  private fun providerPackage(authority: String?): String? {
    if (authority == null) return null
    val provider = context.packageManager.resolveContentProvider(authority, 0)
      ?: throw IOException("Selected provider is not discoverable")
    check(provider.readPermission == CloudAdmissionPolicy.CLOUD_PERMISSION &&
      provider.writePermission == CloudAdmissionPolicy.CLOUD_PERMISSION)
    return provider.packageName
  }

  override fun inspect(): Bundle = operation {
    val snapshot = state()
    val own = context.packageManager.resolveContentProvider("${BuildConfig.APPLICATION_ID}.cloudmedia", 0)
    check(own?.packageName == BuildConfig.APPLICATION_ID && own.exported &&
      own.readPermission == CloudAdmissionPolicy.CLOUD_PERMISSION &&
      own.writePermission == CloudAdmissionPolicy.CLOUD_PERMISSION) { "Cloud provider is not installed correctly" }
    check(snapshot.androidUser == ownerUid / 100000) { "Switch to this application's Android user" }
    snapshot.bundle().apply { putString("selectedPackage", providerPackage(snapshot.selected)) }
  }

  override fun admit(expected: Bundle): Bundle = operation {
    val before = expected.snapshot()
    check(state() == before) { "System settings changed before activation" }
    val journal = CloudAdmissionPolicy.plan(before, BuildConfig.APPLICATION_ID, providerPackage(before.selected))
      ?: return@operation before.bundle()
    check(expected.getString("plan") == null || expected.getString("plan") == journal.planToken) { "Admission plan changed" }
    if (journal.changes.isEmpty()) return@operation before.bundle()
    journal.changes.forEach { change ->
      command("/system/bin/device_config", "override", change.before.namespace, change.before.key, change.written)
    }
    val after = state()
    check(CloudAdmissionPolicy.verifyAdmitted(after, journal)) { "Admission read-back failed; recovery is pending" }
    after.bundle()
  }

  override fun undo(journalBundle: Bundle): Bundle = operation {
    val journal = journalBundle.journal()
    val expectedPlan = CloudAdmissionPolicy.plan(journal.before, BuildConfig.APPLICATION_ID,
      providerPackage(journal.before.selected))
    check(expectedPlan != null && (journal.planToken.isEmpty() || expectedPlan.planToken == journal.planToken)) {
      "Invalid recovery journal"
    }
    val current = state()
    if (CloudAdmissionPolicy.isBefore(current, journal)) {
      return@operation current.bundle() // Idempotent recovery after a lost Binder acknowledgement.
    }
    CloudAdmissionPolicy.undoOwnedChanges(journal, ::state) { change ->
      if (change.before.overridePresent) {
        command("/system/bin/device_config", "override", change.before.namespace, change.before.key,
          requireNotNull(change.before.overrideValue))
      } else {
        command("/system/bin/device_config", "clear_override", change.before.namespace, change.before.key)
      }
    }
    val after = state()
    check(CloudAdmissionPolicy.isBefore(after, journal)) { "Recovery read-back failed" }
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
