package app.alextran.immich.images

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.IOException

class RemoteImageHttpErrorTest {
  @Test fun `404 retains status and safe request metadata`() {
    val error = RemoteImageHttpError(404,
      "https://user:password@example.test/api/assets/stale/thumbnail?size=preview&edited=false&key=secret#fragment",
      "https://cdn-user:cdn-password@cdn.example.test/files/missing.jpg?signature=private#private")
    assertEquals(404, error.statusCode)
    assertEquals("/api/assets/stale/thumbnail", error.requestPath)
    assertEquals("/files/missing.jpg", error.finalPath)
    assertEquals(42L, error.details(42L)["requestId"])
    assertEquals("preview", error.details(42L)["mediaSize"])
    assertEquals(false, error.details(42L)["edited"])
    val diagnostic = error.toString() + error.details(42L).toString()
    for (secret in listOf("password", "example.test", "secret", "signature", "private", "fragment")) {
      assertFalse("Must not disclose $secret", diagnostic.contains(secret))
    }
  }

  @Test fun `only validated media selection parameters enter diagnostics`() {
    val error = RemoteImageHttpError(404, "/thumbnail?size=secret&edited=private&token=private", "/thumbnail")
    assertFalse(error.details(1L).containsKey("mediaSize"))
    assertFalse(error.details(1L).containsKey("edited"))
    assertFalse(error.details(1L).toString().contains("private"))
  }

  @Test fun `authentication server and other HTTP failures keep their exact status`() {
    for (status in listOf(400, 401, 403, 410, 429, 500, 503)) {
      val error = RemoteImageHttpError(status, "/api/assets/id/original", "/api/assets/id/original")
      assertEquals(status, error.details(1L)["statusCode"])
      assertEquals("Remote image request failed (HTTP $status)", error.message)
    }
  }

  @Test fun `missing URL path is represented without the origin`() {
    val error = RemoteImageHttpError(404, "https://user:secret@example.test?key=secret", "https://example.test")
    assertEquals("/", error.requestPath)
    assertEquals("/", error.finalPath)
  }

  @Test fun `malformed URL diagnostics do not echo the input`() {
    val error = RemoteImageHttpError(404, "https://user:secret@bad host/path?key=secret", "invalid-secret")
    assertEquals("<invalid-path>", error.requestPath)
    assertEquals("<invalid-path>", error.finalPath)
    assertFalse(error.details(0).toString().contains("secret"))
  }

  @Test fun `diagnostic paths are bounded`() {
    val error = RemoteImageHttpError(404, "https://example.test/" + "x".repeat(5000), "/original")
    assertEquals(2048, error.requestPath.length)
  }

  @Test fun `HTTP error remains an IOException without embedding full URL`() {
    val error: IOException = RemoteImageHttpError(404, "https://example.test/path?key=private", "/path")
    assertEquals("Remote image request failed (HTTP 404)", error.message)
  }

  @Test fun `real unexpected 404 preserves request path and status`() {
    val server = MockWebServer()
    try {
      server.enqueue(MockResponse().setResponseCode(404).setBody("Asset media not found"))
      server.start()
      val request = Request.Builder().url(server.url("/api/assets/id/thumbnail?size=preview&key=secret")).build()
      OkHttpClient().newCall(request).execute().use { response ->
        val error = RemoteImageHttpError(response.code, request.url.toString(), response.request.url.toString())
        assertEquals(404, error.statusCode)
        assertEquals("/api/assets/id/thumbnail", error.requestPath)
        assertEquals(error.requestPath, error.finalPath)
        assertFalse(error.details(7L).toString().contains("secret"))
      }
    } finally {
      server.shutdown()
    }
  }

  @Test fun `redirected 404 distinguishes requested derivative from final original`() {
    val server = MockWebServer()
    try {
      server.start()
      server.enqueue(MockResponse().setResponseCode(302)
        .setHeader("Location", server.url("/api/assets/id/original?key=redirect-secret")))
      server.enqueue(MockResponse().setResponseCode(404))
      val request = Request.Builder().url(server.url("/api/assets/id/thumbnail?size=fullsize")).build()
      OkHttpClient().newCall(request).execute().use { response ->
        val error = RemoteImageHttpError(response.code, request.url.toString(), response.request.url.toString())
        assertEquals(404, error.statusCode)
        assertEquals("/api/assets/id/thumbnail", error.requestPath)
        assertEquals("/api/assets/id/original", error.finalPath)
        assertFalse(error.details(8L).toString().contains("redirect-secret"))
        assertEquals(2, server.requestCount)
      }
    } finally {
      server.shutdown()
    }
  }
}
