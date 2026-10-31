package app.alextran.immich.cloudmedia

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

internal class CloudReaderFailure(val code: String, val sqliteCode: Int? = null) : IllegalStateException(code)

/** Logical native readers use an admitted Flutter pool, never Android SQLite's
 * independent library/locking state on the same live WAL/SHM in this process. */
internal object CloudSqliteReaders {
  val pickerQueries = AtomicLong()
  val pickerRows = AtomicLong()
  private val main = Handler(Looper.getMainLooper())
  private val readers = linkedMapOf<Any, MethodChannel>()
  private val capacity = Semaphore(4)
  @Synchronized fun ready(owner: Any, channel: MethodChannel) { readers[owner] = channel }
  @Synchronized fun close(owner: Any) { readers.remove(owner) }
  @Synchronized fun available(): Boolean = readers.isNotEmpty()
  @Synchronized private fun reader(): MethodChannel? = readers.values.lastOrNull()

  private fun request(arguments: Map<String, Any?>, cancellation: CancellationSignal? = null): Any? {
    check(Looper.myLooper() != Looper.getMainLooper()) { "cloud_reader_main_thread" }
    val channel = reader() ?: throw CloudReaderFailure("cloud_reader_unavailable")
    if (!capacity.tryAcquire()) throw CloudReaderFailure("cloud_reader_busy")
    val result = CompletableFuture<Any?>()
    cancellation?.setOnCancelListener { result.completeExceptionally(CloudReaderFailure("cloud_reader_cancelled")) }
    try {
      cancellation?.throwIfCanceled()
      main.post {
        channel.invokeMethod("read", arguments, object : MethodChannel.Result {
          override fun success(value: Any?) { result.complete(value) }
          override fun error(code: String, message: String?, details: Any?) {
            val sqliteCode = ((details as? Map<*, *>)?.get("sqliteCode") as? Number)?.toInt()
            result.completeExceptionally(CloudReaderFailure(code, sqliteCode))
          }
          override fun notImplemented() { result.completeExceptionally(CloudReaderFailure("cloud_reader_unavailable")) }
        })
      }
      return try { result.get(30, TimeUnit.SECONDS) }
      catch (e: ExecutionException) { throw (e.cause as? CloudReaderFailure ?: CloudReaderFailure("cloud_reader_unavailable")) }
      catch (_: java.util.concurrent.TimeoutException) { throw CloudReaderFailure("cloud_reader_timeout") }
    } finally {
      // The owning Dart pool drains a timed-out callback before closing its lease.
      if (cancellation?.isCanceled != true) cancellation?.setOnCancelListener(null)
      capacity.release()
    }
  }

  fun query(sql: String, args: Array<String>, cancellation: CancellationSignal? = null): Cursor {
    val value = request(mapOf("operation" to "query", "sql" to sql, "args" to args.toList()), cancellation) as Map<*, *>
    val columns = (value["columns"] as List<*>).map { it as String }.toTypedArray()
    return MatrixCursor(columns).also { cursor ->
      (value["rows"] as List<*>).forEach { cursor.addRow((it as List<*>).toTypedArray()) }
    }
  }

  fun digest(scope: String, queries: List<Map<String, Any>>): String =
    request(mapOf("operation" to "digest", "scope" to scope, "queries" to queries)) as String
}

class CloudSqliteBridgePlugin : FlutterPlugin {
  private lateinit var channel: MethodChannel
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "foto/cloud_sqlite_reader")
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "ready" -> {
          CloudSqliteReaders.ready(this, channel)
          CloudMediaChanges.start(binding.applicationContext); CloudMediaChanges.changed()
          result.success(null)
        }
        "closing" -> { CloudSqliteReaders.close(this); result.success(null) }
        else -> result.notImplemented()
      }
    }
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    CloudSqliteReaders.close(this)
    channel.setMethodCallHandler(null)
  }
}
