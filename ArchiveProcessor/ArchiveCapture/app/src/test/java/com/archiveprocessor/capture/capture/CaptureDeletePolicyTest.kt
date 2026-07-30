package com.archiveprocessor.capture.capture

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * W23.h4 — the thumbnail tap → X → delete gesture used to destroy an un-uploaded archival page with no
 * confirmation and no upload-job cancel. These are the two halves of the guard, exercised headlessly:
 * WHICH items need a confirmation, and WHAT the confirmed delete is allowed to do to the bytes.
 *
 * Scratch only: every file here is an `mktemp`-style temp file in the JVM's temp dir. Nothing in this
 * test can see a corpus, a capture session, or the phone's gallery.
 */
class CaptureDeletePolicyTest {
    private fun item(state: UploadState, needsResend: Boolean = false) = CapturedItem(
        id = 1,
        file = File("page-1.jpg"),
        groupId = "g1",
        seq = 1,
        type = GroupType.DOCUMENT,
        state = state,
        needsResend = needsResend
    )

    private fun tempJpeg(): File =
        File.createTempFile("w23h4-", ".jpg").apply { writeBytes(byteArrayOf(1, 2, 3)); deleteOnExit() }

    // ---- (a) which deletes must be confirmed ----

    @Test
    fun `every state the Mac has not confirmed requires an explicit confirmation`() {
        assertTrue(requiresDeleteConfirmation(item(UploadState.PENDING)))
        assertTrue(requiresDeleteConfirmation(item(UploadState.UPLOADING)))
        assertTrue(requiresDeleteConfirmation(item(UploadState.FAILED)))
    }

    @Test
    fun `a confirmed upload deletes without a prompt, but a stale metadata resend does not`() {
        assertFalse(requiresDeleteConfirmation(item(UploadState.UPLOADED)))
        // Bytes are on the Mac but a field changed since, so this page is still queued to re-send —
        // treat it as un-sent, exactly as the heartbeat does.
        assertTrue(requiresDeleteConfirmation(item(UploadState.UPLOADED, needsResend = true)))
    }

    @Test
    fun `the confirmation predicate is the same one the un-sent heartbeat counts`() {
        val items = listOf(
            item(UploadState.PENDING),
            item(UploadState.UPLOADED),
            item(UploadState.UPLOADED, needsResend = true)
        )
        assertEquals(items.count { requiresDeleteConfirmation(it) }, pendingReportCount(items))
    }

    // ---- (c) what a confirmed delete may do to the bytes ----

    @Test
    fun `retiring to the gallery removes the local file only after the copy is written`() {
        val file = tempJpeg()
        var copiedWhileStillOnDisk = false

        val outcome = retireCaptureFile(file) { f -> copiedWhileStillOnDisk = f.exists(); true }

        assertEquals(DeleteOutcome.RETIRED_TO_GALLERY, outcome)
        assertTrue("the gallery copy must run against a file that still exists", copiedWhileStillOnDisk)
        assertFalse(file.exists())
    }

    @Test
    fun `a failed gallery copy KEEPS the photo instead of destroying the only copy`() {
        val file = tempJpeg()

        val outcome = retireCaptureFile(file) { false }

        assertEquals(DeleteOutcome.KEPT_RETIRE_FAILED, outcome)
        assertTrue("a page that could not be backed up must survive the delete", file.exists())
        file.delete()
    }

    @Test
    fun `delete permanently removes the file when the operator asks for it`() {
        val file = tempJpeg()

        val outcome = retireCaptureFile(file, retire = null)

        assertEquals(DeleteOutcome.DELETED, outcome)
        assertFalse(file.exists())
    }

    // ---- (b) the upload must be stopped before the bytes go away ----

    @Test
    fun `the in-flight upload is cancelled AND joined before the file is removed`() = runBlocking {
        val file = tempJpeg()
        val uploadSawMissingFile = AtomicBoolean(false)
        val fileExistedWhenUploadUnwound = AtomicReference<Boolean?>(null)
        val uploadStarted = CompletableDeferred<Unit>()

        // Stand-in for enqueueUpload's coroutine: it keeps opening the file, exactly the window the old
        // deleteItem raced. `finally` records what the file looked like at the moment it unwound.
        val uploadJob = launch(Dispatchers.IO) {
            try {
                uploadStarted.complete(Unit)
                while (isActive) {
                    if (!file.exists()) uploadSawMissingFile.set(true)
                    delay(1)
                }
            } finally {
                fileExistedWhenUploadUnwound.set(file.exists())
            }
        }
        uploadStarted.await()

        val outcome = retireCapture(uploadJob, file, retire = null)

        assertEquals(DeleteOutcome.DELETED, outcome)
        assertTrue("retireCapture must not return while the upload is still running", uploadJob.isCompleted)
        assertEquals("the upload must unwind BEFORE the bytes are removed", true, fileExistedWhenUploadUnwound.get())
        assertFalse("the upload must never observe a file the delete already removed", uploadSawMissingFile.get())
        assertFalse(file.exists())
    }

    @Test
    fun `a delete with no upload in flight still retires the file`() = runBlocking {
        val file = tempJpeg()

        val outcome = retireCapture(uploadJob = null, file = file, retire = { true })

        assertEquals(DeleteOutcome.RETIRED_TO_GALLERY, outcome)
        assertFalse(file.exists())
    }
}
