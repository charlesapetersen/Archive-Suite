package com.archiveprocessor.capture.capture

import android.app.Application
import android.os.Looper
import com.archiveprocessor.capture.data.SessionStore
import com.archiveprocessor.capture.net.DriveClient
import com.archiveprocessor.capture.net.HttpExecuting
import com.archiveprocessor.capture.net.MacEndpoint
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.net.URLDecoder
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
// S-021 baseline. Start at the shutter path and inject only the Drive HTTP response.
class IndependentRelayEndTest {
    @Test fun healthyRelayDeliversEnd() = runCapture(false)
    @Test fun driveFailureDropsCompletionEvenAfterPairingAgain() = runCapture(true)

    private fun runCapture(refuseFirstEnd: Boolean) {
        val app = RuntimeEnvironment.getApplication() as Application
        val relay = Relay(refuseFirstEnd)
        CaptureViewModel.driveClientForTest = DriveClient(relay) { "fixture" }
        try {
            val vm = CaptureViewModel(app)
            val endpoint = MacEndpoint("", 0, "CHECK1", "Scratch Mac", "cloud")
            fun pair() {
                var paired = false
                vm.connectCloud(endpoint) { paired = it }
                spin { paired }
            }
            pair()
            // The Drive client treats photo bytes as opaque; its mock peer returns a real receipt shape.
            val photo = vm.newCaptureFile().apply { writeBytes(byteArrayOf(1, 2, 3)) }
            vm.addDocumentPhoto(photo)
            spin { vm.items.singleOrNull()?.state == UploadState.UPLOADED }
            val group = vm.items.single().groupId
            vm.finishDocumentSegment()
            assertEquals(group, vm.pendingTagGroupId)
            vm.applyTagsAndContinue("Q2", 1968, 3)
            spin {
                val persisted = SessionStore(app).load()
                relay.endAttempts.get() > 0 && persisted != null &&
                    persisted.items.isEmpty() && persisted.endedSegments.isEmpty()
            }
            vm.disconnect()
            pair()
            val deadline = System.nanoTime() + 1_000_000_000L
            while (System.nanoTime() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(10)
            }
            assertEquals(1, relay.endAttempts.get())
            assertEquals(!refuseFirstEnd, relay.endPublished)
            println("refuseFirstEnd=$refuseFirstEnd photo=UPLOADED creates=${relay.endAttempts} endPublished=${relay.endPublished} persistedEnded=0 afterRePair=true")
        } finally {
            CaptureViewModel.driveClientForTest = null
        }
    }

    private fun spin(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 15_000_000_000L
        do {
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return
            Thread.sleep(10)
        } while (System.nanoTime() < deadline)
        error("Timed out waiting for app state")
    }

    private class Relay(private val refuseFirstEnd: Boolean) : HttpExecuting {
        val endAttempts = AtomicInteger()
        @Volatile var endPublished = false
        private var receiptName: String? = null
        private var receipt: JSONObject? = null

        @Synchronized
        override fun execute(method: String, url: String, headers: Map<String, String>, body: ByteArray?):
            Triple<Int, ByteArray, Map<String, String>> {
            fun response(text: String, status: Int = 200) = Triple(status, text.toByteArray(), emptyMap<String, String>())
            fun list(id: String?) = response(if (id == null) """{"files":[]}""" else """{"files":[{"id":"$id"}]}""")
            val decoded = URLDecoder.decode(url, "UTF-8")
            return when {
                method == "GET" && decoded.contains("mimeType = 'application/vnd.google-apps.folder'") -> list("folder")
                method == "GET" && decoded.contains("value='_epoch.json'") -> list("epoch")
                method == "GET" && decoded.contains("/epoch?alt=media") -> response("""{"epoch":"EP","token":"CHECK1"}""")
                method == "GET" && decoded.contains("/receipt?alt=media") -> response(checkNotNull(receipt).toString())
                method == "GET" && receiptName?.let { decoded.contains("value='$it'") } == true -> list("receipt")
                method == "GET" && decoded.contains("relayName") -> list(null)
                method == "POST" && decoded.contains("uploadType=multipart") -> {
                    val parts = checkNotNull(body).toString(Charsets.UTF_8).split("\r\n\r\n")
                    val name = JSONObject(parts[1].substringBefore("\r\n")).getString("name")
                    when {
                        name.endsWith(".segment.json") -> {
                            val meta = JSONObject(parts[2].substringBefore("\r\n"))
                            check(meta.getString("seqs") == "1" && meta.getString("quality") == "Q2")
                            check(meta.getString("year") == "1968" && meta.getString("month") == "3")
                            if (endAttempts.incrementAndGet() == 1 && refuseFirstEnd) return response("fixture 500", 500)
                            endPublished = true
                        }
                        name.endsWith(".json") -> {
                            val meta = JSONObject(parts[2].substringBefore("\r\n"))
                            receiptName = name.removeSuffix(".json") + ".receipt.json"
                            receipt = meta.put("kind", "receipt")
                        }
                        else -> check(name.endsWith(".jpg"))
                    }
                    response("""{"id":"fixture"}""")
                }
                else -> error("Unexpected fixture request $method $decoded")
            }
        }
    }
}
