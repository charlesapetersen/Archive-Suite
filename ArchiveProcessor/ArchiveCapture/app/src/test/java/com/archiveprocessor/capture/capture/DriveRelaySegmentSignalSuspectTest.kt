package com.archiveprocessor.capture.capture

import android.os.Looper
import com.archiveprocessor.capture.data.SessionStore
import com.archiveprocessor.capture.net.DriveClient
import com.archiveprocessor.capture.net.DriveRelayTransportTest
import com.archiveprocessor.capture.net.MacEndpoint
import com.archiveprocessor.capture.net.RelayObjectFormat
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.io.File

/**
 * W49.relay-suspects, S-021 (phase rule 5a): the operator's path over the cloud relay. The real [CaptureViewModel]
 * restores a session with one page already on the Mac, pairs to the cloud relay, and the operator ends the segment
 * (End segment, then Skip on the tag sheet). The real [DriveRelayTransport] and [DriveClient] talk to the mock Drive
 * of [DriveRelayTransportTest], which answers the `<group>.segment.json` create with a 500.
 *
 * These assertions record what the phone does TODAY, as reproduced on 2026-11-20 (S-021 in verification/SUSPECTS.md):
 * the signal is never written, yet the phone drops the segment from its ended-but-unacked list, so nothing re-sends
 * it, not even a reconnect. A fix flips the `failed` case: the segment stays in the list and is re-sent.
 *
 * Scratch only: Robolectric's per-test app storage, no network, no Google sign-in.
 */
@RunWith(RobolectricTestRunner::class)
class DriveRelaySegmentSignalSuspectTest {

    private val app = RuntimeEnvironment.getApplication()
    private val token = "TESTTK"

    @After fun tearDown() { CaptureViewModel.driveClientForTest = null }

    /** A Drive with the Mac's relay folder and its epoch marker, as the Mac publishes them. */
    private fun macDrive() = DriveRelayTransportTest.MockDrive().apply {
        injectFolder(token)
        injectFile(RelayObjectFormat.EPOCH_MARKER_NAME, token,
            RelayObjectFormat.canonicalJson(mapOf("kind" to "epoch", "token" to token, "epoch" to "EP1")))
    }

    /** One document page of the open segment `gdoc`, already confirmed on the Mac. */
    private fun seedSession() {
        val dir = File(app.filesDir, "capture").apply { mkdirs() }
        val page = File(dir, "img_0001.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        assertTrue(SessionStore(app).save(listOf(CapturedItem(1, page, "gdoc", 1, GroupType.DOCUMENT, state = UploadState.UPLOADED)),
            seq = 1, nextId = 2, currentGroupId = "gdoc", pendingTagGroupId = null, endedSegments = emptyList()))
    }

    private fun waitUntil(what: String, cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 10_000
        while (!cond()) {
            shadowOf(Looper.getMainLooper()).idle()
            if (System.currentTimeMillis() > deadline) throw AssertionError("timed out waiting for $what")
            Thread.sleep(20)
        }
    }

    /** The ended-but-unacked list as the session writer (off the main thread) last saved it: polled for up to 5 s
     *  for the list to empty, so a slow write is not mistaken for a kept segment. */
    private fun endedOnDisk(): List<String> {
        val deadline = System.currentTimeMillis() + 5_000
        while (true) {
            shadowOf(Looper.getMainLooper()).idle()
            val groups = SessionStore(app).load()!!.endedSegments.map { it.group }
            if (groups.isEmpty() || System.currentTimeMillis() > deadline) return groups
            Thread.sleep(50)
        }
    }

    /** Pair to the cloud relay, end the segment, Skip the tag sheet; returns once the send has settled. */
    private fun endSegmentOverRelay(drive: DriveRelayTransportTest.MockDrive): CaptureViewModel {
        CaptureViewModel.driveClientForTest = DriveClient(drive) { "fake" }
        seedSession()
        val vm = CaptureViewModel(app)
        var paired = false
        vm.connectCloud(MacEndpoint("", 0, token, "Mac", mode = "cloud")) { paired = it }
        waitUntil("cloud pairing") { paired }
        vm.finishDocumentSegment()
        assertEquals("End segment opens the tag sheet", "gdoc", vm.pendingTagGroupId)
        vm.applyTagsAndContinue(null, null, null)
        waitUntil("the segment signal to settle") {
            drive.hasName("gdoc.segment.json") || drive.refusedCreates.isNotEmpty()
        }
        // The send job removes the group from the list (or not) on the main thread after the transport returns.
        Thread.sleep(200); shadowOf(Looper.getMainLooper()).idle()
        return vm
    }

    @Test fun `control - the signal is written and the segment leaves the list`() {
        val drive = macDrive()
        endSegmentOverRelay(drive)
        assertTrue("segment object on Drive", drive.hasName("gdoc.segment.json"))
        assertEquals(emptyList<String>(), endedOnDisk())
    }

    @Test fun `S-021 - a refused segment write is recorded as acked and never re-sent`() {
        val drive = macDrive().apply { failCreate.add("gdoc.segment.json") }
        val vm = endSegmentOverRelay(drive)
        assertEquals("one create, refused, and no retry", listOf("gdoc.segment.json"), drive.refusedCreates)
        assertFalse("no segment object on Drive", drive.hasName("gdoc.segment.json"))
        assertEquals("dropped from the ended-but-unacked list on disk", emptyList<String>(), endedOnDisk())

        // A reconnect re-drives every ended-but-unacked segment; this one is no longer listed, so nothing goes.
        var paired = false
        vm.connectCloud(MacEndpoint("", 0, token, "Mac", mode = "cloud")) { paired = it }
        waitUntil("re-pairing") { paired }
        Thread.sleep(500); shadowOf(Looper.getMainLooper()).idle()
        assertEquals("no further attempt after a reconnect", listOf("gdoc.segment.json"), drive.refusedCreates)
        assertFalse(drive.hasName("gdoc.segment.json"))
    }
}
