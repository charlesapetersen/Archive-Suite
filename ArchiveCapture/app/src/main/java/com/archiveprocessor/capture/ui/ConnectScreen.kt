package com.archiveprocessor.capture.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.archiveprocessor.capture.capture.CaptureViewModel
import com.archiveprocessor.capture.net.QrAnalyzer

/** Pairing flow: first ask Wired vs Wi-Fi, then scan the Mac's QR (or enter manually). */
@Composable
fun ConnectScreen(vm: CaptureViewModel, onConnected: () -> Unit) {
    var wired by remember { mutableStateOf<Boolean?>(null) }
    when (wired) {
        null -> ModeChooser { wired = it }
        else -> Pairing(vm = vm, wired = wired == true, onBack = { wired = null }, onConnected = onConnected)
    }
}

@Composable
private fun ModeChooser(onChoose: (Boolean) -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("Connect to the Mac", style = MaterialTheme.typography.headlineSmall)
        Text("How is this phone connected to the Mac?", style = MaterialTheme.typography.bodyMedium)
        Button(onClick = { onChoose(true) }, modifier = Modifier.fillMaxWidth()) { Text("Wired (USB cable)") }
        OutlinedButton(onClick = { onChoose(false) }, modifier = Modifier.fillMaxWidth()) { Text("Wi-Fi (same network)") }
        Text(
            "Wired is the most reliable and needs no shared Wi-Fi. Both scan the same QR shown in Live Capture on the Mac.",
            style = MaterialTheme.typography.bodySmall
        )
    }
}

@Composable
private fun Pairing(vm: CaptureViewModel, wired: Boolean, onBack: () -> Unit, onConnected: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasCam by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        )
    }
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { hasCam = it }
    LaunchedEffect(Unit) { if (!hasCam) permLauncher.launch(Manifest.permission.CAMERA) }

    var showManual by remember { mutableStateOf(false) }
    var connecting by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(if (wired) "Wired — scan the QR" else "Wi-Fi — scan the QR", style = MaterialTheme.typography.headlineSmall)
        Text("Point the camera at the QR code in Live Capture on the Mac.", style = MaterialTheme.typography.bodyMedium)
        if (!wired) {
            Text(
                "On public / guest / hotel Wi-Fi that hides devices from each other, the scan may do nothing. " +
                    "Use a personal hotspot (join both devices to it), or the USB cable instead.",
                style = MaterialTheme.typography.bodySmall
            )
        }

        if (hasCam) {
            val controller = remember { LifecycleCameraController(context) }
            val analyzerRef = remember { arrayOfNulls<QrAnalyzer>(1) }
            val analyzer = remember {
                QrAnalyzer { payload ->
                    if (!connecting) {
                        connecting = true
                        vm.connectFromQr(payload, wired) { ok ->
                            connecting = false
                            // Re-arm on failure so simply pointing at the QR again retries — the analyzer
                            // latches after one decode, so without this a failed scan is a dead end.
                            if (ok) onConnected() else analyzerRef[0]?.rearm()
                        }
                    }
                }.also { analyzerRef[0] = it }
            }
            DisposableEffect(Unit) { onDispose { analyzer.close() } }   // release the ML Kit detector
            LaunchedEffect(Unit) {
                controller.setEnabledUseCases(CameraController.IMAGE_ANALYSIS)
                controller.setImageAnalysisAnalyzer(ContextCompat.getMainExecutor(context), analyzer)
                controller.bindToLifecycle(lifecycleOwner)
            }
            AndroidView(
                factory = { PreviewView(it).apply { this.controller = controller } },
                modifier = Modifier.fillMaxWidth().weight(1f)
            )
        } else {
            Text("Camera permission is needed to scan the QR code.", color = MaterialTheme.colorScheme.error)
        }

        if (vm.statusMessage.isNotEmpty()) Text(vm.statusMessage, style = MaterialTheme.typography.bodySmall)

        TextButton(onClick = { showManual = !showManual }) {
            Text(if (showManual) "Hide manual entry" else "Enter manually instead")
        }
        if (showManual) ManualConnect(vm, wired, onConnected)

        TextButton(onClick = onBack) { Text("← Choose connection type") }
    }
}

@Composable
private fun ManualConnect(vm: CaptureViewModel, wired: Boolean, onConnected: () -> Unit) {
    var host by remember { mutableStateOf(if (wired) "127.0.0.1" else "") }
    var port by remember { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(host, { host = it }, label = { Text("Host") }, singleLine = true)
        OutlinedTextField(
            port, { port = it.filter { c -> c.isDigit() } }, label = { Text("Port") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
        )
        OutlinedTextField(token, { token = it }, label = { Text("Token") }, singleLine = true)
        Button(onClick = {
            val p = port.toIntOrNull() ?: return@Button
            vm.connect(host.trim(), p, token.trim()) { ok -> if (ok) onConnected() }
        }) { Text("Connect") }
    }
}
