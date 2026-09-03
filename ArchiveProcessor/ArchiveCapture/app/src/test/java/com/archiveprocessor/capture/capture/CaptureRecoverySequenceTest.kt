package com.archiveprocessor.capture.capture

import com.archiveprocessor.capture.data.SessionStore
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * W23.m8 — the failure end to end, over a real scratch filesDir: a session is published, a later snapshot
 * fails to publish, the process dies, and the next launch re-adopts the photos the lost snapshot described.
 *
 * This drives the SAME pieces the view model does — a real [SessionStore] against real files, plus the real
 * [adoptOrphans] / [isSendable] policy — rather than restating their logic, so neutering either half turns
 * these red. What it deliberately does NOT cover is Compose rendering and the view model's own wiring
 * lines; the app has no instrumentation-test target, so those are compiler- and inspection-level only.
 */
class CaptureRecoverySequenceTest {
    private val filesDir: File = Files.createTempDirectory("capture-recovery-test").toFile()
    private val sessionDir: File = File(filesDir, "capture").apply { mkdirs() }

    @After fun cleanUp() { filesDir.deleteRecursively() }

    private fun shoot(name: String): File =
        File(sessionDir, name).apply { writeBytes(byteArrayOf(0xFF.toByte(), 0xD8.toByte())) }

    private fun page(id: Long, file: File, group: String, seq: Int) = CapturedItem(
        id = id, file = file, groupId = group, seq = seq, type = GroupType.DOCUMENT,
        quality = "Q1", year = 1971, month = 4, state = UploadState.UPLOADED
    )

    private fun save(store: SessionStore, items: List<CapturedItem>, group: String) =
        store.save(items, items.size, items.size + 1L, group, null, emptyList())

    /** The recovery sweep exactly as [CaptureViewModel] runs it: everything `img_*` on disk, minus what the
     *  restored session already accounts for. */
    private fun sweep(restored: SessionStore.Restored?, store: SessionStore, group: String): List<CapturedItem> {
        val known = (restored?.items ?: emptyList()).map { it.file.path }.toHashSet()
        val onDisk = sessionDir.listFiles { f -> f.isFile && f.name.startsWith("img_") }
            ?.sortedBy { it.name } ?: emptyList()
        return adoptOrphans(onDisk.toList(), known,
            firstId = restored?.nextId ?: 1L, firstSeq = (restored?.seq ?: 0) + 1,
            groupId = group, manifestStale = store.manifestIsStale())
    }

    @Test fun `a lost snapshot leaves the next launch holding its photos instead of misfiling them`() {
        // 1. A real, published session: two pages of box "gBOX", classified.
        val first = shoot("img_0001.jpg")
        val second = shoot("img_0002.jpg")
        val committed = listOf(page(1, first, "gBOX", 1), page(2, second, "gBOX", 2))
        assertTrue(save(SessionStore(filesDir), committed, "gBOX"))

        // 2. A third page is shot into the same classified segment — and its snapshot never lands.
        val third = shoot("img_0003.jpg")
        val failing = SessionStore(filesDir) { _, _ -> false }
        assertFalse(save(failing, committed + page(3, third, "gBOX", 3), "gBOX"))

        // 3. The app dies. A new process restores what IS on disk: the two-page manifest, not the three.
        val restarted = SessionStore(filesDir)
        val restored = restarted.load()!!
        assertEquals(listOf(1L, 2L), restored.items.map { it.id })
        assertTrue(restarted.manifestIsStale())

        // 4. The sweep finds the third page. It is kept — an archival photo can't be re-taken — but it is
        //    NOT sendable: "document page, group gREC, no box, no date" is a classification nobody chose,
        //    and the Mac would file it into the archive under exactly that.
        val adopted = sweep(restored, restarted, "gREC")
        assertEquals(listOf(third), adopted.map { it.file })
        assertTrue(adopted.single().needsReview)
        assertFalse(isSendable(adopted.single()))
        assertTrue(third.exists())

        // 5. The pages the manifest DOES account for are unaffected — recovery withholds nothing else.
        assertTrue(restored.items.all { isSendable(it) })

        // 6. Review supplies the classification (what finalizeSegment stamps), and only then does it send.
        val reviewed = adopted.single().copy(needsReview = false, quality = "Q1", year = 1971, month = 4)
        assertTrue(isSendable(reviewed))

        // 7. The hold is durable in its own right: persisting it and reloading in yet another process keeps
        //    it held, so a second kill can't be what releases it.
        assertTrue(save(SessionStore(filesDir), restored.items + adopted, "gREC"))
        val secondRestart = SessionStore(filesDir).load()!!
        assertEquals(1, secondRestart.items.count { it.needsReview })
        assertEquals(third, secondRestart.items.first { it.needsReview }.file)
        // …and that successful save is what clears the staleness, so the NEXT sweep holds nothing.
        assertFalse(SessionStore(filesDir).manifestIsStale())
    }

    @Test fun `a trustworthy manifest still self-heals untracked photos exactly as before`() {
        // The pre-existing behaviour this must not regress: session.json can simply lag a capture. Nothing
        // failed, so the recovery segment is an honest description and the page uploads on its own.
        val tracked = shoot("img_0001.jpg")
        assertTrue(save(SessionStore(filesDir), listOf(page(1, tracked, "gBOX", 1)), "gBOX"))
        val lagging = shoot("img_0002.jpg")

        val restarted = SessionStore(filesDir)
        val restored = restarted.load()!!
        assertFalse(restarted.manifestIsStale())

        val adopted = sweep(restored, restarted, "gREC")
        assertEquals(listOf(lagging), adopted.map { it.file })
        assertFalse(adopted.single().needsReview)
        assertTrue(isSendable(adopted.single()))
    }

    @Test fun `a first-ever save that never lands still holds everything it shot`() {
        // No manifest at all: load() is null, so the staleness signal has to come from the store itself.
        // Without it every photo of the session would be adopted as an unclassified default Document page.
        val a = shoot("img_0001.jpg")
        val b = shoot("img_0002.jpg")
        val failing = SessionStore(filesDir) { _, _ -> false }
        assertFalse(save(failing, listOf(page(1, a, "gBOX", 1), page(2, b, "gBOX", 2)), "gBOX"))

        val restarted = SessionStore(filesDir)
        assertEquals(null, restarted.load())
        val adopted = sweep(null, restarted, "gREC")
        assertEquals(listOf(a, b), adopted.map { it.file })
        assertTrue(adopted.all { it.needsReview })
        assertTrue(adopted.none { isSendable(it) })
        // Ids and seqs still advance in filename order, so nothing collides once they are released.
        assertEquals(listOf(1L, 2L), adopted.map { it.id })
        assertEquals(listOf(1, 2), adopted.map { it.seq })
    }

    @Test fun `a cleared session does not quarantine the photos of the next one`() {
        val stranded = shoot("img_0001.jpg")
        assertFalse(save(SessionStore(filesDir) { _, _ -> false }, listOf(page(1, stranded, "gBOX", 1)), "gBOX"))
        assertTrue(SessionStore(filesDir).manifestIsStale())

        SessionStore(filesDir).clear()

        val fresh = shoot("img_0009.jpg")
        val restarted = SessionStore(filesDir)
        assertFalse(restarted.manifestIsStale())
        assertTrue(sweep(null, restarted, "gREC").filter { it.file == fresh }.none { it.needsReview })
    }
}
