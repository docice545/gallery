package app.alextran.immich.sync

internal data class MediaGenerationSnapshot(val version: String, val generations: Map<String, Long>)

/** Commit the generation observed BEFORE reading, never the generation at the
 * end of a scan. A screenshot may be published after a cursor was opened; an
 * end-of-scan checkpoint would incorrectly mark that unseen file as consumed.
 */
internal class MediaGenerationCheckpoint(private val read: () -> MediaGenerationSnapshot) {
  private var pending: MediaGenerationSnapshot? = null

  fun begin() {
    val snapshot = read()
    pending = snapshot.copy(generations = snapshot.generations.toMap())
  }

  fun ensureStarted() {
    if (pending == null) begin()
  }

  fun commit(persist: (MediaGenerationSnapshot) -> Unit) {
    ensureStarted()
    persist(requireNotNull(pending))
    pending = null
  }

  fun clear() {
    pending = null
  }
}
