package com.archiveprocessor.capture.ui

import androidx.compose.material3.Surface
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * W40.e8 — the on-phone tag sheet shown at End segment, rendered by Robolectric with no emulator. What it
 * sends decides the quality and date the Mac files the document under, so each button's values are checked,
 * not only that the sheet draws.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = ScreenQualifiers.PHONE)
class SegmentTagSheetScreenTest {

    @get:Rule val compose = createComposeRule()

    private data class Applied(val quality: String?, val year: Int?, val month: Int?)

    private var applied: Applied? = null
    private var cancelled = false

    private fun show(recentYears: List<Int> = listOf(1974, 1973), dark: Boolean = false) {
        compose.setContent {
            // In the app the sheet sits in a ModalBottomSheet, which supplies the themed surface behind it.
            ArchiveCaptureTheme(darkTheme = dark) {
                Surface {
                    SegmentTagSheet(
                        recentYears = recentYears,
                        onApply = { q, y, m -> applied = Applied(q, y, m) },
                        onCancel = { cancelled = true }
                    )
                }
            }
        }
    }

    @Test
    fun `apply sends the chosen quality, recent year and month`() {
        show()
        compose.onNodeWithText("Q2").performClick()
        compose.onNodeWithText("Q2").assertIsSelected()
        compose.onNodeWithText("1973").performClick()
        compose.onNodeWithText("Mar").performScrollTo().performClick()
        compose.onNodeWithText("Apply & continue").performScrollTo().performClick()
        assertEquals(Applied("Q2", 1973, 3), applied)
        assertTrue(!cancelled)
    }

    @Test
    fun `a typed year replaces the chip and Unrated sends no quality`() {
        show()
        compose.onNodeWithText("1974").performClick()
        compose.onNodeWithText("0 · Unrated").performClick()
        compose.onNodeWithText("Specific year").performTextInput("19x61")   // non-digits are dropped
        compose.onNodeWithText("1974").assertIsNotSelected()
        compose.onNodeWithText("Apply & continue").performScrollTo().performClick()
        assertEquals(Applied(null, 1961, null), applied)
    }

    @Test
    fun `tapping a selected chip again clears it`() {
        show()
        compose.onNodeWithText("Q3").performClick()
        compose.onNodeWithText("Q3").performClick()
        compose.onNodeWithText("Q3").assertIsNotSelected()
        compose.onNodeWithText("Apply & continue").performScrollTo().performClick()
        assertEquals(Applied(null, null, null), applied)
    }

    @Test
    fun `skip sends nothing even after choices, and cancel does not end the segment`() {
        show()
        compose.onNodeWithText("Q1").performClick()
        compose.onNodeWithText("Skip (tag on Mac)").performScrollTo().performClick()
        assertEquals(Applied(null, null, null), applied)

        applied = null
        compose.onNodeWithText("Cancel — keep shooting").performScrollTo().performClick()
        assertTrue(cancelled)
        assertNull(applied)
    }

    @Test
    fun `with no recent years the sheet still offers a typed year`() {
        show(recentYears = emptyList())
        compose.onNodeWithText("Specific year").assertIsDisplayed()
        compose.onNodeWithText("Month").assertIsDisplayed()
    }

    @Test
    fun `screenshot light`() {
        show()
        compose.onNodeWithText("Q2").performClick()
        compose.onRoot().captureRoboImage()
    }

    @Test
    fun `screenshot dark`() {
        show(dark = true)
        compose.onRoot().captureRoboImage()
    }
}
