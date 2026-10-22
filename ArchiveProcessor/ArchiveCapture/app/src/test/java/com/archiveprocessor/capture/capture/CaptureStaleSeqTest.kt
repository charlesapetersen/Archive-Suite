package com.archiveprocessor.capture.capture

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * W40.fix-android-stale-seq — a stale session file restores the current group with a seq counter that can
 * lag pages already sent into that group. The Mac keys on (group, seq), so reusing one replaces a page.
 */
class CaptureStaleSeqTest {
    @Test fun `a trustworthy restore carries on from the file's counter`() {
        assertEquals(5, seqAfterRestore(5, manifestStale = false))
    }

    /** The file was last published at seq 5; pages 6..8 were then shot into gCUR and sent, and page 7 was
     *  deleted on the phone, before the app died with the next publish unwritten. gCUR is restored as
     *  current; only 6 and 8 are left on disk to adopt, so adoption alone moves the counter to 7. */
    private fun nextSeqIntoRestoredGroup(manifestStale: Boolean): Int {
        var seq = seqAfterRestore(5, manifestStale)
        val adopted = adoptOrphans(listOf(File("/tmp/img_0006.jpg"), File("/tmp/img_0008.jpg")), emptySet(),
            firstId = 6L, firstSeq = seq + 1, groupId = "gREC", manifestStale = manifestStale)
        seq += adopted.size
        return seq + 1
    }

    @Test fun `a stale restore never reuses a seq already sent to the restored group`() {
        val sentToMac = (1..8).toSet()   // gCUR's seqs on the Mac
        val next = nextSeqIntoRestoredGroup(manifestStale = true)
        assertTrue("gCUR seq $next would replace a page the Mac holds", next !in sentToMac)
    }

    @Test fun `without the margin the same restore reuses one - the scenario is real`() {
        assertEquals(8, nextSeqIntoRestoredGroup(manifestStale = false))
    }

    @Test fun `the margin matches iOS`() {
        assertEquals(10_000, STALE_SEQ_MARGIN)   // CaptureQueue.staleSeqMargin
    }
}
