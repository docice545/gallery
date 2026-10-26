package app.alextran.immich.places

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** Foreground, read-only localized place lookup using the device's geodata provider. */
class PlaceNamesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var context: Context? = null
  private val handler = Handler(Looper.getMainLooper())
  private var worker = Executors.newSingleThreadExecutor()
  private var pending: Lookup? = null
  private var providerBusy = false
  // A timed-out legacy synchronous lookup may still be inside the OS service.
  // Do not queue more work behind it, even when interruption is unsupported.
  @Volatile private var legacyBusy = false

  private class Lookup(val result: MethodChannel.Result) {
    var timeout: Runnable? = null
    var task: Future<*>? = null
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    if (worker.isShutdown) worker = Executors.newSingleThreadExecutor()
    channel = MethodChannel(binding.binaryMessenger, "de.opennoodle.gallery/place_names").also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    pending?.let { finish(it, error = "GEOCODER_DETACHED") }
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
    worker.shutdownNow()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "localizePlace") {
      result.notImplemented()
      return
    }
    val ctx = context
    val args = call.arguments as? Map<*, *>
    val city = (args?.get("city") as? String)?.trim()
    val latitude = (args?.get("latitude") as? Number)?.toDouble()
    val longitude = (args?.get("longitude") as? Number)?.toDouble()
    val languageTag = args?.get("languageTag") as? String
    if (ctx == null || city.isNullOrEmpty() || city.length > 200 || city.any(Char::isISOControl) ||
      latitude == null || longitude == null || !PlaceNamePolicy.validCoordinates(latitude, longitude) ||
      languageTag == null || !Regex("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$").matches(languageTag)) {
      result.error("INVALID_PLACE", "A place, valid coordinates and language tag are required.", null)
      return
    }
    if (!Geocoder.isPresent()) {
      result.error("GEOCODER_UNAVAILABLE", "The device has no geodata provider.", null)
      return
    }
    if (pending != null || providerBusy || legacyBusy) {
      result.error("GEOCODER_BUSY", "A place lookup is already in progress.", null)
      return
    }
    val qualifiers = listOf("state", "country").mapNotNull { key ->
      (args?.get(key) as? String)?.trim()?.takeIf { it.isNotEmpty() && it.length <= 200 && it.none(Char::isISOControl) }
    }
    val queries = PlaceNamePolicy.queries(city, qualifiers)
    val operation = Lookup(result)
    pending = operation
    operation.timeout = Runnable {
      finish(operation, error = "GEOCODER_TIMEOUT")
      // Geocoder has no cancellation API. Keep its slot occupied until the
      // callback/legacy call returns, rather than accumulating timed-out calls.
    }.also { handler.postDelayed(it, 3500) }
    val south = (latitude - 0.5).coerceAtLeast(-90.0)
    val north = (latitude + 0.5).coerceAtMost(90.0)
    val crossesDateLine = longitude - 0.5 < -180 || longitude + 0.5 > 180
    val west = if (crossesDateLine) -180.0 else longitude - 0.5
    val east = if (crossesDateLine) 180.0 else longitude + 0.5
    try {
      val geocoder = Geocoder(ctx, Locale.forLanguageTag(languageTag))
      if (Build.VERSION.SDK_INT >= 33) {
        fun lookup(index: Int) {
          if (pending !== operation) return
          providerBusy = true
          geocoder.getFromLocationName(queries[index], 3, south, west, north, east, object : Geocoder.GeocodeListener {
            override fun onGeocode(addresses: MutableList<Address>) {
              handler.post {
                providerBusy = false
                if (pending !== operation) return@post
                val label = resolve(latitude, longitude, addresses)?.takeIf { PlaceNamePolicy.acceptsLocale(it, languageTag) }
                if (label == null && index + 1 < queries.size) {
                  try { lookup(index + 1) }
                  catch (_: Exception) {
                    providerBusy = false
                    finish(operation, error = "GEOCODER_FAILED")
                  }
                } else if (label == null) finish(operation, error = "GEOCODER_NO_MATCH")
                else finish(operation, label)
              }
            }

            override fun onError(errorMessage: String?) {
              // Provider error text can contain the query/coordinates. Keep it off logs.
              handler.post {
                providerBusy = false
                finish(operation, error = "GEOCODER_FAILED")
              }
            }
          })
        }
        lookup(0)
      } else {
        legacyBusy = true
        val deadline = SystemClock.elapsedRealtime() + 3000
        operation.task = worker.submit {
          try {
            var label: String? = null
            for (query in queries) {
              if (Thread.currentThread().isInterrupted || SystemClock.elapsedRealtime() >= deadline) break
              @Suppress("DEPRECATION")
              val addresses = geocoder.getFromLocationName(query, 3, south, west, north, east).orEmpty()
              label = resolve(latitude, longitude, addresses)?.takeIf { PlaceNamePolicy.acceptsLocale(it, languageTag) }
              if (label != null) break
            }
            handler.post {
              if (label == null) finish(operation, error = "GEOCODER_NO_MATCH")
              else finish(operation, label)
            }
          } catch (_: Exception) {
            handler.post { finish(operation, error = "GEOCODER_FAILED") }
          } finally {
            legacyBusy = false
          }
        }
      }
    } catch (_: Exception) {
      providerBusy = false
      legacyBusy = false
      finish(operation, error = "GEOCODER_FAILED")
    }
  }

  private fun resolve(latitude: Double, longitude: Double, addresses: List<Address>): String? =
    PlaceNamePolicy.resolve(latitude, longitude, addresses.filter { it.hasLatitude() && it.hasLongitude() }.map {
      PlaceNameCandidate(it.latitude, it.longitude, it.featureName, it.locality, it.subLocality,
        it.adminArea, it.countryName, it.thoroughfare)
    })

  private fun finish(operation: Lookup, name: String? = null, error: String? = null) {
    if (pending !== operation) return
    pending = null
    operation.timeout?.let(handler::removeCallbacks)
    if (error == null) operation.result.success(name)
    else operation.result.error(error, "Localized place lookup is unavailable; retain the original name.", null)
  }
}
