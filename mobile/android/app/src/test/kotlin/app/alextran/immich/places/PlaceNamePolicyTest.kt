package app.alextran.immich.places

import org.junit.Assert.*
import org.junit.Test

class PlaceNamePolicyTest {
  @Test fun `ignored Russian locale triggers the bounded fallback instead of accepting English`() {
    assertFalse(PlaceNamePolicy.acceptsLocale("Moscow", "ru-RU"))
    assertFalse(PlaceNamePolicy.acceptsLocale("Moskva", "ru"))
    assertTrue(PlaceNamePolicy.acceptsLocale("Москва", "ru-RU"))
    assertTrue(PlaceNamePolicy.acceptsLocale("Mũi Né", "vi"))
  }

  @Test fun `qualified lookup has only one bounded city-only fallback`() {
    assertEquals(listOf("Moscow, Russia", "Moscow"),
      PlaceNamePolicy.queries("Moscow", listOf("MOSCOW", "Russia")))
    assertEquals(listOf("Vnukovo, Moscow, Russia", "Vnukovo"),
      PlaceNamePolicy.queries("Vnukovo", listOf("Moscow", "Russia")))
    assertEquals(listOf("Муйне"), PlaceNamePolicy.queries("Муйне", emptyList()))
  }

  @Test fun preservesNamesFromLocalizedProviderWithoutTransliteration() {
    val fixtures = listOf("Москва", "Химки", "Внуково", "Белек", "Муйне", "Немчиновка",
      "Восточное Дегунино", "Новая Купавна", "Гонолулу")
    fixtures.forEach { name ->
      assertEquals(name, PlaceNamePolicy.resolve(55.75, 37.61,
        listOf(PlaceNameCandidate(55.75, 37.61, featureName = name, locality = name))))
    }
  }

  @Test fun rejectsDistantAmbiguousPlaceAndStreetAddress() {
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(21.3, -157.8, featureName = "Гонолулу"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "7", locality = "Москва", thoroughfare = "Тверская"))))
  }

  @Test fun rejectsCountryAndRegionOnlyResults() {
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Россия", countryName = "Россия"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Московская область", adminArea = "Московская область"))))
  }

  @Test fun usesValidLocalityFallbackAndAllowsEquatorAndPrimeMeridian() {
    assertEquals("Greenwich", PlaceNamePolicy.resolve(0.0, 0.0,
      listOf(PlaceNameCandidate(0.0, 0.0, featureName = "001", locality = "Greenwich"))))
    assertNull(PlaceNamePolicy.resolve(Double.NaN, 0.0, emptyList()))
    assertFalse(PlaceNamePolicy.validCoordinates(91.0, 0.0))
    assertFalse(PlaceNamePolicy.validCoordinates(0.0, 181.0))
  }

  @Test fun distanceHandlesDateLineAndDoesNotChooseOtherCity() {
    assertEquals("Место", PlaceNamePolicy.resolve(0.0, 179.99,
      listOf(PlaceNameCandidate(0.0, -179.99, featureName = "Место", locality = "Место"))))
    assertNull(PlaceNamePolicy.resolve(0.0, 0.0,
      listOf(PlaceNameCandidate(1.0, 0.0, featureName = "Место"))))
  }

  @Test fun rejectsPoiWithoutStreetAndDoesNotRenameSuburbToItsContainingCity() {
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Международный аэропорт Внуково", locality = "Москва"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Гостиница", locality = "Химки", subLocality = "Сходня"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Океанариум"))))
  }

  @Test fun matchesExplicitLocalityOrSuburbIgnoringOnlyCaseAndOuterWhitespace() {
    assertEquals("химки", PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = " химки ", locality = "Химки"))))
    assertEquals("Восточное Дегунино", PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Восточное Дегунино", locality = "Москва",
        subLocality = " восточное дегунино "))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Moskva", locality = "Москва"))))
  }

  @Test fun rejectsCountryAndRegionLabelsWithWhitespaceOrCaseDifferences() {
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = " россия ", countryName = "Россия"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, subLocality = " РОССИЯ ", countryName = "Россия"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = " московская область ", adminArea = "Московская область"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, subLocality = " московская область ", adminArea = "Московская область"))))
    // A city can legitimately also name its own administrative region.
    assertEquals("Москва", PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, locality = "Москва", adminArea = " москва "))))
  }

  @Test fun rejectsInvalidProviderLabelsBeforeConsideringTheNextCandidate() {
    assertEquals("Химки", PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, featureName = "Гостиница", locality = "Москва"),
        PlaceNameCandidate(55.75, 37.61, featureName = "Химки", locality = "Химки"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, locality = "Мос\u0000ква"))))
    assertNull(PlaceNamePolicy.resolve(55.75, 37.61,
      listOf(PlaceNameCandidate(55.75, 37.61, locality = "Я".repeat(201)))))
  }

  @Test fun `English first result does not hide a later Russian candidate`() {
    val candidates = listOf(
      PlaceNameCandidate(55.58, 37.60, featureName = "Annino", locality = "Annino"),
      PlaceNameCandidate(55.5801, 37.60, featureName = "Аннино", locality = "Аннино"),
    )
    assertEquals("Аннино", PlaceNamePolicy.resolve(55.58, 37.60, candidates, "ru-RU"))
    assertEquals("Annino", PlaceNamePolicy.resolve(55.58, 37.60, candidates, "en-US"))
  }

  @Test fun `nearest trusted homonym wins regardless of provider registration order`() {
    listOf("Аннино", "Дружба").forEach { name ->
      val nearest = PlaceNameCandidate(55.5801, 37.60, featureName = name, locality = name)
      // Distinct provider casing makes the selected result observable without
      // inventing a translated name or using the input name as a replacement.
      val farther = PlaceNameCandidate(55.70, 37.60,
        featureName = name.uppercase(java.util.Locale.ROOT), locality = name.uppercase(java.util.Locale.ROOT))
      assertEquals(name, PlaceNamePolicy.resolve(55.58, 37.60, listOf(farther, nearest), "ru"))
      assertEquals(name, PlaceNamePolicy.resolve(55.58, 37.60, listOf(nearest, farther), "ru"))
    }
  }

  @Test fun `a distant homonym in another country cannot displace the anchored place`() {
    val candidates = listOf(
      PlaceNameCandidate(46.39, 28.26, featureName = "Дружба", locality = "Дружба", countryName = "Молдова"),
      PlaceNameCandidate(55.58, 37.60, featureName = "ДРУЖБА", locality = "ДРУЖБА", countryName = "Россия"),
    )
    assertEquals("ДРУЖБА", PlaceNamePolicy.resolve(55.58, 37.60, candidates, "ru"))
  }

  @Test fun `only provider localized names are returned without generated transliteration`() {
    val fixtures = listOf(
      Triple(36.86, 31.05, "Белек"),
      Triple(56.25, 37.99, "Хотьково"),
    )
    fixtures.forEach { (latitude, longitude, name) ->
      assertEquals(name, PlaceNamePolicy.resolve(latitude, longitude,
        listOf(PlaceNameCandidate(latitude, longitude, featureName = name, locality = name)), "ru-RU"))
    }
    assertNull(PlaceNamePolicy.resolve(36.86, 31.05,
      listOf(PlaceNameCandidate(36.86, 31.05, featureName = "Belek", locality = "Belek")), "ru"))
    assertNull(PlaceNamePolicy.resolve(56.25, 37.99,
      listOf(PlaceNameCandidate(56.25, 37.99, featureName = "Khot'kovo", locality = "Khot'kovo")), "ru"))
  }

  @Test fun `nearest ranking handles candidates on opposite sides of the date line`() {
    val candidates = listOf(
      PlaceNameCandidate(0.0, 179.80, featureName = "Дальнее место", locality = "Дальнее место"),
      PlaceNameCandidate(0.0, -179.99, featureName = "Ближнее место", locality = "Ближнее место"),
    )
    assertEquals("Ближнее место", PlaceNamePolicy.resolve(0.0, 179.99, candidates, "ru"))
  }

  @Test fun `equal distance retains deterministic provider order`() {
    val first = PlaceNameCandidate(55.58, 37.60, featureName = "Первое место", locality = "Первое место")
    val second = PlaceNameCandidate(55.58, 37.60, featureName = "Второе место", locality = "Второе место")
    assertEquals("Первое место", PlaceNamePolicy.resolve(55.58, 37.60, listOf(first, second), "ru"))
    assertEquals("Второе место", PlaceNamePolicy.resolve(55.58, 37.60, listOf(second, first), "ru"))
  }

  @Test fun `localized nearby POI and mismatched scripts remain untrusted`() {
    val candidates = listOf(
      PlaceNameCandidate(55.58, 37.60, featureName = "Парк Аннино", locality = "Москва"),
      PlaceNameCandidate(55.5801, 37.60, featureName = "Annino", locality = "Аннино"),
      PlaceNameCandidate(55.5802, 37.60, featureName = "Аннино", locality = "Аннино"),
    )
    assertEquals("Аннино", PlaceNamePolicy.resolve(55.58, 37.60, candidates, "ru"))
    assertNull(PlaceNamePolicy.resolve(55.58, 37.60, candidates.take(2), "ru"))
  }
}
