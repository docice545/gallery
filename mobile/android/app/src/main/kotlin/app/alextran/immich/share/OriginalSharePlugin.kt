package app.alextran.immich.share

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

private val ORIGINAL_SHARE_MIME_TYPE = Regex("[a-zA-Z0-9!#$&^_.+\\-]+/[a-zA-Z0-9!#$&^_.+\\-]+")

// A dedicated provider keeps original shares separate from share_plus's eagerly cleared cache.
class OriginalShareFileProvider : FileProvider() {
  override fun getType(uri: Uri): String {
    // Let FileProvider validate the URI against its narrow configured cache path first.
    val inferredType: String? = super.getType(uri)
    val suppliedType = uri.getQueryParameter("mimeType")
    return suppliedType?.takeIf { ORIGINAL_SHARE_MIME_TYPE.matches(it) }
      ?: inferredType
      ?: "application/octet-stream"
  }
}

class OriginalSharePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var activity: Activity? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
    activity = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "shareFiles") {
      result.notImplemented()
      return
    }

    val currentActivity = activity
    val currentContext = context
    if (currentActivity == null || currentContext == null) {
      result.error("NO_ACTIVITY", "A foreground activity is required to share originals.", null)
      return
    }

    val arguments = call.arguments as? Map<*, *>
    val paths = (arguments?.get("paths") as? List<*>)?.map { it as? String ?: "" }
    val mimeTypes = (arguments?.get("mimeTypes") as? List<*>)?.map { it as? String ?: "" }
    val displayNames = (arguments?.get("displayNames") as? List<*>)?.map { it as? String ?: "" }
    if (paths.isNullOrEmpty() || mimeTypes == null || displayNames == null ||
      mimeTypes.size != paths.size || displayNames.size != paths.size ||
      paths.any { it.isBlank() } || mimeTypes.any { !ORIGINAL_SHARE_MIME_TYPE.matches(it) } ||
      displayNames.any { it.isBlank() || it.contains('/') || it.contains('\\') || it.contains('\u0000') }) {
      result.error("INVALID_ARGS", "Matching original paths, MIME types and display names are required.", null)
      return
    }

    currentActivity.runOnUiThread {
      if (activity !== currentActivity || context !== currentContext || currentActivity.isFinishing) {
        result.error("NO_ACTIVITY", "The foreground activity is no longer available.", null)
        return@runOnUiThread
      }

      try {
        val root = File(currentContext.cacheDir, "outgoing_share").canonicalFile
        val rootPrefix = root.path + File.separator
        val files = paths.map { path ->
          File(path).canonicalFile.also { file ->
            require(file.path.startsWith(rootPrefix) && file.isFile && file.canRead()) {
              "Share files must be readable files in the outgoing originals cache."
            }
          }
        }
        val uris = ArrayList(files.mapIndexed { index, file ->
          FileProvider.getUriForFile(
            currentContext,
            "${currentContext.packageName}.original_share",
            file,
            displayNames[index],
          ).buildUpon().appendQueryParameter("mimeType", mimeTypes[index]).build()
        })
        val type = commonMimeType(mimeTypes)
        val clip = ClipData.newUri(currentContext.contentResolver, displayNames.first(), uris.first())
        uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
        val shareIntent = Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
          this.type = type
          if (uris.size == 1) {
            putExtra(Intent.EXTRA_STREAM, uris.first())
          } else {
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
          }
          clipData = clip
          addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(shareIntent, null).apply {
          clipData = clip
          addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        currentActivity.startActivity(chooser)
        // Launch is not proof that a recipient finished reading. Dart retains the session cache.
        result.success(true)
      } catch (_: IllegalArgumentException) {
        result.error("INVALID_FILE", "The original share files are invalid or unavailable.", null)
      } catch (_: Exception) {
        result.error("SHARE_FAILED", "The system share sheet could not be opened.", null)
      }
    }
  }

  private fun commonMimeType(types: List<String>): String {
    if (types.all { it == types.first() }) return types.first()
    val family = types.first().substringBefore('/')
    return if (types.all { it.substringBefore('/') == family }) "$family/*" else "*/*"
  }

  private companion object {
    const val CHANNEL_NAME = "app.alextran.immich/originalShare"
  }
}
