package com.archiveprocessor.capture.net

import org.json.JSONObject

/** Connection info for the Mac receiver, decoded from the pairing QR JSON: {host, port, token, name}. */
data class MacEndpoint(
    val host: String,
    val port: Int,
    val token: String,
    val name: String
) {
    val baseUrl: String get() = "http://$host:$port"

    companion object {
        fun fromQrPayload(payload: String): MacEndpoint? = try {
            val o = JSONObject(payload)
            val host = o.getString("host")
            val port = o.getInt("port")
            val token = o.getString("token")
            if (host.isBlank() || token.isBlank() || port <= 0) null
            else MacEndpoint(host, port, token, o.optString("name", "Mac"))
        } catch (e: Exception) {
            null
        }
    }
}
