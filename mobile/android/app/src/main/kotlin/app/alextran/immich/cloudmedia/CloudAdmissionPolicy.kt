package app.alextran.immich.cloudmedia

import org.json.JSONArray
import org.json.JSONObject

internal data class DeviceConfigValue(
  val namespace: String,
  val key: String,
  val effective: String?,
  val overridePresent: Boolean,
  val overrideValue: String?,
)

internal data class AdmissionSnapshot(
  val effective: String?, val overridePresent: Boolean, val overrideValue: String?,
  val feature: String?, val enforcement: String?, val selected: String?, val androidUser: Int,
  // The first seven fields are retained for compatibility with journals written by the
  // previous implementation. New snapshots carry both mediaprovider values consulted by
  // Android 15/16.
  val values: List<DeviceConfigValue> = emptyList(),
)

internal data class AdmissionChange(val before: DeviceConfigValue, val written: String)

internal data class AdmissionJournal(
  val before: AdmissionSnapshot,
  val written: String,
  val changes: List<AdmissionChange> = emptyList(),
) {
  val planToken: String
    get() = changes.joinToString("\u0001") { "${it.before.namespace}/${it.before.key}=${it.written}" }
}

/** Pure policy, separate from shell transport and media/auth. */
internal object CloudAdmissionPolicy {
  private val packageName = Regex("[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z0-9_]+)+")
  const val GOOGLE_PHOTOS = "com.google.android.apps.photos"
  const val MEDIA_PROVIDER_NAMESPACE = "mediaprovider"
  const val ALLOWED_CLOUD_PROVIDERS = "allowed_cloud_providers"
  const val CLOUD_MEDIA_FEATURE_ENABLED = "cloud_media_feature_enabled"
  const val CLOUD_PERMISSION = "com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS"

  val settings = listOf(
    MEDIA_PROVIDER_NAMESPACE to ALLOWED_CLOUD_PROVIDERS,
    MEDIA_PROVIDER_NAMESPACE to CLOUD_MEDIA_FEATURE_ENABLED,
  )

  // println adds one terminator. Preserve actual flag whitespace for exact undo.
  fun commandValue(stdout: String): String = stdout.removeSuffix("\n").removeSuffix("\r")

  fun verifyOverrideSnapshot(listed: List<String>, raw: String?, effective: String?): Boolean =
    listed.size <= 1 && listed.isNotEmpty() == (raw != null) &&
      (raw == null || (raw == effective && listed.single().substringAfter('=') == raw))

  fun verifyOverrideSnapshots(listed: List<Pair<String, String>>, values: List<DeviceConfigValue>): Boolean {
    if (values.map { "${it.namespace}/${it.key}" }.toSet().size != values.size) return false
    if (listed.map { it.first }.toSet().size != listed.size) return false
    val listedMap = listed.toMap()
    val known = values.associateBy { "${it.namespace}/${it.key}" }
    if (listedMap.keys.any { it !in known }) return false
    return values.all { value ->
      val name = "${value.namespace}/${value.key}"
      val listedValue = listedMap[name]
      (listedValue != null) == value.overridePresent &&
        (!value.overridePresent ||
          (listedValue == value.overrideValue && value.overrideValue == value.effective))
    }
  }

  fun requireCaller(processUid: Int, callingUid: Int, ownerUid: Int, api: Int, lifecycle: Boolean = false) {
    if (processUid != 2000 || (callingUid != ownerUid && !(lifecycle && callingUid == 2000))) {
      throw SecurityException("Wireless shell service and application owner are required")
    }
    check(api >= 35) { "Sticky per-key overrides require Android 15 or newer" }
  }

  fun packages(value: String?): List<String> {
    require((value?.length ?: 0) <= 8192) { "Allowlist exceeds supported size" }
    require(value?.any { it == '\n' || it == '\r' || it == '\u0000' } != true) { "Unsupported multiline allowlist" }
    if (value.isNullOrBlank()) return emptyList()
    return value.split(',').map { it.trim() }.also { parts ->
      require(parts.all { packageName.matches(it) }) { "Unsupported allowlist format" }
    }
  }

  fun plan(snapshot: AdmissionSnapshot, ownPackage: String, currentProviderPackage: String?): AdmissionJournal? {
    require(packageName.matches(ownPackage))
    require(snapshot.enforcement == null || snapshot.enforcement == "true") { "System allowlist protection was changed externally" }
    // A legacy journal only described mediaprovider/allowed_cloud_providers. Keep its
    // old policy contract while new builds use both AOSP mediaprovider values below.
    if (snapshot.values.isEmpty()) {
      require(snapshot.feature == null || snapshot.feature == "true") { "System cloud media feature is disabled" }
      if (snapshot.overridePresent) packages(snapshot.overrideValue)
      val merged = mergedProviders(snapshot.effective, ownPackage, currentProviderPackage)
      if (ownPackage in packages(snapshot.effective)) return null
      return AdmissionJournal(snapshot, merged)
    }

    val changes = snapshot.values.mapNotNull { before ->
      val desired = when (before.key) {
        ALLOWED_CLOUD_PROVIDERS -> mergedProviders(before.effective, ownPackage, currentProviderPackage)
        CLOUD_MEDIA_FEATURE_ENABLED -> "true"
        else -> error("Unsupported cloud media setting ${before.namespace}/${before.key}")
      }
      if (before.effective == desired) null else AdmissionChange(before, desired)
    }
    return changes.firstOrNull()?.let { AdmissionJournal(snapshot, it.written, changes) }
  }

  private fun mergedProviders(effective: String?, ownPackage: String, currentProviderPackage: String?): String {
    val existing = packages(effective)
    if (ownPackage in existing) return effective ?: ownPackage
    val merged = LinkedHashSet(existing)
    // An unset OEM/default list is not permission to remove Google Photos or the
    // currently selected, verified cloud provider when creating a local override.
    merged.add(GOOGLE_PHOTOS)
    currentProviderPackage?.let { require(packageName.matches(it)); merged.add(it) }
    merged.add(ownPackage)
    return merged.joinToString(",")
  }

  private fun changes(journal: AdmissionJournal): List<AdmissionChange> = journal.changes.ifEmpty {
    listOf(AdmissionChange(DeviceConfigValue(MEDIA_PROVIDER_NAMESPACE, ALLOWED_CLOUD_PROVIDERS,
      journal.before.effective, journal.before.overridePresent, journal.before.overrideValue), journal.written))
  }

  private fun value(current: AdmissionSnapshot, change: AdmissionChange): DeviceConfigValue? {
    if (current.values.isNotEmpty()) return current.values.singleOrNull {
      it.namespace == change.before.namespace && it.key == change.before.key
    }
    // Legacy journals/snapshots own only the original allowlist key.
    if (change.before.namespace != MEDIA_PROVIDER_NAMESPACE || change.before.key != ALLOWED_CLOUD_PROVIDERS) return null
    return DeviceConfigValue(MEDIA_PROVIDER_NAMESPACE, ALLOWED_CLOUD_PROVIDERS,
      current.effective, current.overridePresent, current.overrideValue)
  }

  private fun isWritten(value: DeviceConfigValue, change: AdmissionChange) =
    value.overridePresent && value.overrideValue == change.written && value.effective == change.written

  private fun isOriginal(value: DeviceConfigValue, change: AdmissionChange) =
    value.overridePresent == change.before.overridePresent && value.overrideValue == change.before.overrideValue &&
      (!value.overridePresent || value.effective == change.before.overrideValue)

  // A cancelled two-key write/undo can leave any mix of original and owned values.
  // Null means external interference: never overwrite even the still-owned keys.
  private fun pendingUndo(current: AdmissionSnapshot, journal: AdmissionJournal): List<AdmissionChange>? {
    if (current.androidUser != journal.before.androidUser) return null
    val pending = mutableListOf<AdmissionChange>()
    for (change in changes(journal)) {
      val now = value(current, change) ?: return null
      when {
        isOriginal(now, change) -> Unit
        isWritten(now, change) -> pending.add(change)
        else -> return null
      }
    }
    return pending
  }

  fun canUndo(current: AdmissionSnapshot, journal: AdmissionJournal): Boolean =
    pendingUndo(current, journal)?.isNotEmpty() == true

  fun undoOwnedChanges(journal: AdmissionJournal, inspect: () -> AdmissionSnapshot, restore: (AdmissionChange) -> Unit) {
    for (change in changes(journal)) {
      // Re-read before each mutation, including retries after a lost acknowledgement.
      val pending = checkNotNull(pendingUndo(inspect(), journal)) {
        "Settings changed externally; recovery will not overwrite them"
      }
      if (change in pending) restore(change)
    }
    check(isBefore(inspect(), journal)) { "Recovery read-back failed" }
  }

  fun isBefore(current: AdmissionSnapshot, journal: AdmissionJournal): Boolean {
    return pendingUndo(current, journal)?.isEmpty() == true
  }

  fun verifyAdmitted(current: AdmissionSnapshot, written: String): Boolean =
    current.overridePresent && current.overrideValue == written && current.effective == written

  fun verifyAdmitted(current: AdmissionSnapshot, journal: AdmissionJournal): Boolean {
    if (journal.changes.isEmpty()) return verifyAdmitted(current, journal.written)
    val values = current.values.associateBy { "${it.namespace}/${it.key}" }
    return journal.changes.all { change ->
      val value = values["${change.before.namespace}/${change.before.key}"] ?: return@all false
      value.overridePresent && value.overrideValue == change.written && value.effective == change.written
    }
  }

  internal fun encodeValues(values: List<DeviceConfigValue>): String = JSONArray().apply {
    values.forEach { value ->
      put(JSONObject().apply {
        put("namespace", value.namespace)
        put("key", value.key)
        put("effective", value.effective ?: JSONObject.NULL)
        put("overridePresent", value.overridePresent)
        put("overrideValue", value.overrideValue ?: JSONObject.NULL)
      })
    }
  }.toString()

  internal fun decodeValues(raw: String?): List<DeviceConfigValue> {
    if (raw.isNullOrBlank()) return emptyList()
    val array = JSONArray(raw)
    return buildList(array.length()) {
      for (index in 0 until array.length()) {
        val value = array.getJSONObject(index)
        fun text(key: String) = if (value.isNull(key)) null else value.getString(key)
        add(DeviceConfigValue(value.getString("namespace"), value.getString("key"),
          text("effective"), value.getBoolean("overridePresent"), text("overrideValue")))
      }
    }
  }

  internal fun encodeChanges(changes: List<AdmissionChange>): String = JSONArray().apply {
    changes.forEach { change ->
      put(JSONObject().apply {
        put("namespace", change.before.namespace); put("key", change.before.key)
        put("written", change.written)
        put("before", JSONObject().apply {
          put("effective", change.before.effective ?: JSONObject.NULL)
          put("overridePresent", change.before.overridePresent)
          put("overrideValue", change.before.overrideValue ?: JSONObject.NULL)
        })
      })
    }
  }.toString()

  internal fun decodeChanges(raw: String?): List<AdmissionChange> {
    if (raw.isNullOrBlank()) return emptyList()
    val array = JSONArray(raw)
    return buildList(array.length()) {
      for (index in 0 until array.length()) {
        val value = array.getJSONObject(index)
        val before = value.getJSONObject("before")
        fun text(key: String) = if (before.isNull(key)) null else before.getString(key)
        add(AdmissionChange(
          DeviceConfigValue(value.getString("namespace"), value.getString("key"), text("effective"),
            before.getBoolean("overridePresent"), text("overrideValue")),
          value.getString("written"),
        ))
      }
    }
  }
}
