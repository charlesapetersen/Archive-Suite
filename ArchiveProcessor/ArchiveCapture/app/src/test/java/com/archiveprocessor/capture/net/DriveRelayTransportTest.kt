package com.archiveprocessor.capture.net

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URLDecoder

/**
 * Offline verification of the Android DriveRelayTransport never-lose contract against a mock Drive (no
 * network/OAuth) — parity with the iOS scripts/test-drive-transport.sh. postPhoto returns true ONLY after a
 * matching-(token,epoch,group,seq,fp) receipt, never on a write alone; stale-fp (A1) and wrong-epoch (A2)
 * acks are rejected. Plain-JVM (org.json via testImplementation).
 */
class DriveRelayTransportTest {

    /** In-memory mock Google Drive covering exactly the DriveClient calls the transport makes. */
    private class MockDrive : HttpExecuting {
        class F(val id: String, val name: String, val appProps: MutableMap<String, String>, val parents: List<String>, var media: ByteArray, val mime: String)
        val store = LinkedHashMap<String, F>()
        private var seq = 0
        private fun newId(): String { seq++; return "f$seq" }
        fun injectFolder(relayToken: String) { val id = newId(); store[id] = F(id, "folder", mutableMapOf("relayToken" to relayToken, "relayFolder" to "1"), emptyList(), ByteArray(0), "application/vnd.google-apps.folder") }
        fun injectFile(name: String, token: String, media: ByteArray) {
            val folder = store.values.firstOrNull { it.mime == "application/vnd.google-apps.folder" && it.appProps["relayToken"] == token }
            val id = newId(); store[id] = F(id, name, mutableMapOf("relayName" to name, "relayToken" to token), if (folder != null) listOf(folder.id) else emptyList(), media, "")
        }
        fun hasName(name: String) = store.values.any { it.appProps["relayName"] == name && it.appProps["relayRejected"] != "1" }

        override fun execute(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Triple<Int, ByteArray, Map<String, String>> {
            fun idFromPath(): String? { val i = url.indexOf("/files/"); if (i < 0) return null; return url.substring(i + 7).takeWhile { it != '?' } }
            if (method == "POST" && url.contains("/upload/drive/v3/files")) {
                val ct = headers.entries.firstOrNull { it.key.equals("Content-Type", true) }?.value ?: ""
                val boundary = ct.substringAfter("boundary=", "")
                val s = String(body ?: ByteArray(0), Charsets.UTF_8)
                val parts = s.split("--$boundary")
                fun content(p: String): String { val i = p.indexOf("\r\n\r\n"); if (i < 0) return ""; var c = p.substring(i + 4); if (c.endsWith("\r\n")) c = c.dropLast(2); return c }
                val meta = JSONObject(content(parts[1]))
                val ap = HashMap<String, String>(); meta.optJSONObject("appProperties")?.let { for (k in it.keys()) ap[k] = it.getString(k) }
                val parents = ArrayList<String>(); meta.optJSONArray("parents")?.let { for (i in 0 until it.length()) parents.add(it.getString(i)) }
                val id = newId(); store[id] = F(id, meta.optString("name"), ap, parents, content(parts[2]).toByteArray(Charsets.UTF_8), "")
                return Triple(200, """{"id":"$id"}""".toByteArray(), emptyMap())
            }
            if (method == "PATCH" && url.contains("/upload/drive/v3/files/")) { idFromPath()?.let { store[it]?.media = body ?: ByteArray(0) }; return Triple(200, "{}".toByteArray(), emptyMap()) }
            if (method == "GET" && url.contains("alt=media")) { return Triple(200, store[idFromPath()]?.media ?: ByteArray(0), emptyMap()) }
            if (method == "GET" && url.contains("/drive/v3/files?q=")) {
                val q = URLDecoder.decode(url.substringAfter("?q=").substringBefore("&"), "UTF-8")
                fun between(a: String, b: String): String? { val i = q.indexOf(a); if (i < 0) return null; val j = q.indexOf(b, i + a.length); if (j < 0) return null; return q.substring(i + a.length, j) }
                val matched = when {
                    q.contains("in parents") -> {
                        val fid = between("'", "' in parents") ?: ""
                        var m = store.values.filter { it.parents.contains(fid) }
                        if (q.contains("relayName")) between("key='relayName' and value='", "'")?.let { n -> m = m.filter { it.appProps["relayName"] == n } }
                        m
                    }
                    q.contains("relayToken") -> { val tok = between("value='", "'"); store.values.filter { it.mime == "application/vnd.google-apps.folder" && it.appProps["relayToken"] == tok } }
                    else -> emptyList()
                }
                val arr = JSONArray()
                for (f in matched) { val o = JSONObject().put("id", f.id).put("name", f.name); val ap = JSONObject(); for ((k, v) in f.appProps) ap.put(k, v); o.put("appProperties", ap); arr.put(o) }
                return Triple(200, JSONObject().put("files", arr).toString().toByteArray(), emptyMap())
            }
            if (method == "DELETE") { idFromPath()?.let { store.remove(it) }; return Triple(204, ByteArray(0), emptyMap()) }
            return Triple(404, "{}".toByteArray(), emptyMap())
        }
    }

    private fun receipt(g: String, s: Int, e: String, fp: String): ByteArray =
        RelayObjectFormat.canonicalJson(mapOf("kind" to "receipt", "token" to "TESTTK", "epoch" to e, "group" to g, "seq" to s.toString(), "received" to "true", "fp" to fp))

    @Test fun neverLoseContract() {
        val mock = MockDrive()
        mock.injectFolder("TESTTK")
        mock.injectFile("_epoch.json", "TESTTK", RelayObjectFormat.canonicalJson(mapOf("kind" to "epoch", "token" to "TESTTK", "epoch" to "EP1")))
        val client = DriveClient(mock) { "fake" }
        val t = DriveRelayTransport(client, "TESTTK", 1500, 200)

        assertFalse("no receipt -> false (never-lose)", t.postPhoto("b1".toByteArray(), "g", 1, "document", "Q1", 1968, 3, "X", null))
        assertTrue("sidecar+jpeg upserted to Drive", mock.hasName("g__1.json") && mock.hasName("g__1.jpg"))

        val fp2 = RelayObjectFormat.fingerprint("document", "Q1", "1968", "3", null)
        mock.injectFile("g__2.receipt.json", "TESTTK", receipt("g", 2, "EP1", fp2))
        assertTrue("matching receipt -> true", t.postPhoto("b2".toByteArray(), "g", 2, "document", "Q1", 1968, 3, "X", null))

        mock.injectFile("g__3.receipt.json", "TESTTK", receipt("g", 3, "EP1", "deadbeefdeadbeef"))
        assertFalse("wrong-fp receipt -> false (A1)", t.postPhoto("b3".toByteArray(), "g", 3, "document", "Q1", 1968, 3, "X", null))

        val fp4 = RelayObjectFormat.fingerprint("document", null, null, null, null)
        mock.injectFile("g__4.receipt.json", "TESTTK", receipt("g", 4, "OLD", fp4))
        assertFalse("wrong-epoch receipt -> false (A2)", t.postPhoto("b4".toByteArray(), "g", 4, "document", null, null, null, "X", null))

        assertTrue("segmentComplete -> true", t.segmentComplete("g", "Q1", 1968, 3))
        assertTrue("segment object written", mock.hasName("g.segment.json"))
    }
}
