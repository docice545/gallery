package app.alextran.immich.images

import java.io.IOException
import java.net.URI

/** HTTP failures retain their status without exposing authentication or URL queries. */
internal class RemoteImageHttpError(
  val statusCode: Int,
  requestUrl: String,
  finalUrl: String,
) : IOException("Remote image request failed (HTTP $statusCode)") {
  val requestPath: String = pathOnly(requestUrl)
  val finalPath: String = pathOnly(finalUrl)
  val mediaSize: String? = allowedQueryValue(requestUrl, "size", setOf("thumbnail", "preview", "fullsize", "original"))
  val edited: Boolean? = when (allowedQueryValue(requestUrl, "edited", setOf("true", "false"))) {
    "true" -> true
    "false" -> false
    else -> null
  }

  fun details(requestId: Long): Map<String, Any> = buildMap {
    put("statusCode", statusCode)
    put("requestPath", requestPath)
    put("finalPath", finalPath)
    put("requestId", requestId)
    mediaSize?.let { put("mediaSize", it) }
    edited?.let { put("edited", it) }
  }

  companion object {
    private fun allowedQueryValue(url: String, name: String, allowed: Set<String>): String? = try {
      URI(url).rawQuery?.split('&')?.firstOrNull { it.substringBefore('=') == name }
        ?.substringAfter('=', "")?.takeIf { it in allowed }
    } catch (_: Exception) {
      null
    }

    private fun pathOnly(url: String): String = try {
      val path = URI(url).rawPath
      when {
        path.isNullOrEmpty() -> "/"
        !path.startsWith('/') -> "<invalid-path>"
        else -> path.take(2048)
      }
    } catch (_: Exception) {
      "<invalid-path>"
    }
  }
}
