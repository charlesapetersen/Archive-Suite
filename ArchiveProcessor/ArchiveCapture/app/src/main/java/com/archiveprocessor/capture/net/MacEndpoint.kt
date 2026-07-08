package com.archiveprocessor.capture.net

import org.json.JSONObject

/**
 * Connection info for the Mac receiver.
 *
 * - **LAN/USB** (`mode = "lan"`): decoded from the pairing QR `{host, port, token, name}`; the phone talks
 *   HTTP to `baseUrl`. `token` is the Bearer pairing code.
 * - **Cloud** (`mode = "cloud"`): the phone chose Cloud. `host`/`port` are unused; the relay token comes
 *   from [relayToken]. The Mac now emits ONE combined LAN QR that ALSO carries the relay token in an
 *   OPTIONAL `relay` key (see below), so cloud is reached from that same scan — a legacy `{mode:"cloud",…}`
 *   QR is still accepted for back-compat. The relay token is the same value the Mac writes as the Drive
 *   folder's `appProperties.relayToken` and into `_epoch.json`, which `DriveRelayTransport` uses to
 *   self-discover the shared folder. `account` is an optional Google-account email hint for sign-in.
 *
 * `relay` is the OPTIONAL combined-QR field: present on a current Mac's QR when it's signed into Drive,
 * absent on an older / LAN-only QR (→ null, LAN pairing unaffected).
 */
data class MacEndpoint(
    val host: String,
    val port: Int,
    val token: String,
    val name: String,
    val mode: String = "lan",
    val account: String? = null,
    val relay: String? = null
) {
    val baseUrl: String get() = "http://$host:$port"
    val isCloud: Boolean get() = mode == "cloud"

    /** The Drive-relay token to use for the Cloud transport: the explicit combined-QR `relay` field, else
     *  the token itself when this endpoint was already built as a cloud endpoint. Null for a plain LAN QR
     *  with no `relay` field (→ Cloud isn't available from that scan; sign the Mac into Drive first). */
    val relayToken: String? get() = relay ?: token.takeIf { isCloud }

    companion object {
        fun fromQrPayload(payload: String): MacEndpoint? {
            return try {
                val o = JSONObject(payload)
                val token = o.optString("token", "")
                if (token.isBlank()) return null
                val name = o.optString("name", "Mac")
                val relay = o.optString("relay", "").ifBlank { null }   // OPTIONAL; tolerate absence
                if (o.optString("mode", "lan") == "cloud") {
                    MacEndpoint("", 0, token, name, "cloud", o.optString("account", "").ifBlank { null }, relay)
                } else {
                    val host = o.optString("host", "")
                    val port = o.optInt("port", 0)
                    if (host.isBlank() || port <= 0) null
                    else MacEndpoint(host, port, token, name, "lan", null, relay)
                }
            } catch (e: Exception) {
                null
            }
        }
    }
}
