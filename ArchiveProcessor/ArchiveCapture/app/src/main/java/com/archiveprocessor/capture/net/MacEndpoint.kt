package com.archiveprocessor.capture.net

import org.json.JSONObject

/**
 * Connection info for the Mac receiver.
 *
 * - **LAN/USB** (`mode = "lan"`): decoded from the pairing QR `{host, port, token, name}`; the phone talks
 *   HTTP to `baseUrl`. `token` is the Bearer pairing code.
 * - **Cloud** (`mode = "cloud"`): decoded from the cloud pairing QR `{mode:"cloud", token, name, account?}`;
 *   `host`/`port` are unused. `token` is the **relay/session token** — the same value the Mac writes as the
 *   Drive folder's `appProperties.relayToken` and into `_epoch.json`, which `DriveRelayTransport` uses to
 *   self-discover the shared folder. `account` is an optional Google-account email hint for sign-in.
 */
data class MacEndpoint(
    val host: String,
    val port: Int,
    val token: String,
    val name: String,
    val mode: String = "lan",
    val account: String? = null
) {
    val baseUrl: String get() = "http://$host:$port"
    val isCloud: Boolean get() = mode == "cloud"

    companion object {
        fun fromQrPayload(payload: String): MacEndpoint? {
            return try {
                val o = JSONObject(payload)
                val token = o.optString("token", "")
                if (token.isBlank()) return null
                val name = o.optString("name", "Mac")
                if (o.optString("mode", "lan") == "cloud") {
                    MacEndpoint("", 0, token, name, "cloud", o.optString("account", "").ifBlank { null })
                } else {
                    val host = o.optString("host", "")
                    val port = o.optInt("port", 0)
                    if (host.isBlank() || port <= 0) null
                    else MacEndpoint(host, port, token, name, "lan")
                }
            } catch (e: Exception) {
                null
            }
        }
    }
}
