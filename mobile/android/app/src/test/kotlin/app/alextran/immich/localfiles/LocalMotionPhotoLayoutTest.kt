package app.alextran.immich.localfiles

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class LocalMotionPhotoLayoutTest {
  private val video = ByteBuffer.allocate(32).putInt(32).put("ftypisom".toByteArray()).array()
  private fun little(value: Int) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()
  private fun locate(bytes: ByteArray) = LocalMotionPhotoLayout.locate(bytes.size.toLong()) { start, count ->
    bytes.copyOfRange(start.toInt(), start.toInt() + count)
  }
  private fun samsung(pointer: Boolean): Pair<ByteArray, Long> {
    val prefix = ByteArray(128)
    val name = "MotionPhoto_Data".toByteArray()
    val payload = if (pointer) ByteBuffer.allocate(12).put("mpv2".toByteArray()).putInt(128).putInt(video.size).array() else video
    val header = byteArrayOf(0, 0, 0x30, 0x0a) + little(name.size) + name
    val beforeBlock = if (pointer) prefix + video + ByteArray(24) else prefix
    val block = header + payload
    val directory = "SEFH".toByteArray() + little(101) + little(1) +
      byteArrayOf(0, 0, 0x30, 0x0a) + little(block.size) + little(block.size)
    val all = beforeBlock + block + directory + little(directory.size) + "SEFT".toByteArray()
    return all to if (pointer) 128L else (prefix.size + header.size).toLong()
  }

  @Test fun `Samsung JPEG SEF resolves only its named embedded payload`() {
    val (bytes, start) = samsung(false)
    assertEquals(LocalMotionPhotoLayout.Range(start, video.size.toLong()), locate(bytes))
  }
  @Test fun `Samsung HEIC mpv2 resolves absolute offset and size`() {
    val (bytes, start) = samsung(true)
    assertEquals(LocalMotionPhotoLayout.Range(start, video.size.toLong()), locate(bytes))
  }
  @Test fun `invalid SEF offsets are rejected`() {
    val (bytes, _) = samsung(false)
    val directoryStart = bytes.size - 32
    little(Int.MAX_VALUE).copyInto(bytes, directoryStart + 16)
    assertNull(locate(bytes))
  }
  @Test fun `a video signature without motion metadata does not authorize extraction`() {
    assertNull(locate(ByteArray(128) + video))
  }
  @Test fun `legacy Google MicroVideo offset is resolved from end of local file`() {
    val xml = """<x:xmpmeta xmlns:x="x" xmlns:rdf="rdf" xmlns:Camera="camera"><rdf:Description Camera:MicroVideo="1" Camera:MicroVideoOffset="32"/></x:xmpmeta>"""
    assertEquals(LocalMotionPhotoLayout.Range(968, 32), LocalMotionPhotoLayout.xmp(xml, 1000))
  }
  @Test fun `Google container directory accounts for trailing non-video items`() {
    val xml = """<x:xmpmeta xmlns:x="x" xmlns:rdf="rdf" xmlns:Camera="camera" xmlns:Container="container" xmlns:Item="item"><rdf:Description Camera:MotionPhoto="1"/><Container:Directory><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0"/><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="32"/><Container:Item Item:Mime="image/jpeg" Item:Semantic="GainMap" Item:Length="16"/></Container:Directory></x:xmpmeta>"""
    assertEquals(LocalMotionPhotoLayout.Range(952, 32), LocalMotionPhotoLayout.xmp(xml, 1000))
  }
  @Test fun `an offset outside the source is never accepted`() {
    val xml = """<x:xmpmeta xmlns:x="x" xmlns:rdf="rdf" xmlns:Camera="camera"><rdf:Description Camera:MotionPhoto="1" Camera:MicroVideoOffset="999999"/></x:xmpmeta>"""
    assertNull(LocalMotionPhotoLayout.xmp(xml, 1000))
  }
  @Test fun `a disabled motion flag does not extract an incidental video offset`() {
    val xml = """<x:xmpmeta xmlns:x="x" xmlns:rdf="rdf" xmlns:Camera="camera"><rdf:Description Camera:MotionPhoto="0" Camera:MicroVideoOffset="32"/></x:xmpmeta>"""
    assertNull(LocalMotionPhotoLayout.xmp(xml, 1000))
  }
  @Test fun `XML external entity declarations are rejected`() {
    assertNull(LocalMotionPhotoLayout.xmp("<!DOCTYPE x SYSTEM 'https://invalid.test'><x:xmpmeta/>", 1000))
  }
  @Test fun `metadata probing never reads an entire large original`() {
    var largest = 0
    assertNull(LocalMotionPhotoLayout.locate(500L * 1024 * 1024) { _, count ->
      largest = maxOf(largest, count)
      ByteArray(count)
    })
    assertEquals(1024 * 1024, largest)
  }
}
