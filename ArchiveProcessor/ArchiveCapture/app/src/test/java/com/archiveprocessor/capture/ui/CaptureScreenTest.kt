package com.archiveprocessor.capture.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import com.archiveprocessor.capture.capture.CaptureViewModel
import com.archiveprocessor.capture.capture.CapturedItem
import com.archiveprocessor.capture.capture.GroupType
import com.archiveprocessor.capture.capture.UploadState
import com.archiveprocessor.capture.data.SessionStore
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * W40.e8 — the capture screen, rendered by Robolectric with no emulator, camera or Mac. The session is
 * seeded the way a restart finds it — a manifest written by the real [SessionStore] plus its image files —
 * and the real [CaptureViewModel] restores it. No endpoint is saved, so nothing is ever sent.
 *
 * The checks that matter most are the ones guarding photos that exist only on this phone: Clear and the
 * third-tap delete must both stop for a confirmation, and cancelling either must leave the file in place.
 *
 * Scratch only: everything lives in Robolectric's per-test app storage.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = ScreenQualifiers.PHONE)
class CaptureScreenTest {

    @get:Rule val compose = createComposeRule()

    private val app = RuntimeEnvironment.getApplication()
    private val captureDir = File(app.filesDir, "capture").apply { mkdirs() }

    private fun jpeg(name: String, color: Int): File {
        val bmp = Bitmap.createBitmap(120, 160, Bitmap.Config.ARGB_8888)
        Canvas(bmp).drawColor(color)
        return File(captureDir, name).apply { outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) } }
    }

    private lateinit var page1: File
    private lateinit var page2: File
    private lateinit var folder: File

    /** Two pages of the open document (one Q3, one already on the Mac) and a folder marker that failed. */
    private fun seedSession(pendingTag: String? = null) {
        page1 = jpeg("img_0001.jpg", Color.rgb(222, 205, 170))
        page2 = jpeg("img_0002.jpg", Color.rgb(200, 190, 160))
        folder = jpeg("img_0003.jpg", Color.rgb(120, 60, 160))
        val items = listOf(
            CapturedItem(1, page1, "gdoc", 1, GroupType.DOCUMENT, quality = "Q3"),
            CapturedItem(2, page2, "gdoc", 2, GroupType.DOCUMENT, state = UploadState.UPLOADED),
            CapturedItem(3, folder, "gfold", 3, GroupType.FOLDER, state = UploadState.FAILED),
        )
        assertTrue(SessionStore(app).save(items, seq = 3, nextId = 4, currentGroupId = "gdoc",
            pendingTagGroupId = pendingTag, endedSegments = emptyList()))
    }

    private fun show(): CaptureViewModel {
        val vm = CaptureViewModel(app)
        compose.setContent { ArchiveCaptureTheme(darkTheme = false) { CaptureScreen(vm) } }
        return vm
    }

    @Test
    fun `an empty session shows the capture controls and nothing destructive`() {
        show()
        compose.onNodeWithText("Not connected").assertIsDisplayed()
        compose.onNodeWithText("Camera permission needed to capture.").assertIsDisplayed()
        compose.onNodeWithContentDescription("End segment").assertIsDisplayed()
        compose.onNodeWithContentDescription("Shutter. Capture a document page").assertIsDisplayed()
        compose.onNodeWithContentDescription("Box. Capture a box-label marker").assertIsDisplayed()
        compose.onNodeWithContentDescription("Folder. Capture a folder-label marker").assertIsDisplayed()
        compose.onNodeWithText("Clear").assertDoesNotExist()
        compose.onNodeWithText("Retry").assertDoesNotExist()
        compose.onNodeWithText("Save to phone").assertDoesNotExist()
    }

    @Test
    fun `a restored session shows its strip, its state and the recovery actions`() {
        seedSession()
        val vm = show()
        assertEquals(3, vm.items.size)
        compose.onNodeWithText("Restored 3 photo(s) from last session").assertIsDisplayed()
        compose.onNodeWithText("Clear").assertIsDisplayed()
        compose.onNodeWithText("Retry").assertIsDisplayed()
        compose.onNodeWithText("Save to phone").assertIsDisplayed()
        compose.onNodeWithContentDescription("Document page, queued to send, quality Q3").assertIsDisplayed()
        compose.onNodeWithContentDescription("Document page, sent to Mac").assertIsDisplayed()
        compose.onNodeWithContentDescription("Folder marker, upload failed, will retry").assertIsDisplayed()
    }

    @Test
    fun `clear asks first, and cancel deletes nothing`() {
        seedSession()
        val vm = show()
        compose.onNodeWithText("Clear").performClick()
        compose.onNodeWithText("Clear all photos?").assertIsDisplayed()
        compose.onNodeWithText("permanently deletes all 3 captured photo(s)", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Clear all photos?").assertDoesNotExist()
        assertEquals(3, vm.items.size)
        assertTrue(page1.exists() && page2.exists() && folder.exists())
    }

    @Test
    fun `tap selects, a second tap arms, and a third on an unsent page asks before deleting`() {
        seedSession()
        val vm = show()
        val thumb = "Document page, queued to send, quality Q3"
        compose.onNodeWithContentDescription(thumb).performClick()
        // Selected: the marker buttons now reclassify rather than shoot.
        compose.onNodeWithContentDescription("Reclassify the selected photo as a box marker").assertIsDisplayed()
        compose.onNodeWithContentDescription(thumb).performClick()
        compose.onNodeWithContentDescription("$thumb, tap again to delete").assertIsDisplayed()
        compose.onNodeWithContentDescription("$thumb, tap again to delete").performClick()

        compose.onNodeWithText("Delete this page?").assertIsDisplayed()
        compose.onNodeWithText("Save to gallery & delete").assertIsDisplayed()
        compose.onNodeWithText("Delete permanently").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Delete this page?").assertDoesNotExist()
        assertNull(vm.pendingDeleteId)
        assertEquals(3, vm.items.size)
        assertTrue(page1.exists())
    }

    @Test
    fun `re-pair asks first and cancel stays on the capture screen`() {
        show()
        compose.onNodeWithContentDescription("Re-pair with a Mac").performClick()
        compose.onNodeWithText("Re-pair with a Mac?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Re-pair with a Mac?").assertDoesNotExist()
        compose.onNodeWithContentDescription("End segment").assertIsDisplayed()
    }

    @Test
    fun `a restart mid-tagging reopens the tag sheet, and cancel keeps the segment open`() {
        seedSession(pendingTag = "gdoc")
        val vm = show()
        compose.onNodeWithText("Tag this document").assertIsDisplayed()
        compose.onNodeWithText("Cancel — keep shooting").performClick()
        compose.onNodeWithText("Tag this document").assertDoesNotExist()
        assertNull(vm.pendingTagGroupId)
        assertEquals("gdoc", vm.currentGroupId)
    }

    @Test
    fun `screenshot empty`() {
        show()
        compose.onRoot().captureRoboImage()
    }

    @Test
    fun `screenshot restored session`() {
        seedSession()
        show()
        compose.onRoot().captureRoboImage()
    }
}
