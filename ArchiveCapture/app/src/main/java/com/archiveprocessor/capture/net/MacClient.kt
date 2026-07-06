package com.archiveprocessor.capture.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** Why a pairing attempt failed — so the UI can name the cause + the fix instead of a bare "couldn't
 *  reach". UNREACHABLE = timeout / no route (the client-isolation case); REFUSED = reached the network
 *  but nothing listening (server not started / wrong port); UNAUTHORIZED = reached the Mac, bad token. */
enum class Reachability { OK, UNAUTHORIZED, REFUSED, UNREACHABLE }

/** Protocol v2 client for the Archive Processor Live Capture receiver (raw JPEG body + X-* headers). */
class MacClient(private val endpoint: MacEndpoint) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .build()
    // Short-timeout client for the pre-pairing reachability probe only (fast, honest failure); the
    // 30s upload timeout above is untouched so large photo POSTs still have time.
    private val preflight = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .callTimeout(4, TimeUnit.SECONDS)
        .build()

    private fun auth() = "Bearer ${endpoint.token}"

    fun ping(): Boolean = try {
        val req = Request.Builder().url("${endpoint.baseUrl}/ping")
            .header("Authorization", auth()).get().build()
        client.newCall(req).execute().use { it.isSuccessful }
    } catch (e: Exception) {
        false
    }

    /** Classify reachability of the Mac for a clear pairing diagnostic (short timeout). */
    fun reachability(): Reachability = try {
        val req = Request.Builder().url("${endpoint.baseUrl}/ping")
            .header("Authorization", auth()).get().build()
        preflight.newCall(req).execute().use { resp ->
            when {
                resp.isSuccessful -> Reachability.OK
                resp.code == 401 -> Reachability.UNAUTHORIZED
                else -> Reachability.REFUSED
            }
        }
    } catch (e: java.net.SocketTimeoutException) {
        Reachability.UNREACHABLE               // black-holed SYN — the AP-isolation signature
    } catch (e: java.net.ConnectException) {
        Reachability.REFUSED                   // RST — reachable host, nothing listening
    } catch (e: Exception) {
        Reachability.UNREACHABLE               // no route / unknown host → treat as unreachable
    }

    /** POST one JPEG (raw body) with grouping + minimal-tag headers. Returns true on 2xx. */
    fun postPhoto(
        jpeg: ByteArray, group: String, seq: Int, type: String,
        priority: String?, year: Int?, month: Int?, device: String,
        replaces: String? = null
    ): Boolean = try {
        val body = jpeg.toRequestBody("image/jpeg".toMediaType())
        val b = Request.Builder().url("${endpoint.baseUrl}/photo")
            .header("Authorization", auth())
            .header("X-Group", group)
            .header("X-Seq", seq.toString())
            .header("X-Type", type)
            .header("X-Device", device)
        if (!priority.isNullOrBlank()) b.header("X-Priority", priority)
        if (year != null) b.header("X-Year", year.toString())
        if (month != null) b.header("X-Month", month.toString())
        // The old group this photo replaces (reclassify) — the Mac drops the orphaned old copy.
        if (!replaces.isNullOrBlank()) b.header("X-Replaces", replaces)
        client.newCall(b.post(body).build()).execute().use { it.isSuccessful }
    } catch (e: Exception) {
        false
    }

    fun sessionComplete(): Boolean = try {
        val req = Request.Builder().url("${endpoint.baseUrl}/session/complete")
            .header("Authorization", auth())
            .post(ByteArray(0).toRequestBody(null)).build()
        client.newCall(req).execute().use { it.isSuccessful }
    } catch (e: Exception) {
        false
    }

    /** End of a document segment: pages already streamed in via postPhoto; this tells the Mac the group
     *  is complete (so its tag card can appear) and carries the segment's tags. No image bytes. */
    fun segmentComplete(group: String, priority: String?, year: Int?, month: Int?): Boolean = try {
        val b = Request.Builder().url("${endpoint.baseUrl}/segment/complete")
            .header("Authorization", auth())
            .header("X-Group", group)
        if (!priority.isNullOrBlank()) b.header("X-Priority", priority)
        if (year != null) b.header("X-Year", year.toString())
        if (month != null) b.header("X-Month", month.toString())
        client.newCall(b.post(ByteArray(0).toRequestBody(null)).build()).execute().use { it.isSuccessful }
    } catch (e: Exception) {
        false
    }

    /** Best-effort notice that the phone is re-pairing, so the Mac re-shows the pairing QR instead of
     *  sitting on a stale "paired" state. Fire-and-forget (may not reach the Mac if the link is already down). */
    fun sessionDisconnect(): Boolean = try {
        val req = Request.Builder().url("${endpoint.baseUrl}/session/disconnect")
            .header("Authorization", auth())
            .post(ByteArray(0).toRequestBody(null)).build()
        client.newCall(req).execute().use { it.isSuccessful }
    } catch (e: Exception) {
        false
    }
}
