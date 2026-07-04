package com.archiveprocessor.capture

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
                    // Derive from the observable endpoint so disconnect()/re-pair are reflected — a
                    // one-way remembered flag would diverge from the source of truth.
                    if (vm.endpoint != null) CaptureScreen(vm)
                    else ConnectScreen(vm) { }
                }
            }
        }
    }
}
