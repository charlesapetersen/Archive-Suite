package com.archiveprocessor.capture

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.archiveprocessor.capture.capture.CaptureViewModel
import com.archiveprocessor.capture.ui.CaptureScreen
import com.archiveprocessor.capture.ui.ConnectScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw edge-to-edge (transparent system bars) so the capture preview can reach under the status
        // bar. CaptureScreen handles its own insets (preview to the top, controls above the nav bar);
        // ConnectScreen is kept inside the safe area below so its title/QR don't slide under the bars.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val vm: CaptureViewModel = viewModel()
                    // Derive from the observable endpoint so disconnect()/re-pair are reflected — a
                    // one-way remembered flag would diverge from the source of truth.
                    if (vm.endpoint != null) CaptureScreen(vm)
                    else Box(Modifier.safeDrawingPadding()) { ConnectScreen(vm) { } }
                }
            }
        }
    }
}
