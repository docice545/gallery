package app.alextran.immich.cloudmedia

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CloudRangeReaderTest {
  private lateinit var server: MockWebServer
  private val total = 50L * 1024 * 1024 * 1024 // No 50GiB buffer/file is allocated.
  @Before fun setup() {
    server = MockWebServer()
    server.dispatcher = object : Dispatcher() {
      override fun dispatch(request: RecordedRequest): MockResponse {
        val range = Regex("bytes=(\\d+)-(\\d+)").matchEntire(request.getHeader("Range")!!)!!
        val start = range.groupValues[1].toLong(); val end = range.groupValues[2].toLong()
        val bytes = ByteArray((end - start + 1).toInt()) { ((start + it) % 251).toByte() }
        return MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes $start-$end/$total")
          .setHeader("ETag", "stable").setBody(Buffer().write(bytes))
      }
    }
    server.start()
  }
  @After fun cleanup() { server.shutdown() }
  private fun reader(access: () -> Unit = {}) = CloudRangeReader(OkHttpClient(),
    { Request.Builder().url(server.url("/original")) }, access)

  @Test fun seekAndCacheRemainBoundedForHugeVideo() {
    reader().use { r ->
      assertEquals(total, r.size())
      val bytes = ByteArray(32000)
      val offset = total - 64000
      assertEquals(bytes.size, r.read(offset, bytes.size, bytes))
      assertArrayEquals(ByteArray(bytes.size) { ((offset + it) % 251).toByte() }, bytes)
      val count = server.requestCount
      r.read(offset, bytes.size, bytes)
      assertEquals(count, server.requestCount)
      assertEquals(0, r.read(total, 100, bytes))
    }
  }
  @Test fun metadataAndRangeRequestsDoNotDownloadWholeOriginal() {
    reader().use { r ->
      r.read(700000, 100, ByteArray(100))
      assertEquals("bytes=0-0", server.takeRequest().getHeader("Range"))
      assertEquals("bytes=524288-1048575", server.takeRequest().getHeader("Range"))
      assertEquals(2, server.requestCount)
    }
  }
  @Test fun accessIsRecheckedForCachedBytesAfterLogoutOrTrash() {
    val visible = AtomicBoolean(true)
    reader { if (!visible.get()) throw SecurityException("inactive") }.use { r ->
      r.read(0, 10, ByteArray(10)); visible.set(false)
      assertThrows(SecurityException::class.java) { r.read(0, 10, ByteArray(10)) }
    }
  }
  @Test fun authenticationFailureIsAnError() {
    server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(401) }
    reader().use { assertThrows(IOException::class.java) { it.size() } }
  }
  @Test fun mismatchedRangesFailClosed() {
    server.dispatcher = object : Dispatcher() {
      override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(206)
        .setHeader("Content-Range", "bytes 10-10/100").setBody("x")
    }
    reader().use { assertThrows(IOException::class.java) { it.size() } }
  }
  @Test fun changedOriginalEtagFailsBeforeReturningBytes() {
    reader().use { r ->
      r.size()
      server.dispatcher = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(206)
          .setHeader("Content-Range", "bytes 0-524287/$total").setHeader("ETag", "changed")
      }
      assertThrows(IOException::class.java) { r.read(0, 10, ByteArray(10)) }
    }
  }
  @Test fun changedOriginalLengthFailsBeforeReturningBytes() {
    reader().use { r ->
      r.size()
      server.dispatcher = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(206)
          .setHeader("Content-Range", "bytes 0-524287/${total + 1}").setHeader("ETag", "stable")
      }
      assertThrows(IOException::class.java) { r.read(0, 10, ByteArray(10)) }
    }
  }
  @Test fun closeCancelsBlockedNetworkAndRejectsFurtherReads() {
    server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest) = MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE) }
    val r = reader(); val worker = Executors.newSingleThreadExecutor()
    try {
      val reading = worker.submit { assertThrows(IOException::class.java) { r.size() } }
      assertNotNull(server.takeRequest(3, TimeUnit.SECONDS))
      r.close()
      reading.get(3, TimeUnit.SECONDS)
      assertThrows(IOException::class.java) { r.read(0, 10, ByteArray(10)) }
    } finally { r.close(); worker.shutdownNow() }
  }
  @Test fun cancellationDuringRequestPreparationNeverStartsNetwork() {
    val preparing = CountDownLatch(1)
    val prepared = CountDownLatch(1)
    val client = OkHttpClient.Builder().readTimeout(1, TimeUnit.SECONDS).build()
    val r = CloudRangeReader(client, {
      preparing.countDown()
      check(prepared.await(3, TimeUnit.SECONDS))
      Request.Builder().url(server.url("/original"))
    }, {})
    server.dispatcher = object : Dispatcher() {
      override fun dispatch(request: RecordedRequest) = MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)
    }
    val worker = Executors.newSingleThreadExecutor()
    val closer = Thread { r.close() }
    try {
      val reading = worker.submit { assertThrows(IOException::class.java) { r.size() } }
      assertTrue(preparing.await(3, TimeUnit.SECONDS))
      closer.start()
      // close publishes cancellation before waiting for read's monitor. Wait for
      // that barrier rather than racing the request builder against a sleep.
      val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
      while (closer.state != Thread.State.BLOCKED && System.nanoTime() < deadline) Thread.yield()
      assertEquals(Thread.State.BLOCKED, closer.state)
      prepared.countDown()
      reading.get(3, TimeUnit.SECONDS)
      closer.join(3000)
      assertFalse(closer.isAlive)
      assertEquals(0, server.requestCount)
    } finally {
      prepared.countDown(); r.close(); closer.join(3000); worker.shutdownNow()
    }
  }
  @Test fun malformedInputIsRejectedWithoutNetwork() {
    reader().use { r ->
      assertThrows(IOException::class.java) { r.read(-1, 1, ByteArray(1)) }
      assertThrows(IOException::class.java) { r.read(0, 2, ByteArray(1)) }
      assertEquals(0, server.requestCount)
    }
  }
}
