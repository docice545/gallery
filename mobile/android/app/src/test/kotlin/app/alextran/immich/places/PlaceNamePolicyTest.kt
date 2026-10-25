package app.alextran.immich.places

import org.junit.Assert.*
import org.junit.Test

class PlaceNamePolicyTest {
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
}
