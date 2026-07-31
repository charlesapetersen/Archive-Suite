package com.archiveprocessor.capture.capture

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * W23.m8 — the recovery sweep re-adopts capture files the restored session doesn't mention. Against a
 * manifest that is known to be older than the state that produced those files, the adoption's default
 * Document group is a classification nobody chose, and sending it files the page wrongly on the Mac.
 */
class CaptureOrphanAdoptionTest {
    private fun orphan(stale: Boolean) =
        adoptedOrphan(id = 7L, file = File("/tmp/img_0007.jpg"), groupId = "gREC", seq = 3, manifestStale = stale)

    @Test fun `against a trustworthy manifest an orphan is adopted and sent exactly as before`() {
        val item = orphan(stale = false)
        assertEquals(GroupType.DOCUMENT, item.type)
        assertEquals("gREC", item.groupId)
        assertEquals(3, item.seq)
        assertEquals(UploadState.PENDING, item.state)
        assertFalse(item.needsReview)
        assertTrue(isSendable(item))
    }

    @Test fun `against a stale manifest the same orphan is adopted but held`() {
        val item = orphan(stale = true)
        assertTrue(item.needsReview)
        assertFalse(isSendable(item))
        // Adopted, not dropped: an archival photo can't be re-taken, so it must still be visible + kept.
        assertEquals(File("/tmp/img_0007.jpg"), item.file)
        assertEquals(GroupType.DOCUMENT, item.type)
    }

    @Test fun `a held page still counts as one the Mac must wait for`() {
        // Otherwise the heartbeat reports zero un-sent pages and the Mac can finish the session without it.
        assertEquals(1, pendingReportCount(listOf(orphan(stale = true))))
    }

    @Test fun `a held page still requires delete confirmation`() {
        // It exists ONLY on the phone — the strongest case for the confirm-before-delete gesture.
        assertTrue(requiresDeleteConfirmation(orphan(stale = true)))
    }

    @Test fun `review releases the page for sending`() {
        val reviewed = orphan(stale = true).copy(needsReview = false, priority = "P2", year = 1971, month = 4)
        assertTrue(isSendable(reviewed))
    }

    @Test fun `nothing else in the queue is withheld`() {
        val ordinary = CapturedItem(id = 1L, file = File("/tmp/img_0001.jpg"), groupId = "gAAA", seq = 1,
            type = GroupType.DOCUMENT, state = UploadState.FAILED, needsResend = true)
        assertTrue(isSendable(ordinary))
    }
}
