package com.archiveprocessor.capture.data

import com.archiveprocessor.capture.capture.CapturedItem
import com.archiveprocessor.capture.capture.GroupType
import com.archiveprocessor.capture.capture.UploadState
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * W23.m8 — `SessionStore.save` used to return Unit, discard [ManifestFileWriter]'s Boolean and swallow
 * exceptions, so a snapshot that never reached disk was indistinguishable from one that did. These run on
 * a plain JVM against a real scratch directory (`Files.createTempDirectory`) — no device, no emulator, and
 * nothing outside the temp dir is touched.
 */
class SessionStoreTest {
    private val scratch: File = Files.createTempDirectory("session-store-test").toFile()

    @After fun cleanUp() { scratch.deleteRecursively() }

    private fun page(
        id: Long,
        group: String = "gAAA",
        seq: Int = 1,
        needsReview: Boolean = false
    ) = CapturedItem(
        id = id, file = File(scratch, "img_$id.jpg"), groupId = group, seq = seq,
        type = GroupType.DOCUMENT, quality = "Q2", year = 1971, month = 4,
        state = UploadState.UPLOADED, replacesGroupId = "gOLD", needsResend = true,
        savedToPhone = true, needsReview = needsReview
    )

    /** [SessionStore.load] drops any item whose JPEG is gone, so a round-trip test needs the bytes there. */
    private fun withFilesOnDisk(items: List<CapturedItem>): List<CapturedItem> =
        items.onEach { it.file.writeBytes(byteArrayOf(0xFF.toByte(), 0xD8.toByte())) }

    private fun store(publish: ((File, ByteArray) -> Boolean)? = null) =
        if (publish == null) SessionStore(scratch) else SessionStore(scratch, publish)

    private fun save(
        store: SessionStore,
        items: List<CapturedItem>,
        group: String = "gAAA",
        pendingTag: String? = null,
        ended: List<SessionStore.EndedSeg> = emptyList()
    ): Boolean = store.save(items, items.size, items.size + 1L, group, pendingTag, ended)

    private val marker get() = File(scratch, "session.stale")
    private val manifest get() = File(scratch, "session.json")

    // ---- The result is now the truth about the disk ----

    @Test fun `a published snapshot reports success and round-trips`() {
        val items = withFilesOnDisk(listOf(page(1), page(2, group = "gBBB", seq = 2)))
        val s = store()

        assertTrue(save(s, items, group = "gBBB", pendingTag = "gBBB",
            ended = listOf(SessionStore.EndedSeg("gAAA", "Q1", 1971, 4, "1"))))

        val restored = s.load()
        assertNotNull(restored)
        assertEquals(2, restored!!.items.size)
        assertEquals("gBBB", restored.groupId)
        assertEquals("gBBB", restored.pendingTagGroupId)
        assertEquals(listOf("gAAA"), restored.endedSegments.map { it.group })
        val first = restored.items.first()
        assertEquals("Q2", first.quality)
        assertEquals(1971, first.year)
        assertEquals("gOLD", first.replacesGroupId)
        assertTrue(first.needsResend)
        assertTrue(first.savedToPhone)
    }

    @Test fun `a failed publish reports failure instead of silence`() {
        val s = store { _, _ -> false }
        assertFalse(save(s, withFilesOnDisk(listOf(page(1)))))
    }

    @Test fun `a publish that throws is still reported as a failure, not propagated`() {
        // The capture flow must never crash on a persistence hiccup — but must not read it as success.
        val s = store { _, _ -> throw IOException("injected publish failure") }
        assertFalse(save(s, withFilesOnDisk(listOf(page(1)))))
    }

    @Test fun `an unwritable destination is a reported failure, not a thrown one`() {
        // A regular file where the parent directory belongs: mkdirs() can't fix it and createTempFile
        // throws — the real path that used to escape ManifestFileWriter uncaught.
        val blocked = File(scratch, "blocked")
        blocked.mkdirs()
        File(blocked, "nested").writeText("i am a file, not a directory")
        val s = SessionStore(File(blocked, "nested"))
        assertFalse(save(s, withFilesOnDisk(listOf(page(1)))))
    }

    @Test fun `a failed publish leaves the previous manifest readable`() {
        val items = withFilesOnDisk(listOf(page(1)))
        val s = store()
        assertTrue(save(s, items, group = "gGOOD"))

        val failing = store { _, _ -> false }
        assertFalse(save(failing, items, group = "gNEVER"))

        assertEquals("gGOOD", s.load()?.groupId)
    }

    // ---- Staleness survives the process that discovered it ----

    @Test fun `a failed publish is still detectable after a restart`() {
        val s = store { _, _ -> false }
        assertFalse(save(s, withFilesOnDisk(listOf(page(1)))))

        // A brand-new SessionStore == a fresh process reading the same filesDir.
        assertTrue(SessionStore(scratch).manifestIsStale())
    }

    @Test fun `a successful publish leaves nothing stale`() {
        val s = store()
        assertTrue(save(s, withFilesOnDisk(listOf(page(1)))))
        assertFalse(SessionStore(scratch).manifestIsStale())
    }

    @Test fun `a later successful publish clears an earlier failure`() {
        val items = withFilesOnDisk(listOf(page(1)))
        assertFalse(save(store { _, _ -> false }, items))
        assertTrue(SessionStore(scratch).manifestIsStale())

        assertTrue(save(store(), items))
        assertFalse(SessionStore(scratch).manifestIsStale())
    }

    @Test fun `a first-ever publish failure is stale even with no manifest at all`() {
        // load() returns null here, so the staleness signal cannot live on Restored: the photos on disk
        // are exactly the ones the orphan sweep would otherwise adopt as if they were untracked.
        val s = store { _, _ -> false }
        assertFalse(save(s, withFilesOnDisk(listOf(page(1)))))
        assertNull(s.load())
        assertTrue(s.manifestIsStale())
    }

    @Test fun `the flag is set BEFORE the write, so a kill mid-publish reads as stale`() {
        // The crash window this whole mechanism exists for: the process dies between "about to replace the
        // manifest" and "replaced it". Set-on-failure would miss it; set-before-write cannot.
        var markerDuringPublish: Boolean? = null
        val s = store { f, bytes ->
            markerDuringPublish = marker.exists()
            ManifestFileWriter.replace(f, bytes)
        }
        assertTrue(save(s, withFilesOnDisk(listOf(page(1)))))
        assertEquals(true, markerDuringPublish)
        assertFalse(marker.exists())   // …and cleared once the write is confirmed
    }

    @Test fun `clear removes both the manifest and the staleness flag`() {
        val items = withFilesOnDisk(listOf(page(1)))
        assertFalse(save(store { _, _ -> false }, items))
        assertTrue(marker.exists())

        val s = store()
        s.clear()
        assertFalse(manifest.exists())
        assertFalse(s.manifestIsStale())
    }

    // ---- The hold outlives the process that imposed it ----

    @Test fun `a held page is still held after a restart`() {
        val items = withFilesOnDisk(listOf(page(1, needsReview = true), page(2, seq = 2)))
        assertTrue(save(store(), items))

        val restored = SessionStore(scratch).load()!!.items.associateBy { it.id }
        assertTrue(restored.getValue(1L).needsReview)
        assertFalse(restored.getValue(2L).needsReview)
    }
}
