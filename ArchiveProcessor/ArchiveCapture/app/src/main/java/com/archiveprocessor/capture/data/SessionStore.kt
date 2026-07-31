package com.archiveprocessor.capture.data

import android.content.Context
import com.archiveprocessor.capture.capture.CapturedItem
import com.archiveprocessor.capture.capture.GroupType
import com.archiveprocessor.capture.capture.UploadState
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Crash-durable capture session. Persists every captured item + metadata + upload state so a
 *  phone crash/kill never loses photos or their grouping/tags. Rewritten (temp→rename) on change. */
class SessionStore internal constructor(
    private val dir: File,
    /** How a finished snapshot reaches disk. Injectable so a test can fail a publish the way a full or
     *  read-only filesystem does, without needing one. */
    private val publish: (File, ByteArray) -> Boolean = { f, bytes -> ManifestFileWriter.replace(f, bytes) }
) {
    constructor(context: Context) : this(context.filesDir)

    private val file = File(dir, "session.json")

    /** W23.m8 — the publish-in-progress flag. Created BEFORE a snapshot is written and removed only once
     *  that write is confirmed on disk, so finding it at launch means exactly one thing: the manifest we
     *  are about to restore is OLDER than the state the app last held. That matters because the recovery
     *  path re-adopts capture files the manifest doesn't mention, and against a stale manifest those files
     *  are not "untracked" at all — they are pages whose box/folder and tags went down with the write.
     *  Set-before-write rather than set-on-failure deliberately: a kill *during* the publish leaves the
     *  same older manifest behind, and must read the same way. (Durable against process death — the stated
     *  failure — not against power loss, which no unfsynced directory entry survives.) */
    private val staleMarker = File(dir, "session.stale")

    /** A document segment the operator has ended whose segment-complete signal the Mac hasn't acked yet.
     *  Persisted so an app-kill between End segment and the ack can't strand the document. */
    data class EndedSeg(val group: String, val priority: String?, val year: Int?, val month: Int?,
                        val seqs: String? = null)

    data class Restored(val items: List<CapturedItem>, val seq: Int, val nextId: Long, val groupId: String?,
                        val pendingTagGroupId: String?, val endedSegments: List<EndedSeg>)

    /** Publish a snapshot of the live session.
     *
     *  @return true only when THIS snapshot is durably on disk. False means the manifest still holds an
     *  older state — the caller is the only one that can see the difference, so it must treat what it holds
     *  in memory as un-persisted and say so. (Returning Unit here is what let a failed publish look
     *  identical to a successful one all the way up to the view model.) Never throws: a persistence hiccup
     *  must not take down the capture flow — but it must not be mistaken for success either. */
    fun save(items: List<CapturedItem>, seq: Int, nextId: Long, currentGroupId: String, pendingTagGroupId: String?,
             endedSegments: List<EndedSeg>): Boolean {
        markPublishInProgress()
        val published = try {
            val arr = JSONArray()
            for (it in items) {
                arr.put(JSONObject().apply {
                    put("id", it.id)
                    put("path", it.file.path)
                    put("groupId", it.groupId)
                    put("seq", it.seq)
                    put("type", it.type.name)
                    put("state", it.state.name)
                    it.priority?.let { v -> put("priority", v) }
                    it.year?.let { v -> put("year", v) }
                    it.month?.let { v -> put("month", v) }
                    it.replacesGroupId?.let { v -> put("replacesGroupId", v) }
                    if (it.needsResend) put("needsResend", true)
                    if (it.savedToPhone) put("savedToPhone", true)
                    // The hold on a page recovered against a stale manifest outlives the process that
                    // imposed it — otherwise the next kill releases it to the Mac unclassified.
                    if (it.needsReview) put("needsReview", true)
                })
            }
            val ended = JSONArray()
            for (e in endedSegments) {
                ended.put(JSONObject().apply {
                    put("group", e.group)
                    e.priority?.let { v -> put("priority", v) }
                    e.year?.let { v -> put("year", v) }
                    e.month?.let { v -> put("month", v) }
                    e.seqs?.let { v -> put("seqs", v) }
                })
            }
            val root = JSONObject().apply {
                put("items", arr)
                put("seq", seq)
                put("nextId", nextId)
                put("group", currentGroupId)
                if (pendingTagGroupId != null) put("pendingTag", pendingTagGroupId)
                if (ended.length() > 0) put("ended", ended)
            }
            publish(file, root.toString().toByteArray(Charsets.UTF_8))
        } catch (e: Exception) {
            // Never crash the capture flow because of a persistence hiccup — and never call it saved.
            false
        }
        if (published) clearPublishInProgress()
        return published
    }

    /** True when the manifest on disk is known to be older than the state the app last held (a publish
     *  failed, or the process died inside one). Read it BEFORE anything can persist — the first successful
     *  save of the new process clears it. */
    fun manifestIsStale(): Boolean = staleMarker.exists()

    private fun markPublishInProgress() {
        runCatching {
            dir.mkdirs()
            if (!staleMarker.exists()) staleMarker.createNewFile()
        }
    }

    private fun clearPublishInProgress() {
        runCatching { staleMarker.delete() }
    }

    fun load(): Restored? {
        if (!file.exists()) return null
        return try {
            val root = JSONObject(file.readText())
            val arr = root.getJSONArray("items")
            val items = ArrayList<CapturedItem>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val f = File(o.getString("path"))
                if (!f.exists()) continue   // image file gone — skip (nothing to send)
                items.add(
                    CapturedItem(
                        id = o.getLong("id"),
                        file = f,
                        groupId = o.getString("groupId"),
                        seq = o.getInt("seq"),
                        type = GroupType.valueOf(o.getString("type")),
                        priority = if (o.has("priority")) o.getString("priority") else null,
                        year = if (o.has("year")) o.getInt("year") else null,
                        month = if (o.has("month")) o.getInt("month") else null,
                        state = UploadState.valueOf(o.getString("state")),
                        replacesGroupId = if (o.has("replacesGroupId")) o.getString("replacesGroupId") else null,
                        needsResend = o.optBoolean("needsResend", false),
                        savedToPhone = o.optBoolean("savedToPhone", false),
                        needsReview = o.optBoolean("needsReview", false)
                    )
                )
            }
            val nextId = root.optLong("nextId", (items.maxOfOrNull { it.id } ?: 0L) + 1L)
            val ended = ArrayList<EndedSeg>()
            if (root.has("ended")) {
                val ea = root.getJSONArray("ended")
                for (i in 0 until ea.length()) {
                    val o = ea.getJSONObject(i)
                    ended.add(EndedSeg(
                        group = o.getString("group"),
                        priority = if (o.has("priority")) o.getString("priority") else null,
                        year = if (o.has("year")) o.getInt("year") else null,
                        month = if (o.has("month")) o.getInt("month") else null,
                        seqs = if (o.has("seqs")) o.getString("seqs") else null))
                }
            }
            Restored(items, root.optInt("seq", items.size), nextId,
                if (root.has("group")) root.getString("group") else null,
                if (root.has("pendingTag")) root.getString("pendingTag") else null,
                ended)
        } catch (e: Exception) {
            null
        }
    }

    fun clear() {
        file.delete()
        // A session that no longer exists has nothing to be stale about; leaving the flag would make the
        // next launch quarantine a fresh session's own photos.
        staleMarker.delete()
    }
}
