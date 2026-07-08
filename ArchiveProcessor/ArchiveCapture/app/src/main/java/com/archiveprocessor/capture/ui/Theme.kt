package com.archiveprocessor.capture.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

// A plain Material3 baseline for each mode — the app doesn't need a bespoke brand palette, it just needs to
// STOP rendering a light scheme in system dark mode (the connect/pairing flow was hard-locked light because
// MainActivity used a bare `MaterialTheme {}`, whose default color scheme is light regardless of the system).
private val DarkColors = darkColorScheme()
private val LightColors = lightColorScheme()

/** App theme: follows the system light/dark setting so the whole UI (esp. the connect/pairing flow, which
 *  relies on the Material color scheme for its surfaces/text) renders dark in dark mode and light in light
 *  mode. Status-bar icon contrast is driven separately in [MainActivity] (it depends on which screen is up:
 *  the always-black capture screen wants light icons regardless of mode). */
@Composable
fun ArchiveCaptureTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content
    )
}
