package com.archiveprocessor.capture.ui

import androidx.camera.core.ImageCapture
import androidx.camera.view.CameraController

/**
 * The capture rule for every page photograph (`execution-plans/processing-review/13-stage-rules/11-capture.md`
 * §3): flash off, the full-resolution original at the camera's best quality, nothing done to it on the phone.
 * Each setting is explicit rather than inherited, because the defaults are not the rule. Read from the CameraX
 * 1.3.4 bytecode (W46.capture-companions): the capture mode defaults to MINIMIZE_LATENCY, and the JPEG quality
 * follows the mode when none is set: 100 under MAXIMIZE_QUALITY, 95 otherwise. CameraController has no JPEG
 * quality setter, so MAXIMIZE_QUALITY is what gives quality 100. Size: the controller's ImageCapture takes the
 * library's default resolution selector, the highest available at 4:3, and 1.3.4's controller has no selector
 * setter; its one size option, a target size, can only shrink the page, so it is left unset (and tested so).
 */
object CaptureCameraDefaults {
    const val CAPTURE_MODE = ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY
    const val FLASH_MODE = ImageCapture.FLASH_MODE_OFF

    /** Static guidance shown over the preview. No live warning until W46.capture-warning validates a cut. */
    const val GUIDANCE = "Hold still · avoid reflections · the whole page, and only that page, in frame"

    fun apply(controller: CameraController) {
        controller.imageCaptureMode = CAPTURE_MODE
        controller.imageCaptureFlashMode = FLASH_MODE
    }
}
