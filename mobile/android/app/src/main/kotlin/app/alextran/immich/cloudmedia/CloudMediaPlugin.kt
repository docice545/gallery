package app.alextran.immich.cloudmedia

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import app.alextran.immich.BuildConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Foreground admission UI bridge; no Shizuku dependency in the media path. */
class CloudMediaPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
  private var context: Context? = null
  private var activity: android.app.Activity? = null
  private var channel: MethodChannel? = null
  private val main = Handler(Looper.getMainLooper())
  private val worker = Executors.newSingleThreadExecutor()
  private val busy = AtomicBoolean(false)
  private val cancelled = AtomicBoolean(false)
  @Volatile private var attached = false
  @Volatile private var service: ICloudAdmission? = null
  @Volatile private var stopBinding: (() -> Unit)? = null
  private var permissionResult: MethodChannel.Result? = null
  private var permissionMethod: String? = null
  private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, granted ->
    if (code == REQUEST_CODE) {
      val result = permissionResult
      val method = permissionMethod
      permissionResult = null; permissionMethod = null
      if (attached && result != null && method != null) {
        if (granted == PackageManager.PERMISSION_GRANTED) runOperation(method, result)
        else result.error("permissionDenied", "Shizuku permission was denied", null)
      }
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext; attached = true
    channel = MethodChannel(binding.binaryMessenger, "app.alextran.immich/cloudMedia").also { it.setMethodCallHandler(this) }
    Shizuku.addRequestPermissionResultListener(permissionListener)
    if (Build.VERSION.SDK_INT >= 35) CloudMediaChanges.start(binding.applicationContext)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    attached = false; permissionResult = null; permissionMethod = null
    cancelled.set(true)
    stopBinding?.invoke()
    channel?.setMethodCallHandler(null); channel = null; activity = null; context = null
    Shizuku.removeRequestPermissionResultListener(permissionListener)
    worker.shutdownNow()
    // Interrupts the wait/operation; its finally always unbinds the non-daemon service.
  }
  override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
  override fun onDetachedFromActivityForConfigChanges() { activity = null }
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
  override fun onDetachedFromActivity() { activity = null }

  private fun shizukuReady(): Boolean = runCatching { Shizuku.pingBinder() && Shizuku.getUid() == 2000 }.getOrDefault(false)
  private fun hasPermission(): Boolean = shizukuReady() && runCatching {
    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
  }.getOrDefault(false)

  private fun status(): Map<String, Any> {
    val ctx = context ?: throw IllegalStateException("Engine is detached")
    val prefs = ctx.getSharedPreferences("gallery.cloudmedia", Context.MODE_PRIVATE)
    val session = if (Build.VERSION.SDK_INT >= 35) runCatching { CloudMediaCatalog(ctx).session(false) }.getOrNull() else null
    return mapOf("supported" to (Build.VERSION.SDK_INT >= 35), "signedIn" to (session != null),
      "enabled" to (session != null && prefs.getString("enabledScope", null) == session.scope),
      "shizukuRunning" to shizukuReady(), "permissionGranted" to hasPermission(),
      "recoveryPending" to prefs.contains("recoveryJournal"))
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "cancel" -> {
        cancelled.set(true)
        permissionResult?.error("cancelled", "Cloud media activation was cancelled", null)
        permissionResult = null; permissionMethod = null
        // Cancellation must not queue behind the operation it is cancelling.
        Thread { runCatching { service?.cancel() }; stopBinding?.invoke() }.start()
        result.success(null)
      }
      "openPickerSettings" -> {
        val current = activity
        if (Build.VERSION.SDK_INT < 35 || current == null) result.error("unsupported", "Photo Picker settings are unavailable", null)
        else try {
          current.startActivity(Intent("android.provider.action.PICK_IMAGES_SETTINGS"))
          result.success(null)
        } catch (_: Exception) { result.error("settingsUnavailable", "System Photo Picker settings are unavailable", null) }
      }
      "status", "diagnose", "enable", "disable" -> {
        if (busy.get() || permissionResult != null) { result.error("busy", "Another cloud media operation is active", null); return }
        if (call.method == "status") { runOperation(call.method, result); return }
        if (Build.VERSION.SDK_INT < 35) { result.error("unsupported", "This pilot requires Android 15 or newer", null); return }
        // Opt-out takes effect even if Shizuku stopped after reboot. Undo stays
        // journaled until shell permission becomes available again.
        if (call.method == "disable") {
          CloudMediaCatalog(requireNotNull(context)).setEnabled(null)
          CloudMediaChanges.changed()
          val journalPending = requireNotNull(context).getSharedPreferences("gallery.cloudmedia", Context.MODE_PRIVATE)
            .contains("recoveryJournal")
          if (!journalPending || !shizukuReady()) { runOperation("status", result); return }
          // If shell is running but permission was revoked, request it below
          // for this explicit recovery. Opt-out has already taken effect.
        }
        if (!shizukuReady()) { result.error("shizukuUnavailable", "Start wireless Shizuku first", null); return }
        if (!hasPermission()) {
          if (activity == null) { result.error("noActivity", "Foreground permission request is required", null); return }
          permissionResult = result; permissionMethod = call.method
          try { Shizuku.requestPermission(REQUEST_CODE) }
          catch (_: Exception) { permissionResult = null; permissionMethod = null; result.error("permissionDenied", "Shizuku permission is unavailable", null) }
        } else runOperation(call.method, result)
      }
      else -> result.notImplemented()
    }
  }

  private fun runOperation(method: String, result: MethodChannel.Result) {
    if (!busy.compareAndSet(false, true)) { result.error("busy", "Another operation is active", null); return }
    cancelled.set(false)
    val ctx = context ?: run { busy.set(false); return }
    worker.submit {
      try {
        val value = if (method == "status") status() else withService(ctx) { remote ->
          val prefs = ctx.getSharedPreferences("gallery.cloudmedia", Context.MODE_PRIVATE)
          val catalog = CloudMediaCatalog(ctx)
          when (method) {
            "enable" -> {
              val session = catalog.session(false) ?: throw IllegalStateException("signedOut")
              val inspected = remote.inspect()
              check(!cancelled.get() && attached) { "cancelled" }
              // Validate feature/enforcement even when our owned override already
              // contains the package and no new privileged write is necessary.
              val journal = CloudAdmissionPolicy.plan(inspected.snapshot(), ctx.packageName, inspected.getString("selectedPackage"))
              val existingJournal = prefs.getString("recoveryJournal", null)?.let { decodeJournal(it) }
              if (existingJournal != null) {
                check(CloudAdmissionPolicy.verifyAdmitted(inspected.snapshot(), existingJournal.written)) { "externallyChanged" }
              } else {
                if (journal != null) {
                  // Durable BEFORE the privileged mutation. Lost Binder reply,
                  // cancellation or process death cannot lose recovery ownership.
                  check(prefs.edit().putString("recoveryJournal", encodeJournal(journal)).commit())
                  check(!cancelled.get() && attached) { "cancelled" }
                  inspected.putString("written", journal.written)
                  remote.admit(inspected)
                }
              }
              check(catalog.session(false)?.scope == session.scope) { "accountChanged" }
              check(!cancelled.get() && attached) { "cancelled" }
              catalog.setEnabled(session)
              CloudMediaChanges.changed()
              status() + mapOf("admitted" to true, "selected" to (inspected.getString("selected") == "${ctx.packageName}.cloudmedia"))
            }
            "disable" -> {
              prefs.getString("recoveryJournal", null)?.let {
                remote.undo(decodeJournal(it).bundle())
                check(prefs.edit().remove("recoveryJournal").commit())
              }
              status()
            }
            else -> {
              val inspected = remote.inspect()
              val ownPackage = ctx.packageName
              val selected = inspected.getString("selected") == "$ownPackage.cloudmedia"
              status() + mapOf("admitted" to (ownPackage in CloudAdmissionPolicy.packages(inspected.getString("effective"))),
                "selected" to selected, "shellUid" to 2000, "androidApi" to Build.VERSION.SDK_INT)
            }
          }
        }
        main.post { if (attached) result.success(value) }
      } catch (e: Exception) {
        // Exception text can contain system/media/private details; expose only
        // fixed reason codes. A journal survives every uncertain outcome.
        val code = when (e.message) { "signedOut", "accountChanged", "externallyChanged", "cancelled" -> e.message!!; else -> "operationFailed" }
        main.post { if (attached) result.error(code, "Cloud provider operation could not be verified; inspect recovery status", null) }
      } finally { busy.set(false) }
    }
  }

  private fun <T> withService(ctx: Context, block: (ICloudAdmission) -> T): T {
    val args = Shizuku.UserServiceArgs(ComponentName(ctx, CloudAdmissionService::class.java))
      .daemon(false).processNameSuffix("cloud-admission").tag("gallery-cloud-admission").version(BuildConfig.VERSION_CODE)
    val connected = CompletableFuture<ICloudAdmission>()
    val connection = object : ServiceConnection {
      override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        binder.linkToDeath({ connected.completeExceptionally(IllegalStateException("Admission binder died")) }, 0)
        connected.complete(ICloudAdmission.Stub.asInterface(binder))
      }
      override fun onServiceDisconnected(name: ComponentName) { connected.completeExceptionally(IllegalStateException("Admission disconnected")) }
    }
    val stopped = AtomicBoolean(false)
    fun stop() {
      if (stopped.compareAndSet(false, true)) {
        connected.completeExceptionally(IllegalStateException("cancelled"))
        runCatching { Shizuku.unbindUserService(args, connection, true) }
      }
    }
    try {
      Shizuku.bindUserService(args, connection)
      stopBinding = ::stop
      if (cancelled.get() || !attached) stop()
      val remote = connected.get(8, TimeUnit.SECONDS)
      service = remote
      // Binder itself has no timeout. A separate deadline cancels the bounded
      // shell process and unbinds if the engine/activity disappears.
      val deadline = Executors.newSingleThreadScheduledExecutor()
      val timer = deadline.schedule({ cancelled.set(true); stop() }, 30, TimeUnit.SECONDS)
      try { return block(remote) } finally { timer.cancel(false); deadline.shutdownNow() }
    } finally {
      service = null
      stopBinding = null
      stop()
    }
  }

  private fun encodeJournal(j: AdmissionJournal): String = JSONObject().apply {
    put("written", j.written)
    put("before", JSONObject().apply {
      put("effective", j.before.effective ?: JSONObject.NULL); put("overridePresent", j.before.overridePresent)
      put("overrideValue", j.before.overrideValue ?: JSONObject.NULL); put("feature", j.before.feature ?: JSONObject.NULL)
      put("enforcement", j.before.enforcement ?: JSONObject.NULL); put("selected", j.before.selected ?: JSONObject.NULL)
      put("androidUser", j.before.androidUser)
    })
  }.toString()

  private fun decodeJournal(raw: String): AdmissionJournal {
    val j = JSONObject(raw); val b = j.getJSONObject("before")
    fun text(key: String) = if (b.isNull(key)) null else b.getString(key)
    return AdmissionJournal(AdmissionSnapshot(text("effective"), b.getBoolean("overridePresent"), text("overrideValue"),
      text("feature"), text("enforcement"), text("selected"), b.getInt("androidUser")), j.getString("written"))
  }

  private companion object { const val REQUEST_CODE = 7236 }
}
