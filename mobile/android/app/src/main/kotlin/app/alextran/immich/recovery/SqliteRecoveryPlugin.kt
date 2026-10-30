package app.alextran.immich.recovery

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.Executors

class SqliteRecoveryPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
  private lateinit var ctx: Context
  private lateinit var channel: MethodChannel
  private var binding: ActivityPluginBinding? = null
  private var exportResult: MethodChannel.Result? = null
  companion object {
    private var owner: RecoveryStore? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Synchronized internal fun store(ctx: Context): RecoveryStore = owner ?: RecoveryStore(
      File(ctx.noBackupFilesDir, "sqlite-recovery"), File(ctx.getDir("flutter", 0), "immich.sqlite"),
    ) { directory ->
      check(directory.isDirectory)
      // O_DIRECTORY is not exposed by the public Android OsConstants API.
      // Opening an existing directory read-only gives the descriptor for fsync.
      val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
      try { Os.fsync(fd) } finally { Os.close(fd) }
    }.also { owner = it }
  }
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    ctx = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "foto/sqlite_recovery")
    channel.setMethodCallHandler { call, result ->
      if (call.method == "export") {
        try {
          check(store(ctx).canExport() && exportResult == null)
          val activity = checkNotNull(this.binding?.activity)
          exportResult = result
          activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            putExtra(Intent.EXTRA_TITLE, "FOTO-SQLite-backup.zip")
          }, 23023)
        } catch (_: Exception) { exportResult = null; result.error("export_unavailable", "Export unavailable", null) }
      } else executor.execute {
        try {
          val store = store(ctx)
          val value: Any? = when (call.method) {
            "acquire" -> store.acquire()
            "probeComplete" -> {
              store.probeComplete(call.argument<String>("token")!!)
              app.alextran.immich.cloudmedia.CloudMediaChanges.start(ctx)
              app.alextran.immich.cloudmedia.CloudMediaChanges.changed()
              null
            }
            "release" -> { store.release(call.argument<String>("token")!!); null }
            "halt" -> { store.halt(); null }
            "begin" -> store.begin()
            "finish" -> { store.finish(call.argument<String>("token")!!); null }
            "path" -> store.selected().path
            "space" -> StatFs(store.root.path).availableBytes
            "sync" -> { store.syncTree(File(call.argument<String>("path")!!)); null }
            "promote" -> { store.promote(call.argument<String>("token")!!, call.argument<String>("path")!!, call.argument<String>("hash")!!); null }
            else -> throw IllegalArgumentException("unknown method")
          }
          main.post { result.success(value) }
        } catch (_: Exception) { main.post { result.error("sqlite_recovery_required", "SQLite admission or durability check failed", null) } }
      }
    }
  }
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != 23023) return false
    val result = exportResult ?: return true
    exportResult = null
    val uri = data?.data
    if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return true }
    executor.execute {
      try {
        val store = store(ctx)
        check(store.canExport())
        ctx.contentResolver.openOutputStream(uri, "wt").use { raw ->
          RecoveryExport.write(store, checkNotNull(raw))
        }
        main.post { result.success(true) }
      } catch (_: Exception) { main.post { result.error("export_failed", "Export failed; internal originals retained", null) } }
    }
    return true
  }
  override fun onAttachedToActivity(binding: ActivityPluginBinding) { this.binding = binding; binding.addActivityResultListener(this) }
  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
  override fun onDetachedFromActivity() { binding?.removeActivityResultListener(this); binding = null }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { channel.setMethodCallHandler(null) }
}
