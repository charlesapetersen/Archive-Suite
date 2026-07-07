package com.archiveprocessor.capture.net

/**
 * The narrow phone→Mac transfer surface the durable upload queue depends on, abstracted so a
 * non-HTTP transport (the planned Google Drive cloud relay) can be dropped in without touching the
 * queue, retry, dedup, or capture logic. [MacClient] (direct HTTP to the Mac's `CaptureServer`) is
 * the default implementation; a `DriveRelayTransport` will be a second one.
 *
 * These are exactly the methods `CaptureViewModel` invokes on its stored `client`. Pairing-time
 * reachability classification stays on the concrete [MacClient] for now (it is HTTP-specific); it
 * joins this interface when the cloud transport needs a generic connect preflight.
 *
 * Contract every implementation MUST uphold (the "never lose a photo" invariant): [postPhoto]
 * returns `true` ONLY once the Mac holds the bytes durably (idempotent on `(group, seq)`), so the
 * queue marks an item UPLOADED — and drops the phone's only copy — solely on a confirmed `true`.
 */
interface SegmentTransport {
    /** Deliver one page's JPEG with its grouping + minimal-tag metadata. `true` = durably received. */
    fun postPhoto(
        jpeg: ByteArray, group: String, seq: Int, type: String,
        priority: String?, year: Int?, month: Int?, device: String,
        replaces: String? = null
    ): Boolean

    /** Signal that a document segment is complete and carry its tags (no image bytes). Idempotent. */
    fun segmentComplete(group: String, priority: String?, year: Int?, month: Int?): Boolean

    /** Report how many photos are still un-sent on the phone (a heartbeat), so the Mac can tell the
     *  operator "the phone still has N photos to send" at Finish. Best-effort; the default is a no-op for
     *  transports that don't carry it (the file relays), so only the HTTP [MacClient] implements it. */
    fun reportStatus(pending: Int): Boolean = true

    /** Signal the capture session is finished (flush any still-open segment on the Mac). */
    fun sessionComplete(): Boolean

    /** Best-effort notice that the phone is re-pairing, so the Mac can re-show its pairing QR. */
    fun sessionDisconnect(): Boolean
}
