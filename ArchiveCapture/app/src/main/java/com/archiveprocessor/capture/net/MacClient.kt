package com.archiveprocessor.capture.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** Protocol v2 client for the Archive Processor Live Capture receiver (raw JPEG body + X-* headers). */
class MacClient(private val endpoint: MacEndpoint) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .build()

    private fun auth() = "Bearer ${endpoint.token}"

    fun ping(): Boolean = try {
        val req = Request.Builder().url("${endpoint.baseUrl}/ping")
            .header("Authorization", auth()).get().build()
        client.newCall(req).execute().use { it.isSuccessful }
    } catch (e: Exception) {
        false
    }

    /** POST one JPEG (raw body) with grouping + minimal-tag headers. Returns true on 2xx. */
    fun postPhoto(
        jpeg: ByteArray, group: String, seq: Int, type: String,
        priority: String?, year: Int?, month: Int?, device: String
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
}
