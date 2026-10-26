package app.alextran.immich.localfiles

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.resume
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Shared trash-only operation for explicit user requests and synchronization.
 * MediaStore, not an accepted intent or a plugin's batch callback, is the
 * authority for each returned success.
 *
 * An explicit user request can obtain the foreground system trash grant without
 * MANAGE_MEDIA. Automatic synchronization never prompts when that permission is
 * missing. MANAGE_MEDIA suppresses confirmation but does not grant direct write
 * access; camera-owned rows can still need createTrashRequest in the foreground.
 */
internal class SyncTrashDelegate(context: Context) {
  private val ctx = context.applicationContext
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val main = Handler(Looper.getMainLooper())
  private var activity: Activity? = null
  private var active: Operation? = null
  private var pending: PendingConfirmation? = null
  private var nextRequestCode = 23000

  private class Operation(
    val id: String,
    val assets: List<SyncTrashAsset>,
    val allowUserConfirmation: Boolean,
    val result: MethodChannel.Result,
  ) {
    val outcomes = ConcurrentHashMap<String, Map<String, String>>()
    val delivered = AtomicBoolean(false)
    var job: Job? = null
    var watchdog: Runnable? = null
    @Volatile var cancelledCode: String? = null
  }

  private data class PendingConfirmation(
    val requestCode: Int,
    val continuation: CancellableContinuation<Consent>,
  )

  private data class Consent(val accepted: Boolean, val code: String, val message: String? = null)

  fun attach(activity: Activity) {
    this.activity = activity
  }

  fun detach() {
    activity = null
    active?.let {
      stop(it, "activityDetached", "The Activity detached; the intent remains pending")
    }
    pending?.continuation?.cancel()
    pending = null
  }

  fun dispose() {
    detach()
    scope.coroutineContext[Job]?.cancel()
  }

  fun trash(arguments: Any?, result: MethodChannel.Result) {
    val input = arguments as? Map<*, *>
    val values = input?.get("assets") as? List<*>
    val operationId = input?.get("operationId") as? String
    if (values == null || values.size > 40 || operationId.isNullOrEmpty()) {
      result.error("INVALID_ARGS", "operationId and a list containing at most 40 assets are required", null)
      return
    }
    val assets = try {
      values.map { value ->
        val entry = value as Map<*, *>
        SyncTrashAsset(
          entry["id"] as String,
          (entry["type"] as Number).toInt(),
          entry["name"] as String,
          (entry["createdAt"] as Number).toLong(),
          (entry["updatedAt"] as Number).toLong(),
        )
      }.distinctBy { it.id }
    } catch (error: Exception) {
      result.error("INVALID_ARGS", "Each asset needs its current ID, type, name and timestamps", error.javaClass.simpleName)
      return
    }
    if (active != null) {
      result.success(assets.associate { it.id to outcome("busy", "Another synchronized trash operation is active") })
      return
    }
    val op = Operation(operationId, assets, input?.get("allowUserConfirmation") == true, result)
    active = op
    op.watchdog = Runnable {
      // A coroutine timeout alone cannot release Flutter while a synchronous
      // provider Binder call is blocked. This independent Main watchdog can.
      stop(op, "timeout", "MediaStore did not finish within 60 seconds; the intent remains pending")
    }.also { main.postDelayed(it, 60_000) }
    op.job = scope.launch {
      try {
        withTimeout(60_000) { execute(op) }
      } catch (error: TimeoutCancellationException) {
        completeRemaining(op, "timeout", "MediaStore did not finish within 60 seconds; the intent remains pending")
      } catch (error: CancellationException) {
        completeRemaining(op, op.cancelledCode ?: "cancelled", "The native operation was detached or cancelled")
      } catch (error: Exception) {
        completeRemaining(op, "providerError", describe(error))
      } finally {
        withContext(NonCancellable + Dispatchers.Main) {
          pending?.continuation?.cancel()
          pending = null
          if (active === op) active = null
          deliver(op)
        }
      }
    }
  }

  fun cancel(arguments: Any?, result: MethodChannel.Result) {
    val requestedId = (arguments as? Map<*, *>)?.get("operationId") as? String
    val op = active
    if (op == null || requestedId != op.id) {
      result.success(false)
      return
    }
    stop(op, "cancelled", "The owning synchronization task was cancelled")
    result.success(true)
  }

  /** Main-thread callback completion never waits for a blocked provider call. */
  private fun stop(op: Operation, code: String, message: String) {
    op.cancelledCode = code
    op.job?.cancel()
    pending?.continuation?.cancel()
    pending = null
    completeRemaining(op, code, message)
    deliver(op)
    // Keep [active] until the worker actually unwinds. A stuck provider must
    // not permit overlapping mutations from a replacement task.
  }

  private fun deliver(op: Operation) {
    op.watchdog?.let(main::removeCallbacks)
    if (!op.delivered.compareAndSet(false, true)) return
    val snapshot = op.assets.associate { asset ->
      val actual = op.outcomes[asset.id] ?: outcome("cancelled", "The operation ended before this asset was verified")
      asset.id to (actual + ("message" to listOfNotNull(
        "sdk=${Build.VERSION.SDK_INT} mode=${if (op.allowUserConfirmation) "user" else "sync"}",
        actual["message"],
      ).joinToString("; ")))
    }
    op.result.success(snapshot)
  }

  private suspend fun execute(op: Operation) {
    if (!SyncTrashPolicy.supportsTrash(Build.VERSION.SDK_INT, op.allowUserConfirmation)) {
      completeRemaining(op, "unsupported", "System Trash requires Android API 30 for a user request or API 31 for automatic synchronization")
      return
    }
    if (op.allowUserConfirmation && !withContext(Dispatchers.Main) { isForegroundActivity() }) {
      completeRemaining(op, "noActivity", "An explicit user trash request needs a resumed Activity before any MediaStore write")
      return
    }
    val needsConsent = mutableListOf<SyncTrashAsset>()
    val requestReasons = mutableMapOf<String, String>()
    for (asset in op.assets) {
      coroutineContext.ensureActive()
      if (!Regex("^[1-9][0-9]*$").matches(asset.id) || asset.id.toLongOrNull() == null || asset.type !in 1..3) {
        op.outcomes[asset.id] = outcome("invalidId", "A valid numeric image, video or audio MediaStore ID is required")
        continue
      }
      try {
        permissionFailure(asset, op.allowUserConfirmation)?.let { op.outcomes[asset.id] = it } ?: run {
          val current = snapshot(asset)
          val before = SyncTrashPolicy.beforeWrite(asset, current)
          if (before != null) {
            op.outcomes[asset.id] = outcome(before, SyncTrashPolicy.identityDiagnostic(asset, current))
          } else {
            coroutineContext.ensureActive()
            // Recheck permissions immediately before mutating the media row.
            val denied = permissionFailure(asset, op.allowUserConfirmation)
            if (denied != null) {
              op.outcomes[asset.id] = denied
            } else if (op.allowUserConfirmation && !canManageMedia()) {
              // MANAGE_MEDIA is optional for an explicit foreground action.
              // Obtain Android's trash-only grant instead of silently denying
              // the whole selection or attempting an unapproved direct write.
              requestReasons[asset.id] = "MANAGE_MEDIA=false; explicit system consent required"
              needsConsent.add(asset)
            } else {
              coroutineContext.ensureActive()
              try {
                val changed = ctx.contentResolver.update(uri(asset), ContentValues().apply {
                  put(MediaStore.MediaColumns.IS_TRASHED, 1)
                }, null, null)
                val after = verifiedOutcome(asset, op.allowUserConfirmation, "notTrashed",
                  "phase=directWrite rowsChanged=$changed manageMedia=${canManageMedia()}")
                if (after["code"] == "notTrashed") {
                  // Some providers return zero instead of throwing when a
                  // camera-owned row needs a scoped system write grant.
                  requestReasons[asset.id] = "${after["message"]}; MediaStore update did not mark the row as trashed"
                  needsConsent.add(asset)
                } else {
                  op.outcomes[asset.id] = after
                }
              } catch (error: SecurityException) {
                // This includes RecoverableSecurityException for camera-owned
                // media. The proper system trash request, not deletion, grants
                // this operation. Permission loss is rechecked before launching.
                requestReasons[asset.id] = describe(error)
                needsConsent.add(asset)
              }
            }
          }
        }
      } catch (error: CancellationException) {
        throw error
      } catch (error: SecurityException) {
        op.outcomes[asset.id] = outcome("permissionDenied", describe(error))
      } catch (error: Exception) {
        op.outcomes[asset.id] = outcome("providerError", describe(error))
      }
    }

    val eligible = mutableListOf<SyncTrashAsset>()
    for (asset in needsConsent) {
      coroutineContext.ensureActive()
      try {
        val denied = permissionFailure(asset, op.allowUserConfirmation)
        val state = if (denied == null) SyncTrashPolicy.beforeWrite(asset, snapshot(asset)) else null
        when {
          denied != null -> op.outcomes[asset.id] = denied
          state != null -> op.outcomes[asset.id] = outcome(state)
          else -> eligible.add(asset)
        }
      } catch (error: CancellationException) {
        throw error
      } catch (error: SecurityException) {
        op.outcomes[asset.id] = outcome("permissionDenied", describe(error))
      } catch (error: Exception) {
        op.outcomes[asset.id] = outcome("providerError", describe(error))
      }
    }
    if (eligible.isEmpty()) return

    val consent = requestTrash(eligible, op.allowUserConfirmation)
    for (asset in eligible) {
      coroutineContext.ensureActive()
      try {
        // Cancellation, partial success and provider races are determined from
        // the current row, never from RESULT_OK or a list of requested IDs.
        val explanation = listOfNotNull(
          "phase=systemConsent accepted=${consent.accepted} manageMedia=${canManageMedia()}",
          consent.message, requestReasons[asset.id],
        ).joinToString("; ")
        op.outcomes[asset.id] = verifiedOutcome(asset, op.allowUserConfirmation,
          if (consent.accepted) "notTrashed" else consent.code, explanation)
      } catch (error: CancellationException) {
        throw error
      } catch (error: SecurityException) {
        op.outcomes[asset.id] = outcome("permissionDenied", describe(error))
      } catch (error: Exception) {
        op.outcomes[asset.id] = outcome("providerError", describe(error))
      }
    }
  }

  private suspend fun requestTrash(assets: List<SyncTrashAsset>, allowUserConfirmation: Boolean): Consent {
    // MediaStore permission checks and request creation are synchronous provider
    // calls too. Keep them off Main so the independent watchdog remains live.
    val denied = assets.firstNotNullOfOrNull { permissionFailure(it, allowUserConfirmation) }
    if (denied != null) return Consent(false, "permissionDenied", denied["message"])
    if (!withContext(Dispatchers.Main) { isForegroundActivity() }) {
      return Consent(false, "noActivity", "A foreground Activity is required for Android's system trash request")
    }
    val intent = try {
      MediaStore.createTrashRequest(ctx.contentResolver, assets.map(::uri), true)
    } catch (error: Exception) {
      return Consent(false, if (error is SecurityException) "permissionDenied" else "providerError", describe(error))
    }
    coroutineContext.ensureActive()
    return withContext(Dispatchers.Main) {
      val current = activity
      if (current == null || !isForegroundActivity()) {
        return@withContext Consent(false, "noActivity", "The attached Activity is no longer in the foreground")
      }
      if (pending != null) return@withContext Consent(false, "busy", "A system trash request is already pending")
      suspendCancellableCoroutine { continuation ->
        val code = nextRequestCode++
        if (nextRequestCode > 60000) nextRequestCode = 23000
        pending = PendingConfirmation(code, continuation)
        continuation.invokeOnCancellation {
          scope.launch(Dispatchers.Main) {
            if (pending?.continuation === continuation) pending = null
          }
        }
        try {
          current.startIntentSenderForResult(intent.intentSender, code, null, 0, 0, 0)
        } catch (error: Exception) {
          pending = null
          if (continuation.isActive) continuation.resume(Consent(false,
            if (error is SecurityException) "permissionDenied" else "providerError", describe(error)))
        }
      }
    }
  }

  /** Main-thread lifecycle check contains no MediaStore or permission Binder call. */
  private fun isForegroundActivity(): Boolean {
    val current = activity ?: return false
    if (current.isFinishing || current.isDestroyed) return false
    return (current as? LifecycleOwner)?.lifecycle?.currentState
      ?.isAtLeast(Lifecycle.State.RESUMED) ?: current.hasWindowFocus()
  }

  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    val request = pending ?: return false
    if (request.requestCode != requestCode) return false
    pending = null
    if (request.continuation.isActive) {
      request.continuation.resume(if (resultCode == Activity.RESULT_OK) {
        Consent(true, "accepted", "systemResult=RESULT_OK; MediaStore verification follows")
      } else {
        Consent(false, "cancelled", "systemResult=$resultCode; Android rejected or cancelled the system trash request")
      })
    }
    return true
  }

  private fun verifiedOutcome(
    asset: SyncTrashAsset,
    allowUserConfirmation: Boolean,
    failureCode: String,
    message: String? = null,
  ): Map<String, String> {
    permissionFailure(asset, allowUserConfirmation)?.let { return it }
    val actual = snapshot(asset)
      ?: return outcome("missing", "phase=verification: the media row disappeared; $message")
    val state = SyncTrashPolicy.beforeWrite(asset, actual)
    if (state == "assetChanged") return outcome(state, SyncTrashPolicy.identityDiagnostic(asset, actual))
    return if (actual.isTrashed) outcome("trashed", message) else outcome(failureCode, message)
  }

  private fun canManageMedia(): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && MediaStore.canManageMedia(ctx)

  private fun permissionFailure(asset: SyncTrashAsset, allowUserConfirmation: Boolean): Map<String, String>? {
    if (!SyncTrashPolicy.mayRequestTrash(allowUserConfirmation, canManageMedia())) {
      return outcome("permissionDenied", "MANAGE_MEDIA is not granted; automatic synchronization cannot request user consent")
    }
    val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      when (asset.type) {
        1 -> Manifest.permission.READ_MEDIA_IMAGES
        2 -> Manifest.permission.READ_MEDIA_VIDEO
        else -> Manifest.permission.READ_MEDIA_AUDIO
      }
    } else Manifest.permission.READ_EXTERNAL_STORAGE
    return if (ctx.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
      outcome("permissionDenied", "Full $permission is not granted; current media identity cannot be verified (selected-only access may be active)")
    } else null
  }

  private fun snapshot(asset: SyncTrashAsset): SyncTrashSnapshot? {
    val columns = mutableListOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.DATE_ADDED,
      MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.IS_TRASHED)
    if (asset.type != 3) columns.add(MediaStore.MediaColumns.DATE_TAKEN)
    val args = Bundle().apply { putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE) }
    val cursor = ctx.contentResolver.query(uri(asset), columns.toTypedArray(), args, null)
      ?: throw IllegalStateException("MediaStore returned a null cursor")
    return cursor.use {
      if (!it.moveToFirst()) return@use null
      val taken = if (asset.type != 3) it.getLong(4) else 0L
      SyncTrashSnapshot(asset.type, it.getString(0), if (taken > 0) taken / 1000 else it.getLong(1),
        it.getLong(2), it.getInt(3) != 0)
    }
  }

  private fun uri(asset: SyncTrashAsset): Uri = ContentUris.withAppendedId(when (asset.type) {
    1 -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    2 -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
    else -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
  }, asset.id.toLong())

  private fun completeRemaining(op: Operation, code: String, message: String) {
    for (asset in op.assets) op.outcomes.putIfAbsent(asset.id, outcome(code, message))
  }

  private fun outcome(code: String, message: String? = null): Map<String, String> =
    if (message == null) mapOf("code" to code) else mapOf("code" to code, "message" to message)

  private fun describe(error: Exception): String {
    // Provider messages can include storage paths or content URIs. Keep the
    // exception class/reason while excluding original file locations from logs.
    val detail = (error.message ?: "No provider details")
      .replace(Regex("(?:content|file)://[^\\s;]+"), "<media-uri>")
      .replace(Regex("/(?:storage|data|mnt)/[^\\s;]+"), "<media-path>")
    return "${error.javaClass.simpleName}: $detail"
  }
}
