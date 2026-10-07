package app.alextran.immich.cloudmedia

import android.content.Context
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.HandlerThread
import android.provider.MediaStore
import io.flutter.util.PathUtils
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/** One native observer over the existing DB/WAL, not a second sync client. */
internal object CloudMediaChanges {
  val revision = AtomicLong()
  private var context: Context? = null
  private var observer: FileObserver? = null
  private val thread by lazy { HandlerThread("gallery-cloud-notify").apply { start() } }
  private val handler by lazy { Handler(thread.looper) }
  private val notify = Runnable {
    val ctx = context ?: return@Runnable
    if (Build.VERSION.SDK_INT >= 35) {
      // Collection ID + canonical query changes, including logout, force picker
      // resync. No account/media identifiers or credentials are logged.
      runCatching { MediaStore.notifyCloudMediaChangedEvent(ctx.contentResolver, "${ctx.packageName}.cloudmedia") }
    }
  }

  @Synchronized fun start(ctx: Context) {
    if (Build.VERSION.SDK_INT < 35 || observer != null) return
    context = ctx.applicationContext
    observer = object : FileObserver(File(PathUtils.getDataDirectory(ctx)), MODIFY or CLOSE_WRITE or DELETE or MOVED_TO) {
      override fun onEvent(event: Int, path: String?) {
        if (path == "immich.sqlite" || path == "immich.sqlite-wal") changed()
      }
    }.apply { startWatching() }
  }

  fun changed() {
    revision.incrementAndGet()
    handler.removeCallbacks(notify)
    handler.postDelayed(notify, 500)
  }
}
