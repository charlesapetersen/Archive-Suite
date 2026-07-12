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
class SessionStore(context: Context) {
    private val file = File(context.filesDir, "session.json")

    /** A document segment the operator has ended whose segment-complete signal the Mac hasn't acked yet.
     *  Persisted so an app-kill between End segment and the ack can't strand the document. */
    data class EndedSeg(val group: String, val priority: String?, val year: Int?, val month: Int?,
                        val seqs: String? = null)

    data class Restored(val items: List<CapturedItem>, val seq: Int, val nextId: Long, val groupId: String?,
                        val pendingTagGroupId: String?, val endedSegments: List<EndedSeg>)

    fun save(items: List<CapturedItem>, seq: Int, nextId: Long, currentGroupId: String, pendingTagGroupId: String?,
             endedSegments: List<EndedSeg>) {
        try {
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
            ManifestFileWriter.replace(file, root.toString().toByteArray(Charsets.UTF_8))
        } catch (e: Exception) {
            // Never crash the capture flow because of a persistence hiccup.
        }
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
                        savedToPhone = o.optBoolean("savedToPhone", false)
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
    }
}
