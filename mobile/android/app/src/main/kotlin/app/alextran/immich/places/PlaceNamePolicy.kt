package app.alextran.immich.places

import kotlin.math.*

/** Names are supplied by the OS geocoder, never transliterated or written to EXIF. */
internal data class PlaceNameCandidate(
  val latitude: Double,
  val longitude: Double,
  val featureName: String? = null,
  val locality: String? = null,
  val subLocality: String? = null,
  val adminArea: String? = null,
  val countryName: String? = null,
  val thoroughfare: String? = null,
)

internal object PlaceNamePolicy {
  /** Some device providers cannot parse qualified foreign-language place
   * names. A bounded city-only retry uses the same anchor and name policy;
   * it never falls back to the containing city of an unrelated POI. */
  fun queries(city: String, qualifiers: List<String>): List<String> {
    val parts = (listOf(city) + qualifiers).distinctBy { it.trim().lowercase(java.util.Locale.ROOT) }
    return listOf(parts.joinToString(", "), city).distinct()
  }

  fun acceptsLocale(label: String, languageTag: String): Boolean =
    !java.util.Locale.forLanguageTag(languageTag).language.equals("ru", ignoreCase = true) ||
      Regex("[А-Яа-яЁё]").containsMatchIn(label)

  fun validCoordinates(latitude: Double, longitude: Double): Boolean =
    latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0

  fun resolve(
    latitude: Double,
    longitude: Double,
    candidates: List<PlaceNameCandidate>,
    languageTag: String? = null,
  ): String? {
    if (!validCoordinates(latitude, longitude)) return null
    val nearby = candidates.mapNotNull { candidate ->
      if (!validCoordinates(candidate.latitude, candidate.longitude) ||
        !candidate.thoroughfare.isNullOrBlank()) return@mapNotNull null
      val distance = distanceMeters(latitude, longitude, candidate.latitude, candidate.longitude)
      if (distance > 25_000) return@mapNotNull null
      candidate to distance
    }.sortedBy { it.second }

    // Geocoder ordering is provider-specific. Prefer the anchor's nearest
    // trustworthy result, retaining provider order only for equal distances.
    // Check every candidate's language before selecting: an English result
    // must not hide a later localized result from the same bounded lookup.
    for ((candidate, _) in nearby) {
      val label = candidateLabel(candidate) ?: continue
      if (languageTag == null || acceptsLocale(label, languageTag)) return label
    }
    return null
  }

  private fun candidateLabel(candidate: PlaceNameCandidate): String? {
    // Address.featureName can be an airport or business even when no street
    // is supplied. Proximity alone must never rename a city to that POI, or
    // fall back from a queried suburb to the POI's containing city.
    val locality = safeLabel(candidate.locality)?.takeUnless { sameName(it, candidate.countryName) }
    val subLocality = safeLabel(candidate.subLocality)?.takeUnless {
      sameName(it, candidate.countryName) ||
        (sameName(it, candidate.adminArea) && !sameName(it, locality))
    }
    val feature = candidate.featureName?.trim()
    if (feature?.any(Char::isLetter) == true) {
      if (safeLabel(feature) == null) return null
      return feature.takeIf { sameName(it, locality) || sameName(it, subLocality) }
    }

    // Providers sometimes put an opaque numeric id in featureName. Only the
    // explicit city/suburb fields are suitable in that case (or if absent).
    return subLocality ?: locality
  }

  private fun safeLabel(value: String?): String? = value?.trim()?.takeIf {
    it.length in 1..200 && it.any(Char::isLetter) && it.none(Char::isISOControl)
  }

  private fun sameName(first: String?, second: String?): Boolean =
    !first.isNullOrBlank() && !second.isNullOrBlank() && first.trim().equals(second.trim(), ignoreCase = true)

  private fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = sin(dLat / 2).pow(2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2).pow(2)
    return 6_371_000 * 2 * asin(sqrt(a.coerceIn(0.0, 1.0)))
  }
}
