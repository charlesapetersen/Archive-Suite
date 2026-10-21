package com.archiveprocessor.capture.ui

/** W40.e8 — one fixed phone screen for every screen test, so the screenshot goldens don't depend on
 *  Robolectric's default display. A mid-size phone in portrait, the way the app is held at a box. */
object ScreenQualifiers {
    const val PHONE = "w411dp-h891dp-port-xxhdpi"
}
