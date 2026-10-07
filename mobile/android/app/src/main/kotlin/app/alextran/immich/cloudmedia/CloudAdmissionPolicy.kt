package app.alextran.immich.cloudmedia

internal data class AdmissionSnapshot(
  val effective: String?, val overridePresent: Boolean, val overrideValue: String?,
  val feature: String?, val enforcement: String?, val selected: String?, val androidUser: Int,
)

internal data class AdmissionJournal(val before: AdmissionSnapshot, val written: String)

/** Pure policy, separate from shell transport and media/auth. */
internal object CloudAdmissionPolicy {
  private val packageName = Regex("[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z0-9_]+)+")
  const val GOOGLE_PHOTOS = "com.google.android.apps.photos"

  fun requireCaller(processUid: Int, callingUid: Int, ownerUid: Int, api: Int, lifecycle: Boolean = false) {
    if (processUid != 2000 || (callingUid != ownerUid && !(lifecycle && callingUid == 2000))) {
      throw SecurityException("Wireless shell service and application owner are required")
    }
    check(api >= 35) { "Sticky per-key overrides require Android 15 or newer" }
  }

  fun packages(value: String?): List<String> {
    require((value?.length ?: 0) <= 8192) { "Allowlist exceeds supported size" }
    if (value.isNullOrBlank()) return emptyList()
    return value.split(',').map { it.trim() }.also { parts ->
      require(parts.all { packageName.matches(it) }) { "Unsupported allowlist format" }
    }
  }

  fun plan(snapshot: AdmissionSnapshot, ownPackage: String, currentProviderPackage: String?): AdmissionJournal? {
    require(packageName.matches(ownPackage))
    require(snapshot.feature == null || snapshot.feature == "true") { "System cloud media feature is disabled" }
    require(snapshot.enforcement == null || snapshot.enforcement == "true") { "System allowlist protection was changed externally" }
    if (snapshot.overridePresent) packages(snapshot.overrideValue)
    val existing = packages(snapshot.effective)
    if (ownPackage in existing) return null // Do not claim an override we did not create.
    val merged = LinkedHashSet(existing)
    // An unset OEM/default list is not permission to remove Google Photos or the
    // currently selected, verified cloud provider when creating a local override.
    merged.add(GOOGLE_PHOTOS)
    currentProviderPackage?.let { require(packageName.matches(it)); merged.add(it) }
    merged.add(ownPackage)
    return AdmissionJournal(snapshot, merged.joinToString(","))
  }

  fun canUndo(current: AdmissionSnapshot, journal: AdmissionJournal): Boolean =
    current.androidUser == journal.before.androidUser && current.overridePresent &&
      current.overrideValue == journal.written && current.effective == journal.written

  fun verifyAdmitted(current: AdmissionSnapshot, written: String): Boolean =
    current.overridePresent && current.overrideValue == written && current.effective == written
}
