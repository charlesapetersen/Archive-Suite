package com.archiveprocessor.capture

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.archiveprocessor.capture.capture.CaptureViewModel
import com.archiveprocessor.capture.ui.CaptureScreen
import com.archiveprocessor.capture.ui.ConnectScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val vm: CaptureViewModel = viewModel()
                    var connected by remember { mutableStateOf(vm.endpoint != null) }
                    if (connected) CaptureScreen(vm)
                    else ConnectScreen(vm) { connected = true }
                }
            }
        }
    }
}
