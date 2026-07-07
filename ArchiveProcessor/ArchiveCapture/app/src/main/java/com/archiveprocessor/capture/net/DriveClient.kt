package com.archiveprocessor.capture.net

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Blocking HTTP execution seam so [DriveClient] (and the whole Drive path) is unit-testable against a
 * mock responder with NO network — the live [OkHttpExecuting] impl is exercised only in an owner-gated
 * integration test. Returns (status, body, lowercased response headers); throws only on transport failure.
 *
 * Mirrors the Mac/iOS Swift `HTTPExecuting`.
 */
interface HttpExecuting {
    fun execute(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Triple<Int, ByteArray, Map<String, String>>
}

/** okhttp-backed blocking executor (same okhttp usage pattern as [MacClient]). Content-Type is carried on
 *  the request body's media type (not a duplicate header) so okhttp emits a single, well-formed header. */
class OkHttpExecuting(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        .build()
) : HttpExecuting {
    override fun execute(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Triple<Int, ByteArray, Map<String, String>> {
        val builder = Request.Builder().url(url)
        val contentType = headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }?.value
        for ((k, v) in headers) {
            if (k.equals("Content-Type", ignoreCase = true)) continue   // carried on the body's media type
            builder.header(k, v)
        }
        val media = contentType?.toMediaType()
        val needsBody = method.uppercase() in setOf("POST", "PUT", "PATCH")
        val reqBody = when {
            body != null -> body.toRequestBody(media)
            needsBody -> ByteArray(0).toRequestBody(media)
            else -> null
        }
        builder.method(method, reqBody)
        client.newCall(builder.build()).execute().use { resp ->
            val respBody = resp.body?.bytes() ?: ByteArray(0)
            val respHeaders = HashMap<String, String>()
            val h = resp.headers
            for (i in 0 until h.size) respHeaders[h.name(i).lowercase()] = h.value(i)
            return Triple(resp.code, respBody, respHeaders)
        }
    }
}

/** Errors from the Drive REST layer (mirror of the Swift `DriveError` cases). */
sealed class DriveException(message: String) : Exception(message) {
    class BadUrl(url: String) : DriveException("bad URL $url")
    object NoResponse : DriveException("no HTTP response")
    class Http(val status: Int, val body: String) : DriveException("HTTP $status: ${body.take(200)}")
    class Decode(msg: String) : DriveException("decode: $msg")
    object NotSignedIn : DriveException("not signed in to Google Drive")
}

/**
 * Thin Google Drive REST v3 client for the relay backend — exactly the calls the phone (and the Mac's
 * store) need. Auth is a token provider closure (a Google OAuth access token), so this stays testable.
 * All methods are blocking (sync) to fit the [SegmentTransport] surface; they run off the main thread.
 *
 * Mirrors `ArchiveProcessor/.../Net/DriveClient.swift`. JSON is parsed with `org.json` (available on-device;
 * NOT on the plain-JVM unit-test classpath — unit tests inject an [HttpExecuting] and assert on requests).
 */
class DriveClient(
    private val http: HttpExecuting = OkHttpExecuting(),
    private val token: () -> String
) {
    /** One Drive file as the relay path needs it. Mirrors the Swift `DriveFile`. */
    data class DriveFile(
        val id: String,
        val name: String?,
        val appProperties: Map<String, String>?,
        val modifiedTime: String?
    )

    /** (changed files, next page token to poll from) — mirrors the Swift `listChanges` tuple. */
    data class Changes(val files: List<DriveFile>, val next: String)

    private fun send(method: String, url: String, headers: Map<String, String> = emptyMap(), body: ByteArray? = null): ByteArray {
        val h = HashMap(headers)
        h["Authorization"] = "Bearer " + token()
        val (status, data, _) = http.execute(method, url, h, body)
        if (status !in 200..299) throw DriveException.Http(status, String(data, Charsets.UTF_8))
        return data
    }

    private fun json(data: ByteArray): JSONObject =
        try { JSONObject(String(data, Charsets.UTF_8)) }
        catch (e: Exception) { throw DriveException.Decode(e.toString()) }

    private fun parseFile(o: JSONObject): DriveFile {
        val name = if (o.has("name") && !o.isNull("name")) o.getString("name") else null
        val modifiedTime = if (o.has("modifiedTime") && !o.isNull("modifiedTime")) o.getString("modifiedTime") else null
        val appProperties = o.optJSONObject("appProperties")?.let { ap ->
            val m = HashMap<String, String>()
            for (key in ap.keys()) m[key] = ap.getString(key)
            m
        }
        return DriveFile(o.getString("id"), name, appProperties, modifiedTime)
    }

    private fun obj(map: Map<String, String>): JSONObject {
        val o = JSONObject()
        for ((k, v) in map) o.put(k, v)
        return o
    }

    private fun arr(list: List<String>): JSONArray {
        val a = JSONArray()
        for (s in list) a.put(s)
        return a
    }

    /** List files matching a Drive query `q`. Returns all pages. */
    fun listFiles(query: String): List<DriveFile> {
        val result = ArrayList<DriveFile>()
        var pageToken: String? = null
        do {
            var url = "$api/files?q=${enc(query)}&fields=${enc("files(id,name,appProperties,modifiedTime),nextPageToken")}&pageSize=1000&spaces=drive"
            if (pageToken != null) url += "&pageToken=${enc(pageToken)}"
            val j = json(send("GET", url))
            val files = j.optJSONArray("files")
            if (files != null) for (i in 0 until files.length()) result.add(parseFile(files.getJSONObject(i)))
            pageToken = if (j.has("nextPageToken") && !j.isNull("nextPageToken")) j.getString("nextPageToken") else null
        } while (pageToken != null)
        return result
    }

    /** Create a metadata-only file (used for folders: mimeType = application/vnd.google-apps.folder). Returns id. */
    fun createMetadata(name: String, parents: List<String>, appProperties: Map<String, String>, mimeType: String?): String {
        val meta = JSONObject()
        meta.put("name", name)
        meta.put("appProperties", obj(appProperties))
        if (parents.isNotEmpty()) meta.put("parents", arr(parents))   // empty → Drive root (My Drive)
        if (mimeType != null) meta.put("mimeType", mimeType)
        val data = send("POST", "$api/files?fields=id", mapOf("Content-Type" to "application/json"),
            meta.toString().toByteArray(Charsets.UTF_8))
        return json(data).getString("id")
    }

    /** Create a file with content via multipart/related (metadata + media). Returns id. */
    fun createFile(name: String, parents: List<String>, appProperties: Map<String, String>, media: ByteArray, mimeType: String): String {
        val boundary = "arcap-${UUID.randomUUID()}"
        val meta = JSONObject()
        meta.put("name", name)
        meta.put("appProperties", obj(appProperties))
        if (parents.isNotEmpty()) meta.put("parents", arr(parents))
        val out = ByteArrayOutputStream()
        fun add(s: String) = out.write(s.toByteArray(Charsets.UTF_8))
        add("--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        out.write(meta.toString().toByteArray(Charsets.UTF_8)); add("\r\n")
        add("--$boundary\r\nContent-Type: $mimeType\r\n\r\n")
        out.write(media); add("\r\n--$boundary--\r\n")
        val data = send("POST", "$upload/files?uploadType=multipart&fields=id",
            mapOf("Content-Type" to "multipart/related; boundary=$boundary"), out.toByteArray())
        return json(data).getString("id")
    }

    /** Replace an existing file's media (idempotent overwrite for a re-sent object). */
    fun updateMedia(fileId: String, media: ByteArray, mimeType: String) {
        send("PATCH", "$upload/files/$fileId?uploadType=media", mapOf("Content-Type" to mimeType), media)
    }

    /** Update just the appProperties of an existing file (e.g. mark a receipt/quarantine flag). */
    fun updateAppProperties(fileId: String, appProperties: Map<String, String>) {
        val body = JSONObject().put("appProperties", obj(appProperties))
        send("PATCH", "$api/files/$fileId?fields=id", mapOf("Content-Type" to "application/json"),
            body.toString().toByteArray(Charsets.UTF_8))
    }

    fun getMedia(fileId: String): ByteArray = send("GET", "$api/files/$fileId?alt=media")

    fun delete(fileId: String) {
        val (status, data, _) = http.execute("DELETE", "$api/files/$fileId",
            mapOf("Authorization" to "Bearer " + token()), null)
        if (status !in 200..299 && status != 404) {   // 404 = already gone (idempotent)
            throw DriveException.Http(status, String(data, Charsets.UTF_8))
        }
    }

    // Changes feed (the reliable way to detect new objects).
    fun startPageToken(): String = json(send("GET", "$api/changes/startPageToken")).getString("startPageToken")

    /** Returns (changed files, next page token). `newStartPageToken` (end of a page run) is returned as
     *  `next` when there are no more pages. */
    fun listChanges(pageToken: String): Changes {
        var token = pageToken
        val files = ArrayList<DriveFile>()
        while (true) {
            val url = "$api/changes?pageToken=${enc(token)}&fields=${enc("changes(fileId,removed,file(id,name,appProperties,modifiedTime)),nextPageToken,newStartPageToken")}&pageSize=1000&spaces=drive"
            val cl = json(send("GET", url))
            val changes = cl.optJSONArray("changes")
            if (changes != null) for (i in 0 until changes.length()) {
                val c = changes.getJSONObject(i)
                if (c.optBoolean("removed", false)) continue
                val f = c.optJSONObject("file")
                if (f != null) files.add(parseFile(f))
            }
            val np = if (cl.has("nextPageToken") && !cl.isNull("nextPageToken")) cl.getString("nextPageToken") else null
            if (np != null) { token = np; continue }
            val newStart = if (cl.has("newStartPageToken") && !cl.isNull("newStartPageToken")) cl.getString("newStartPageToken") else null
            return Changes(files, newStart ?: token)
        }
    }

    /** Query-value-safe percent-encoding (unreserved = alphanumerics + `-._~`); matches the Swift
     *  `.urlQueryValueAllowed` set exactly (per-byte UTF-8, uppercase hex). */
    private fun enc(s: String): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xFF
            val ch = c.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                sb.append(ch)
            } else {
                sb.append('%').append("%02X".format(c))
            }
        }
        return sb.toString()
    }

    companion object {
        private const val api = "https://www.googleapis.com/drive/v3"
        private const val upload = "https://www.googleapis.com/upload/drive/v3"
    }
}
