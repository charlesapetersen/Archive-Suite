package com.archiveprocessor.capture.ui

import androidx.compose.material3.Surface
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.archiveprocessor.capture.capture.CaptureViewModel
import com.archiveprocessor.capture.net.DriveAuth
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * W40.e8 — the pairing flow, rendered by Robolectric with no emulator and no camera. Robolectric denies the
 * camera permission, so the scanner is never bound; what is checked is the flow around it: the three modes,
 * the manual-entry fallback each offers, and the way back. The view model is the real one, on Robolectric's
 * scratch app storage.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = ScreenQualifiers.PHONE)
class ConnectScreenTest {

    @get:Rule val compose = createComposeRule()

    private val vm = CaptureViewModel(RuntimeEnvironment.getApplication())
    private var connected = false

    private fun fieldValue(text: String) =
        SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString(text))

    private fun show(dark: Boolean = false) {
        compose.setContent {
            ArchiveCaptureTheme(darkTheme = dark) {
                Surface { ConnectScreen(vm) { connected = true } }
            }
        }
    }

    @Test
    fun `the chooser offers all three connection types`() {
        show()
        compose.onNodeWithText("Connect to the Mac").assertIsDisplayed()
        compose.onNodeWithText("Wired (USB cable)").assertIsDisplayed()
        compose.onNodeWithText("Wi-Fi (same network)").assertIsDisplayed()
        compose.onNodeWithText("Cloud (Google Drive)").assertIsDisplayed()
    }

    @Test
    fun `wired without the camera says so, and manual entry starts on the USB host`() {
        show()
        compose.onNodeWithText("Wired (USB cable)").performClick()
        compose.onNodeWithText("Wired — scan the QR").assertIsDisplayed()
        compose.onNodeWithText("Camera permission is needed to scan the QR code.").assertIsDisplayed()
        compose.onNodeWithText("public / guest / hotel Wi-Fi", substring = true).assertDoesNotExist()

        compose.onNodeWithText("Enter manually instead").performClick()
        compose.onNodeWithText("Host").assert(fieldValue("127.0.0.1"))
        // The scanner region and the form are exclusive: the form replaces the permission notice.
        compose.onNodeWithText("Camera permission is needed to scan the QR code.").assertDoesNotExist()
        compose.onNodeWithText("Hide manual entry — scan instead").assertIsDisplayed()
    }

    @Test
    fun `wi-fi warns about guest networks and starts with an empty host`() {
        show()
        compose.onNodeWithText("Wi-Fi (same network)").performClick()
        compose.onNodeWithText("Wi-Fi — scan the QR").assertIsDisplayed()
        compose.onNodeWithText("public / guest / hotel Wi-Fi", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Enter manually instead").performClick()
        compose.onNodeWithText("Host").assert(fieldValue(""))
    }

    @Test
    fun `connect without a port does nothing`() {
        show()
        compose.onNodeWithText("Wired (USB cable)").performClick()
        compose.onNodeWithText("Enter manually instead").performClick()
        compose.onNodeWithText("Port").performTextInput("ab")   // digits only: nothing lands
        compose.onNodeWithText("Token").performTextInput("t0ken")
        compose.onNodeWithText("Connect").performClick()
        compose.waitForIdle()
        assertNull(vm.endpoint)
        assertFalse(connected)
    }

    @Test
    fun `back returns to the chooser from every mode`() {
        show()
        for (mode in listOf("Wired (USB cable)", "Wi-Fi (same network)", "Cloud (Google Drive)")) {
            compose.onNodeWithText(mode).performClick()
            compose.onNodeWithText("← Choose connection type").performClick()
            compose.onNodeWithText("Connect to the Mac").assertIsDisplayed()
        }
    }

    @Test
    fun `cloud on a build with no OAuth client says so and stays put`() {
        assumeFalse("this machine's local.properties configures a Drive OAuth client", vm.driveAuth.isConfigured)
        show()
        compose.onNodeWithText("Cloud (Google Drive)").performClick()
        compose.onNodeWithText("Cloud — scan the QR").assertIsDisplayed()
        compose.onNodeWithText("Enter the relay token manually").performClick()
        compose.onNodeWithText("Relay token").performTextInput("relay-123")
        compose.onNodeWithText("Sign in & connect").performClick()
        compose.onNodeWithText(DriveAuth.UNCONFIGURED_MESSAGE).assertIsDisplayed()
        assertNull(vm.endpoint)
        assertFalse(connected)
    }

    @Test
    fun `screenshot chooser light`() {
        show()
        compose.onRoot().captureRoboImage()
    }

    @Test
    fun `screenshot chooser dark`() {
        show(dark = true)
        compose.onRoot().captureRoboImage()
    }

    @Test
    fun `screenshot wired manual entry`() {
        show()
        compose.onNodeWithText("Wired (USB cable)").performClick()
        compose.onNodeWithText("Enter manually instead").performClick()
        compose.onRoot().captureRoboImage()
    }
}
