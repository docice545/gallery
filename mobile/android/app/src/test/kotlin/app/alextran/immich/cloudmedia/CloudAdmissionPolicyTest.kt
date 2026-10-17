package app.alextran.immich.cloudmedia

import org.junit.Assert.*
import org.junit.Test

class CloudAdmissionPolicyTest {
  @Test fun commandValuePreservesFlagWhitespaceForExactUndo() {
    assertEquals(" a.b,b.c ", CloudAdmissionPolicy.commandValue(" a.b,b.c \n"))
    assertEquals("", CloudAdmissionPolicy.commandValue("\n"))
    assertEquals("a.b", CloudAdmissionPolicy.commandValue("a.b\r\n"))
  }
  @Test fun independentRawPresenceMustAgreeWithOverrideListing() {
    val row = "mediaprovider/allowed_cloud_providers= a.b,b.c "
    assertTrue(CloudAdmissionPolicy.verifyOverrideSnapshot(listOf(row), " a.b,b.c ", " a.b,b.c "))
    assertTrue(CloudAdmissionPolicy.verifyOverrideSnapshot(emptyList(), null, "a.b"))
    assertFalse(CloudAdmissionPolicy.verifyOverrideSnapshot(emptyList(), "a.b", "a.b"))
    assertFalse(CloudAdmissionPolicy.verifyOverrideSnapshot(listOf(row), null, "a.b"))
    assertFalse(CloudAdmissionPolicy.verifyOverrideSnapshot(listOf(row), " a.b,b.c ", "different.value"))
    assertFalse(CloudAdmissionPolicy.verifyOverrideSnapshot(listOf(row, row), " a.b,b.c ", " a.b,b.c "))
    assertThrows(IllegalArgumentException::class.java) { CloudAdmissionPolicy.packages("a.b,\nc.d") }
  }
  private val own = "de.opennoodle.gallery"
  private fun state(value: String? = "com.google.android.apps.photos,com.example.cloud", present: Boolean = false) =
    AdmissionSnapshot(value, present, if (present) value else null, "true", "true", null, 0)

  private fun modernState(
    mediaProviders: String? = "com.google.android.apps.photos,com.example.cloud",
    feature: String? = "false",
  ): AdmissionSnapshot {
    val values = listOf(
      DeviceConfigValue("mediaprovider", "allowed_cloud_providers", mediaProviders, false, null),
      DeviceConfigValue("mediaprovider", "cloud_media_feature_enabled", feature, false, null),
    )
    return AdmissionSnapshot(mediaProviders, false, null, feature, "true", null, 0, values)
  }

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

  @Test fun android16ActivationPlansAllowlistAndFeatureFlag() {
    val journal = CloudAdmissionPolicy.plan(modernState(), own, "com.samsung.cloud")!!
    assertEquals(2, journal.changes.size)
    assertEquals(
      listOf("mediaprovider/allowed_cloud_providers", "mediaprovider/cloud_media_feature_enabled"),
      journal.changes.map { "${it.before.namespace}/${it.before.key}" },
    )
    assertEquals("true", journal.changes[1].written)
    assertEquals(listOf("com.google.android.apps.photos", "com.example.cloud", "com.samsung.cloud", own),
      CloudAdmissionPolicy.packages(journal.changes[0].written))
  }

  @Test fun existingModernActivationDoesNotClaimOwnership() {
    val base = modernState(feature = "true")
    val admitted = base.copy(
      values = base.values.map {
        it.copy(effective = if (it.key == "allowed_cloud_providers") "$own,com.google.android.apps.photos" else "true")
      },
      effective = "$own,com.google.android.apps.photos", feature = "true",
    )
    assertNull(CloudAdmissionPolicy.plan(admitted, own, null))
  }

  @Test fun modernRecoveryRequiresEveryWrittenSettingToRemainOwned() {
    val journal = CloudAdmissionPolicy.plan(modernState(), own, null)!!
    val after = journal.before.copy(values = journal.before.values.map { value ->
      val written = journal.changes.first { it.before.namespace == value.namespace && it.before.key == value.key }.written
      value.copy(effective = written, overridePresent = true, overrideValue = written)
    })
    assertTrue(CloudAdmissionPolicy.canUndo(after, journal))
    val changed = after.copy(values = after.values.map {
      if (it.key == "cloud_media_feature_enabled") it.copy(effective = "false") else it
    })
    assertFalse(CloudAdmissionPolicy.canUndo(changed, journal))
  }
  @Test fun exactPreviousFormattingIsRetainedForRecovery() {
    val before = state(" com.example.cloud , com.google.android.apps.photos ", true)
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    assertEquals(before, journal.before)
    assertTrue(CloudAdmissionPolicy.canUndo(state(journal.written, true), journal))
  }

  private fun written(before: DeviceConfigValue, journal: AdmissionJournal): DeviceConfigValue {
    val target = journal.changes.single { it.before.key == before.key }.written
    return before.copy(effective = target, overridePresent = true, overrideValue = target)
  }

  @Test fun everyInterruptedActivationCanBeUndoneWithoutClaimingUnwrittenKeys() {
    val before = modernState()
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    // Failure/cancellation before or after either command, including a lost Binder reply.
    for (mask in 0..3) {
      var current = before.copy(values = before.values.mapIndexed { index, value ->
        if (mask and (1 shl index) != 0) written(value, journal) else value
      })
      val restored = mutableListOf<String>()
      CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { change ->
        restored.add(change.before.key)
        current = current.copy(values = current.values.map { if (it.key == change.before.key) change.before else it })
      }
      assertEquals(before, current)
      assertEquals(Integer.bitCount(mask), restored.size)
      CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { fail("Already restored keys must not be rewritten") }
      val retry = CloudAdmissionPolicy.plan(current, own, null)!!
      current = current.copy(values = current.values.map { written(it, retry) })
      assertTrue(CloudAdmissionPolicy.verifyAdmitted(current, retry))
      assertNull(CloudAdmissionPolicy.plan(current, own, null)) // A retry cannot claim another mutation.
    }
  }

  @Test fun undoRetriesAfterFailureBeforeOrAfterEachMutation() {
    val before = modernState()
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    for (failureIndex in 0..1) for (lostReply in listOf(false, true)) {
      var current = before.copy(values = before.values.map { written(it, journal) })
      var index = 0
      assertThrows(java.io.IOException::class.java) {
        CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { change ->
          val fails = index++ == failureIndex
          if (fails && !lostReply) throw java.io.IOException("cancelled before write")
          current = current.copy(values = current.values.map { if (it.key == change.before.key) change.before else it })
          if (fails) throw java.io.IOException("lost acknowledgement")
        }
      }
      val expectedPending = current.values.count { it.overridePresent }
      var retryWrites = 0
      CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { change ->
        retryWrites++
        current = current.copy(values = current.values.map { if (it.key == change.before.key) change.before else it })
      }
      assertEquals(expectedPending, retryWrites)
      assertEquals(before, current)
      assertTrue(CloudAdmissionPolicy.isBefore(current, journal))
    }
  }

  @Test fun externalInterferenceBlocksRecoveryBeforeAnyFurtherWrite() {
    val before = modernState()
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    for (mask in 0..3) for (changedKey in before.values.indices) {
      val current = before.copy(values = before.values.mapIndexed { index, value ->
        when {
          index == changedKey -> value.copy(effective = "external", overridePresent = true, overrideValue = "external")
          mask and (1 shl index) != 0 -> written(value, journal)
          else -> value
        }
      })
      assertFalse(CloudAdmissionPolicy.canUndo(current, journal))
      assertFalse(CloudAdmissionPolicy.isBefore(current, journal))
      assertThrows(IllegalStateException::class.java) {
        CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { fail("External settings must remain untouched") }
      }
    }
  }

  @Test fun interferenceBetweenUndoCommandsIsDetectedAndNotOverwritten() {
    val before = modernState()
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    var current = before.copy(values = before.values.map { written(it, journal) })
    var writes = 0
    assertThrows(IllegalStateException::class.java) {
      CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { change ->
        writes++
        current = current.copy(values = listOf(change.before,
          before.values[1].copy(effective = "external", overridePresent = true, overrideValue = "external")))
      }
    }
    assertEquals(1, writes)
    assertEquals("external", current.values[1].overrideValue)
  }

  @Test fun legacyJournalCanRecoverUsingModernSnapshotsWithoutOwningTheFeatureFlag() {
    val before = state(" com.example.cloud , com.google.android.apps.photos ", true)
    val journal = CloudAdmissionPolicy.plan(before, own, null)!!
    assertTrue(journal.changes.isEmpty())
    assertTrue(CloudAdmissionPolicy.decodeChanges(null).isEmpty())
    assertTrue(CloudAdmissionPolicy.decodeValues(null).isEmpty())
    val unrelated = DeviceConfigValue("mediaprovider", "cloud_media_feature_enabled", "false", true, "false")
    var current = before.copy(values = listOf(
      DeviceConfigValue("mediaprovider", "allowed_cloud_providers", journal.written, true, journal.written), unrelated))
    CloudAdmissionPolicy.undoOwnedChanges(journal, { current }) { change ->
      assertEquals("allowed_cloud_providers", change.before.key)
      current = current.copy(values = listOf(change.before, unrelated))
    }
    assertEquals(before.overrideValue, current.values[0].overrideValue)
    assertEquals(unrelated, current.values[1])
    assertTrue(CloudAdmissionPolicy.isBefore(current, journal))
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
