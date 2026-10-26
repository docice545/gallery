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
  fun supportsTrash(sdk: Int, userRequested: Boolean): Boolean = sdk >= if (userRequested) 30 else 31

  fun mayRequestTrash(userRequested: Boolean, canManageMedia: Boolean): Boolean = userRequested || canManageMedia

  fun beforeWrite(expected: SyncTrashAsset, actual: SyncTrashSnapshot?): String? {
    if (actual == null) return "missing"
    // A recycled ID must never complete another photo's intent, even when the
    // replacement happens to be in Trash. Trashing itself may change DATE_MODIFIED.
    if (expected.type != actual.type || expected.name != actual.name || expected.createdAt != actual.createdAt) {
      return "assetChanged"
    }
    if (actual.isTrashed) return "alreadyTrashed"
    if (expected.updatedAt != actual.updatedAt) return "assetChanged"
    return null
  }

  fun identityDiagnostic(expected: SyncTrashAsset, actual: SyncTrashSnapshot?): String =
    if (actual == null) "phase=identity: MediaStore row missing or no longer visible" else
      "phase=identity typeMatches=${expected.type == actual.type} nameMatches=${expected.name == actual.name} " +
        "createdAtMatches=${expected.createdAt == actual.createdAt} updatedAtMatches=${expected.updatedAt == actual.updatedAt} " +
        "isTrashed=${actual.isTrashed}"
}
