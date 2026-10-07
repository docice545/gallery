package app.alextran.immich.cloudmedia

import org.junit.Assert.*
import org.junit.Test

class CloudAdmissionPolicyTest {
  private val own = "de.opennoodle.gallery"
  private fun state(value: String? = "com.google.android.apps.photos,com.example.cloud", present: Boolean = false) =
    AdmissionSnapshot(value, present, if (present) value else null, "true", "true", null, 0)

  @Test fun appendPreservesProvidersAndGoogle() {
    val journal = CloudAdmissionPolicy.plan(state(), own, null)!!
    assertEquals("com.google.android.apps.photos,com.example.cloud,de.opennoodle.gallery", journal.written)
    assertFalse(journal.before.overridePresent)
  }
  @Test fun unsetDefaultsDoNotRemoveGoogleOrSelectedProvider() {
    val journal = CloudAdmissionPolicy.plan(state(null), own, "com.samsung.cloud")!!
    assertEquals(listOf("com.google.android.apps.photos", "com.samsung.cloud", own), CloudAdmissionPolicy.packages(journal.written))
  }
  @Test fun existingAdmissionDoesNotClaimOwnership() {
    assertNull(CloudAdmissionPolicy.plan(state(own, true), own, null))
  }
  @Test fun recoveryOwnsOnlyExactWrittenValue() {
    val journal = CloudAdmissionPolicy.plan(state(present = true), own, null)!!
    val after = state(journal.written, true)
    assertTrue(CloudAdmissionPolicy.canUndo(after, journal))
    assertFalse(CloudAdmissionPolicy.canUndo(after.copy(effective = after.effective + ",com.another.cloud"), journal))
    assertFalse(CloudAdmissionPolicy.canUndo(after.copy(overrideValue = own), journal))
    assertFalse(CloudAdmissionPolicy.canUndo(after.copy(overridePresent = false), journal))
    assertFalse(CloudAdmissionPolicy.canUndo(after.copy(androidUser = 10), journal))
  }
  @Test fun readBackRequiresEffectiveAndOverrideAgreement() {
    val written = CloudAdmissionPolicy.plan(state(), own, null)!!.written
    assertTrue(CloudAdmissionPolicy.verifyAdmitted(state(written, true), written))
    assertFalse(CloudAdmissionPolicy.verifyAdmitted(state(written, false), written))
    assertFalse(CloudAdmissionPolicy.verifyAdmitted(state().copy(overridePresent = true, overrideValue = written), written))
  }
  @Test fun shellSyntaxAndOversizedValuesAreRejected() {
    for (value in listOf("com.google.photos;rm", "com.example.photos\nsh", "*", "null", "x".repeat(8193))) {
      assertThrows(IllegalArgumentException::class.java) { CloudAdmissionPolicy.plan(state(value), own, null) }
    }
  }
  @Test fun disabledFeatureOrGlobalBypassIsNotSilentlyChanged() {
    assertThrows(IllegalArgumentException::class.java) { CloudAdmissionPolicy.plan(state().copy(feature = "false"), own, null) }
    assertThrows(IllegalArgumentException::class.java) { CloudAdmissionPolicy.plan(state().copy(enforcement = "false"), own, null) }
  }
  @Test fun exactPreviousFormattingIsRetainedForRecovery() {
    val before = state(" com.example.cloud , com.google.android.apps.photos ", true)
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    assertEquals(before, journal.before)
    assertTrue(CloudAdmissionPolicy.canUndo(state(journal.written, true), journal))
  }
  @Test fun onlyOwnAppCanRequestShellOperationsAndRootIsRejected() {
    CloudAdmissionPolicy.requireCaller(2000, 10050, 10050, 36)
    assertThrows(SecurityException::class.java) { CloudAdmissionPolicy.requireCaller(0, 10050, 10050, 36) }
    assertThrows(SecurityException::class.java) { CloudAdmissionPolicy.requireCaller(2000, 10051, 10050, 36) }
    assertThrows(SecurityException::class.java) { CloudAdmissionPolicy.requireCaller(2000, 2000, 10050, 36) }
    assertThrows(IllegalStateException::class.java) { CloudAdmissionPolicy.requireCaller(2000, 10050, 10050, 34) }
  }
  @Test fun shizukuReservedDestroyTransactionCanDrainTheUserService() {
    CloudAdmissionPolicy.requireCaller(2000, 2000, 10050, 36, lifecycle = true)
    assertThrows(SecurityException::class.java) { CloudAdmissionPolicy.requireCaller(2000, 10051, 10050, 36, lifecycle = true) }
  }
}
