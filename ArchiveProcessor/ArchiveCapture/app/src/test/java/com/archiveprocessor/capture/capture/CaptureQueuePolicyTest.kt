package com.archiveprocessor.capture.capture

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureQueuePolicyTest {
    private fun item(id: Long, state: UploadState) = CapturedItem(
        id = id,
        file = File("page-$id.jpg"),
        groupId = "g1",
        seq = id.toInt(),
        type = GroupType.DOCUMENT,
        state = state
    )

    @Test
    fun `status count includes every state that is not confirmed uploaded`() {
        val items = listOf(
            item(1, UploadState.PENDING),
            item(2, UploadState.UPLOADING),
            item(3, UploadState.FAILED),
            item(4, UploadState.UPLOADED)
        )

        assertEquals(3, pendingReportCount(items))
    }

    @Test
    fun `automatically retryable failure blocks drained status until confirmation`() {
        val failed = item(1, UploadState.FAILED)
        assertEquals(1, pendingReportCount(listOf(failed)))
        assertEquals(0, pendingReportCount(listOf(failed.copy(state = UploadState.UPLOADED))))
    }

    @Test
    fun `deferred metadata resend never exposes a drained uploaded state`() {
        val staleConfirmation = item(1, UploadState.UPLOADED).copy(needsResend = true)
        assertEquals(1, pendingReportCount(listOf(staleConfirmation)))

        val pendingResend = staleConfirmation.prepareDeferredResend()
        assertEquals(UploadState.PENDING, pendingResend.state)
        assertEquals(false, pendingResend.needsResend)
        assertEquals(1, pendingReportCount(listOf(pendingResend)))
    }

    @Test
    fun `restore makes uploaded deferred resend sendable before pruning`() {
        val persistedBetweenSaves = item(1, UploadState.UPLOADED).copy(needsResend = true)

        val restored = persistedBetweenSaves.normalizeForRestore()

        assertEquals(UploadState.PENDING, restored.state)
        assertEquals(false, restored.needsResend)
        assertEquals(1, pendingReportCount(listOf(restored)))
    }

    @Test
    fun `camera callback from before clear is rejected by new generation`() {
        val token = captureStartToken(generation = 7, isClearing = false)
        assertEquals(7L, token)

        assertEquals(false, captureTokenIsCurrent(token!!, generation = 8, isClearing = false))
        assertEquals(false, captureTokenIsCurrent(8, generation = 8, isClearing = true))
        assertEquals(null, captureStartToken(generation = 8, isClearing = true))
        assertEquals(true, captureTokenIsCurrent(8, generation = 8, isClearing = false))
    }
}
