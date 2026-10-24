package app.alextran.immich.localfiles

import java.io.StringReader
import javax.xml.parsers.DocumentBuilderFactory
import org.xml.sax.InputSource

/** Read-only byte layout of the embedded video; never guesses by scanning for ftyp. */
internal object LocalMotionPhotoLayout {
  const val MAX_VIDEO_BYTES = 64L * 1024 * 1024
  private const val MAX_DIRECTORY_BYTES = 64 * 1024
  data class Range(val start: Long, val length: Long)

  fun locate(length: Long, read: (Long, Int) -> ByteArray): Range? {
    if (length < 16) return null
    samsung(length, read)?.let { return it }
    val prefix = read(0, minOf(length, 1024L * 1024).toInt()).toString(Charsets.ISO_8859_1)
    val begin = prefix.indexOf("<x:xmpmeta")
    val end = if (begin >= 0) prefix.indexOf("</x:xmpmeta>", begin) else -1
    if (end < 0) return null
    return xmp(prefix.substring(begin, end + "</x:xmpmeta>".length), length)
  }

  /** Samsung SEF SDR layout is documented by Media3 SefReader and ExifTool Samsung.pm. */
  private fun samsung(length: Long, read: (Long, Int) -> ByteArray): Range? {
    val footer = read(length - 8, 8)
    if (footer.size != 8 || footer.copyOfRange(4, 8).toString(Charsets.US_ASCII) != "SEFT") return null
    val size = little(footer, 0)
    if (size < 12 || size > MAX_DIRECTORY_BYTES || size + 8 > length) return null
    val start = length - size - 8
    val directory = read(start, size.toInt())
    if (directory.size != size.toInt() || directory.copyOfRange(0, 4).toString(Charsets.US_ASCII) != "SEFH") return null
    val count = little(directory, 8)
    if (count > (directory.size - 12) / 12) return null
    for (index in 0 until count.toInt()) {
      val position = 12 + index * 12
      val type = (directory[position + 2].toInt() and 255) or ((directory[position + 3].toInt() and 255) shl 8)
      if (type != 0x0a30) continue
      val backwards = little(directory, position + 4)
      val blockSize = little(directory, position + 8)
      if (backwards > start || blockSize > backwards || blockSize < 8) return null
      val block = start - backwards
      val header = read(block, 8)
      if (header.size != 8) return null
      val nameLength = little(header, 4)
      if (nameLength !in 1..256 || nameLength + 8 >= blockSize) return null
      val name = read(block + 8, nameLength.toInt()).toString(Charsets.US_ASCII)
      if (name != "MotionPhoto_Data") continue
      val payload = block + 8 + nameLength
      val payloadSize = blockSize - 8 - nameLength
      if (payloadSize == 12L) {
        val data = read(payload, 12)
        if (data.size == 12 && data.copyOfRange(0, 4).toString(Charsets.US_ASCII) == "mpv2") {
          return checked(big(data, 4), big(data, 8), length)
        }
      }
      return checked(payload, payloadSize, length)
    }
    return null
  }

  /** Google Motion Photo V1 directory and legacy MicroVideoOffset. */
  internal fun xmp(xml: String, fileLength: Long): Range? {
    if (xml.length > 1024 * 1024 || xml.contains("<!DOCTYPE", ignoreCase = true)) return null
    return try {
      val factory = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
        isExpandEntityReferences = false
      }
      val builder = factory.newDocumentBuilder().apply {
        setEntityResolver { _, _ -> InputSource(StringReader("")) }
      }
      val document = builder.parse(InputSource(StringReader(xml)))
      val descriptions = document.getElementsByTagNameNS("*", "Description")
      var isMotion = false
      var legacyOffset: Long? = null
      for (i in 0 until descriptions.length) {
        val attributes = descriptions.item(i).attributes
        for (j in 0 until attributes.length) {
          val attribute = attributes.item(j)
          when (attribute.localName) {
            "MotionPhoto", "MicroVideo" -> if (attribute.nodeValue == "1") isMotion = true
            "MicroVideoOffset" -> legacyOffset = attribute.nodeValue.toLongOrNull()
          }
        }
      }
      if (!isMotion) return null
      val items = document.getElementsByTagNameNS("*", "Item")
      var position = fileLength
      for (i in items.length - 1 downTo 0) {
        val attributes = items.item(i).attributes
        val values = (0 until attributes.length).associate {
          val attribute = attributes.item(it)
          (attribute.localName ?: attribute.nodeName) to attribute.nodeValue
        }
        val itemLength = values["Length"]?.toLongOrNull() ?: 0
        if (itemLength < 0 || itemLength > position) return null
        if (i != 0) position -= itemLength
        if (values["Semantic"] == "MotionPhoto" && values["Mime"] == "video/mp4") {
          return checked(position, itemLength, fileLength)
        }
      }
      legacyOffset?.let { checked(fileLength - it, it, fileLength) }
    } catch (_: Exception) {
      null
    }
  }

  private fun checked(start: Long, size: Long, fileLength: Long): Range? =
    if (start >= 0 && size in 16..MAX_VIDEO_BYTES && start <= fileLength - size) Range(start, size) else null

  private fun little(bytes: ByteArray, offset: Int): Long =
    (0..3).fold(0L) { value, i -> value or ((bytes[offset + i].toLong() and 255) shl (i * 8)) }

  private fun big(bytes: ByteArray, offset: Int): Long =
    (0..3).fold(0L) { value, i -> (value shl 8) or (bytes[offset + i].toLong() and 255) }
}
