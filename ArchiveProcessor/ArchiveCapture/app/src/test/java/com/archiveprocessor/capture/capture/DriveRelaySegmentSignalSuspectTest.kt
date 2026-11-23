package com.archiveprocessor.capture.capture

import android.os.Looper
import androidx.lifecycle.viewModelScope
import com.archiveprocessor.capture.data.SessionStore
import com.archiveprocessor.capture.net.DriveClient
import com.archiveprocessor.capture.net.DriveRelayTransportTest
import com.archiveprocessor.capture.net.MacEndpoint
import com.archiveprocessor.capture.net.RelayObjectFormat
import kotlinx.coroutines.cancel
import org.json.JSONObject
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

/** S-021 regression: Drive refuses every completion write across a re-pair and the phone retries it
 *  from its saved session after recreation. Scratch app storage and in-process Drive only. */
@RunWith(RobolectricTestRunner::class)
class DriveRelaySegmentSignalSuspectTest {
    private val app = RuntimeEnvironment.getApplication()
    private val token = "TESTTK"
    private val name = "gdoc.segment.json"
    private val store = SessionStore(app)
    private val models = mutableListOf<CaptureViewModel>()

    @After fun tearDown() {
        models.forEach { it.viewModelScope.cancel() }
        CaptureViewModel.driveClientForTest = null
    }

    private fun pair(vm: CaptureViewModel) {
        var paired = false
        vm.connectCloud(MacEndpoint("", 0, token, "Mac", mode = "cloud")) { paired = it }
        waitUntil("cloud pairing") { paired }
    }

    private fun waitUntil(what: String, cond: () -> Boolean) {
        val deadline = System.nanoTime() + 10_000_000_000L
        do {
            shadowOf(Looper.getMainLooper()).idle()
            if (cond()) return
            Thread.sleep(10)
        } while (System.nanoTime() < deadline)
        error("Timed out waiting for $what")
    }

    @Test fun refusedCompletionRetainsTagsAcrossPairingAndRestoresFromDisk() {
        val drive = DriveRelayTransportTest.MockDrive().apply {
            injectFolder(token)
            injectFile(RelayObjectFormat.EPOCH_MARKER_NAME, token,
                RelayObjectFormat.canonicalJson(mapOf("kind" to "epoch", "token" to token, "epoch" to "EP1")))
            failCreate.add(name)
        }
        CaptureViewModel.driveClientForTest = DriveClient(drive) { "fake" }

        // Restore an open document whose page was already confirmed on the Mac.
        val dir = File(app.filesDir, "capture").apply { mkdirs() }
        val page = File(dir, "img_0001.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        assertTrue(store.save(listOf(CapturedItem(1, page, "gdoc", 1, GroupType.DOCUMENT, state = UploadState.UPLOADED)),
            seq = 1, nextId = 2, currentGroupId = "gdoc", pendingTagGroupId = null, endedSegments = emptyList()))
        val pending = listOf(SessionStore.EndedSeg("gdoc", "Q2", 1968, 3, "1"))
        val vm = CaptureViewModel(app).also { models.add(it) }
        pair(vm)
        vm.finishDocumentSegment()
        assertEquals("gdoc", vm.pendingTagGroupId)
        vm.applyTagsAndContinue("Q2", 1968, 3)
        waitUntil("three refused attempts and a saved pending completion") {
            drive.refusedCreates.size == 3 && store.load()?.endedSegments == pending
        }
        assertFalse(drive.hasName(name))

        vm.disconnect()
        pair(vm)
        waitUntil("another round of refused writes after re-pair") {
            // The first retry tick can run while the old pairing's send is unwinding.
            shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
            drive.refusedCreates.size >= 6
        }
        assertEquals(pending, store.load()?.endedSegments)
        assertFalse(drive.hasName(name))

        vm.disconnect()
        vm.viewModelScope.cancel()
        drive.failCreate.remove(name)
        pair(CaptureViewModel(app).also { models.add(it) })
        waitUntil("published completion and cleared pending record") {
            drive.hasName(name) && store.load()?.endedSegments?.isEmpty() == true
        }
        val meta = JSONObject(drive.media(name).single().toString(Charsets.UTF_8))
        assertEquals("gdoc", meta.getString("group"))
        assertEquals("1", meta.getString("seqs"))
        assertEquals("Q2", meta.getString("quality"))
        assertEquals("1968", meta.getString("year"))
        assertEquals("3", meta.getString("month"))
    }
}
