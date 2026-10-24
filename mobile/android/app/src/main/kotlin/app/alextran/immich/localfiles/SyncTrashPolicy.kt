package app.alextran.immich.localfiles

/** Identity read from the local database before a server deletion is applied. */
internal data class SyncTrashAsset(
  val id: String,
  val type: Int,
  val name: String,
  val createdAt: Long,
  val updatedAt: Long,
)

internal data class SyncTrashSnapshot(
  val type: Int,
  val name: String,
  val createdAt: Long,
  val updatedAt: Long,
  val isTrashed: Boolean,
)

/**
 * Only a live, unchanged media row can be mutated. A repeated operation on an
 * already-trashed row is complete without writing or refreshing its expiry.
 */
internal object SyncTrashPolicy {
  fun beforeWrite(expected: SyncTrashAsset, actual: SyncTrashSnapshot?): String? {
    if (actual == null) return "missing"
    if (actual.isTrashed) return "alreadyTrashed"
    if (expected.type != actual.type || expected.name != actual.name ||
      expected.createdAt != actual.createdAt || expected.updatedAt != actual.updatedAt) {
      return "assetChanged"
    }
    return null
  }
}
