package com.archiveprocessor.capture.data

import android.content.Context
import com.archiveprocessor.capture.net.MacEndpoint

/** Lightweight persistence: the paired Mac endpoint + recently used years (for quick date chips). */
class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("archivecapture", Context.MODE_PRIVATE)

    fun saveEndpoint(e: MacEndpoint) {
        sp.edit().putString("host", e.host).putInt("port", e.port)
            .putString("token", e.token).putString("name", e.name).apply()
    }

    fun loadEndpoint(): MacEndpoint? {
        val host = sp.getString("host", null) ?: return null
        val token = sp.getString("token", null) ?: return null
        val port = sp.getInt("port", 0)
        if (port <= 0) return null
        return MacEndpoint(host, port, token, sp.getString("name", "Mac") ?: "Mac")
    }

    fun clearEndpoint() {
        sp.edit().remove("host").remove("port").remove("token").remove("name").apply()
    }

    /** Recent years, most-recent first (max 6). Months are intentionally NOT tracked (no recency bias). */
    fun recentYears(): List<Int> =
        (sp.getString("recentYears", "") ?: "").split(",").mapNotNull { it.toIntOrNull() }

    fun noteYear(year: Int) {
        val list = (listOf(year) + recentYears()).distinct().take(6)
        sp.edit().putString("recentYears", list.joinToString(",")).apply()
    }
}
