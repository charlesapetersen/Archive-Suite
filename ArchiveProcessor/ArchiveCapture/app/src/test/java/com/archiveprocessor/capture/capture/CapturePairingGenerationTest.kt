package com.archiveprocessor.capture.capture

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * W23.m1 — re-pairing used to leave an upload owned by the OLD Mac: `disconnect()` cleared the client but
 * cancelled nothing and invalidated no in-flight entry, so the newly paired Mac was refused the re-enqueue
 * while the orphaned coroutine kept uploading through its captured old client. If that old Mac answered,
 * the page was marked uploaded and the phone's copy scheduled for deletion — though the Mac now paired had
 * never received it.
 *
 * These tests exercise the shipped ownership layer ([PairingGeneration], [OutstandingSends], [sendAck]) and
 * then drive it through the real disconnect/re-pair sequence in [UploadQueue] below, which wires those same
 * objects the way `CaptureViewModel.enqueueUpload` does.
 *
 * Scratch only: the only file touched is a JVM temp file. Nothing here can see a corpus, a capture session,
 * a Mac, or the phone's gallery.
 */
class CapturePairingGenerationTest {

    private fun tempJpeg(): File =
        File.createTempFile("w23m1-", ".jpg").apply { writeBytes(byteArrayOf(1, 2, 3)); deleteOnExit() }

    // ---- the ownership rule ----

    @Test
    fun `a success reported by a Mac we have unpaired from is never a confirmation`() {
        assertEquals(SendAck.CONFIRM, sendAck(ok = true, tokenIsCurrent = true))
        assertEquals(SendAck.RETRY, sendAck(ok = false, tokenIsCurrent = true))
        // The misroute: ok, but from the previous pairing.
        assertEquals(SendAck.REQUEUE_STALE, sendAck(ok = true, tokenIsCurrent = false))
        assertEquals(SendAck.REQUEUE_STALE, sendAck(ok = false, tokenIsCurrent = false))
    }

    @Test
    fun `the pre-fix handler took exactly the disposition this fix withholds`() {
        // Pre-fix there was no notion of endpoint ownership: any `ok` set UPLOADED and scheduled the local
        // delete, i.e. it took CONFIRM unconditionally. Ownership is the only thing separating the two.
        assertEquals(SendAck.CONFIRM, sendAck(ok = true, tokenIsCurrent = true))
        assertEquals(SendAck.REQUEUE_STALE, sendAck(ok = true, tokenIsCurrent = false))
    }

    @Test
    fun `rotating the pairing invalidates every token minted before it`() {
        val pairing = PairingGeneration()
        val beforeRepair = pairing.current
        assertTrue(pairing.isCurrent(beforeRepair))

        val afterRepair = pairing.rotate()

        assertFalse("a send stamped by the previous pairing must not read as current",
            pairing.isCurrent(beforeRepair))
        assertTrue(pairing.isCurrent(afterRepair))
        // Unpair then pair again: two rotations, and the original token is still stale.
        pairing.rotate()
        assertFalse(pairing.isCurrent(beforeRepair))
        assertFalse(pairing.isCurrent(afterRepair))
    }

    @Test
    fun `only one send per page is outstanding, even across a re-pair`() {
        val outstanding = OutstandingSends<Long>()
        assertTrue(outstanding.claim(1L, generation = 0))

        // The retired send is still on the wire holding the file: a second coroutine for the same page
        // would break the cancel-and-join guarantee the delete path depends on (W23.h4).
        assertFalse(outstanding.claim(1L, generation = 1))
        assertTrue(outstanding.contains(1L))
    }

    @Test
    fun `a retired send cannot release the claim the current endpoint is holding`() {
        val outstanding = OutstandingSends<Long>()
        outstanding.claim(1L, generation = 0)
        assertTrue(outstanding.release(1L, generation = 0))

        assertTrue(outstanding.claim(1L, generation = 1))
        // The old coroutine finally unwinds and releases — with ITS generation. It must not free the live
        // send's guard (which would let a third coroutine start against the same file).
        assertFalse(outstanding.release(1L, generation = 0))
        assertTrue(outstanding.contains(1L))
        assertTrue(outstanding.release(1L, generation = 1))
        assertFalse(outstanding.contains(1L))
    }

    @Test
    fun `a segment completion acked by the old Mac stays queued for the new one`() {
        val endedSegments = linkedMapOf("g1" to "priority=P10")
        val pairing = PairingGeneration()
        val token = pairing.current

        pairing.rotate()   // the operator re-pairs while the completion signal is on the wire
        if (sendAck(ok = true, tokenIsCurrent = pairing.isCurrent(token)) == SendAck.CONFIRM) {
            endedSegments.remove("g1")
        }

        assertTrue("the newly paired Mac never heard of this segment — its signal must stay queued",
            endedSegments.containsKey("g1"))
    }

    // ---- the sequence that produced the misroute ----

    @Test
    fun `the old Mac's ack cannot delete the phone copy, and the page then reaches the new Mac`() = runBlocking<Unit> {
        val page = PhonePage(tempJpeg())
        val oldMac = FakeMac()
        val newMac = FakeMac()
        val queue = UploadQueue(this)
        val onTheWire = CompletableDeferred<Unit>()
        val letItLand = CompletableDeferred<Unit>()

        queue.enqueue(page) { onTheWire.complete(Unit); letItLand.await(); oldMac.post("page-1") }
        val orphaned = queue.jobFor(page.id)!!
        onTheWire.await()

        // The operator re-pairs to a different Mac while that upload is still on the wire. Deliberately no
        // cancel here: this is the dangerous ordering, where the old Mac answers before cancellation lands.
        queue.repairWithoutCancelling()
        letItLand.complete(Unit)
        orphaned.join()

        assertEquals("the bytes did reach the old Mac — that part is inherent, not the defect",
            listOf("page-1"), oldMac.received)
        assertTrue("the phone's only copy must survive an ack from a Mac we are no longer paired with",
            page.file.exists())
        assertFalse(page.deletedLocally)
        assertEquals("an unconfirmed page must be sendable again, not left UPLOADING",
            UploadState.PENDING, page.state)
        assertFalse("the retired send must release its guard so the new endpoint can send",
            queue.isOutstanding(page.id))

        // The new pairing now delivers it for real.
        queue.enqueue(page) { newMac.post("page-1") }
        queue.jobFor(page.id)!!.join()

        assertEquals(listOf("page-1"), newMac.received)
        assertEquals(UploadState.UPLOADED, page.state)
        assertTrue("only the current Mac's ack may retire the phone copy", page.deletedLocally)
        assertFalse(page.file.exists())
    }

    @Test
    fun `a re-pair that cancels the upload still re-opens the page for the new endpoint`() = runBlocking<Unit> {
        val page = PhonePage(tempJpeg())
        val oldMac = FakeMac()
        val queue = UploadQueue(this)
        val onTheWire = CompletableDeferred<Unit>()
        val letItLand = CompletableDeferred<Unit>()

        queue.enqueue(page) { onTheWire.complete(Unit); letItLand.await(); oldMac.post("page-1") }
        val orphaned = queue.jobFor(page.id)!!
        onTheWire.await()

        queue.repair()          // rotate + cancel, as disconnect()/connect() now do
        letItLand.complete(Unit)
        orphaned.join()

        assertTrue("a cancelled send must not confirm anything", page.file.exists())
        assertFalse(page.deletedLocally)
        assertEquals("a page left UPLOADING would never be retried — neither resume nor auto-retry send it",
            UploadState.PENDING, page.state)
        assertFalse(queue.isOutstanding(page.id))
        assertTrue("the new pairing must be able to claim the page", queue.canEnqueue(page.id))
        page.file.delete()
    }
}

/** One page on the phone: its queue state and whether the local copy has been retired. */
private class PhonePage(val file: File, val id: Long = 1L) {
    var state: UploadState = UploadState.PENDING
    var deletedLocally: Boolean = false
}

private class FakeMac {
    val received = mutableListOf<String>()
    fun post(page: String): Boolean {
        received += page
        return true
    }
}

/**
 * The upload queue's ownership wiring, isolated from Android: the SAME [PairingGeneration],
 * [OutstandingSends] and [sendAck] the ViewModel uses, arranged exactly as `enqueueUpload` arranges them
 * (stamp the send with the current generation → decide with `sendAck` → release only our own claim → return
 * a page the pairing outlived to the queue). Kept in the test so the sequence can be interleaved
 * deterministically; the decisions themselves are the shipped ones.
 */
private class UploadQueue(private val scope: CoroutineScope) {
    private val pairing = PairingGeneration()
    private val outstanding = OutstandingSends<Long>()
    private val jobs = mutableMapOf<Long, Job>()

    fun isOutstanding(id: Long): Boolean = outstanding.contains(id)
    fun jobFor(id: Long): Job? = jobs[id]
    fun canEnqueue(id: Long): Boolean = !outstanding.contains(id)

    fun enqueue(page: PhonePage, send: suspend () -> Boolean) {
        val token = pairing.current
        if (!outstanding.claim(page.id, token)) return
        page.state = UploadState.UPLOADING
        val job = scope.launch {
            try {
                val ok = send()
                when (sendAck(ok, pairing.isCurrent(token))) {
                    SendAck.REQUEUE_STALE -> return@launch
                    SendAck.CONFIRM -> {
                        page.state = UploadState.UPLOADED
                        page.file.delete()
                        page.deletedLocally = true
                    }
                    SendAck.RETRY -> page.state = UploadState.FAILED
                }
            } finally {
                val wasOurs = outstanding.release(page.id, token)
                jobs.remove(page.id)
                if (wasOurs && !pairing.isCurrent(token)) page.state = UploadState.PENDING
            }
        }
        jobs[page.id] = job
    }

    /** disconnect() / a successful connect(): the previous endpoint owns nothing any more. */
    fun repair() {
        pairing.rotate()
        jobs.values.toList().forEach { it.cancel() }
    }

    /** The race the fix must survive on its own: the pairing rotates but the old send is already
     *  answering, so cancellation never gets the chance to stop it. */
    fun repairWithoutCancelling() {
        pairing.rotate()
    }
}
