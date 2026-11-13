package com.archiveprocessor.capture.ui

import androidx.camera.core.ImageCapture
import androidx.camera.view.LifecycleCameraController
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * W46.capture-companions — the controller the capture screen builds carries the capture rule, not CameraX's
 * defaults: MAXIMIZE_QUALITY (so JPEG quality 100), flash off, and no target size, so the size stays the
 * library default, the highest available at 4:3. The first check pins the reason the settings exist: a fresh
 * controller is not already in that mode.
 */
@RunWith(RobolectricTestRunner::class)
class CaptureCameraDefaultsTest {

    private fun controller() = LifecycleCameraController(RuntimeEnvironment.getApplication())

    @Test
    fun `cameraX's own default is the latency mode, which saves at JPEG quality 95`() {
        assertNotEquals(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY, controller().imageCaptureMode)
    }

    @Test
    fun `the capture screen's controller takes quality mode, flash off and no size cap`() {
        val c = controller().also(CaptureCameraDefaults::apply)
        assertEquals(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY, c.imageCaptureMode)
        assertEquals(ImageCapture.FLASH_MODE_OFF, c.imageCaptureFlashMode)
        assertNull(c.imageCaptureTargetSize)
    }
}
