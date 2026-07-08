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
import com.archiveprocessor.capture.net.MacEndpoint
import com.archiveprocessor.capture.net.QrAnalyzer

private enum class ConnMode { WIRED, WIFI, CLOUD }

/** Pairing flow: pick a connection type, then scan the Mac's QR (or enter manually). */
@Composable
fun ConnectScreen(vm: CaptureViewModel, onConnected: () -> Unit) {
    var mode by remember { mutableStateOf<ConnMode?>(null) }
    when (mode) {
        null -> ModeChooser { mode = it }
        ConnMode.CLOUD -> CloudPairing(vm = vm, onBack = { mode = null }, onConnected = onConnected)
        else -> Pairing(vm = vm, wired = mode == ConnMode.WIRED, onBack = { mode = null }, onConnected = onConnected)
    }
}

@Composable
private fun ModeChooser(onChoose: (ConnMode) -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("Connect to the Mac", style = MaterialTheme.typography.headlineSmall)
        Text("How is this phone connected to the Mac?", style = MaterialTheme.typography.bodyMedium)
        Button(onClick = { onChoose(ConnMode.WIRED) }, modifier = Modifier.fillMaxWidth()) { Text("Wired (USB cable)") }
        OutlinedButton(onClick = { onChoose(ConnMode.WIFI) }, modifier = Modifier.fillMaxWidth()) { Text("Wi-Fi (same network)") }
        OutlinedButton(onClick = { onChoose(ConnMode.CLOUD) }, modifier = Modifier.fillMaxWidth()) { Text("Cloud (Google Drive)") }
        Text(
            "Wired is the most reliable and needs no shared Wi-Fi. Cloud relays through Google Drive — use it " +
                "when the Mac must stay on venue Wi-Fi and USB isn't available. All three scan a QR from Live Capture on the Mac.",
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

/**
 * Cloud pairing: scan the Mac's cloud QR (or paste the relay token), then sign in to Google (the SAME
 * account the Mac uses) via a Custom Tab. On success the phone uploads through the Drive relay.
 */
@Composable
private fun CloudPairing(vm: CaptureViewModel, onBack: () -> Unit, onConnected: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasCam by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        )
    }
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { hasCam = it }
    LaunchedEffect(Unit) { if (!hasCam) permLauncher.launch(Manifest.permission.CAMERA) }

    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<MacEndpoint?>(null) }
    val analyzerRef = remember { arrayOfNulls<QrAnalyzer>(1) }

    // Google sign-in via Custom Tab; on return, exchange the code and finish cloud pairing.
    val authLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
        val data = res.data
        if (data == null) { status = "Google sign-in was canceled"; busy = false; analyzerRef[0]?.rearm(); return@rememberLauncherForActivityResult }
        vm.driveAuth.handleAuthResult(data) { ok, err ->
            if (ok) pending?.let { ep -> vm.connectCloud(ep) { if (it) onConnected() } }
            else { status = "Google sign-in failed" + (err?.let { ": $it" } ?: ""); busy = false; analyzerRef[0]?.rearm() }
        }
    }

    fun proceed(ep: MacEndpoint) {
        if (busy) return
        busy = true
        pending = ep
        // Already signed in (same Google account persists) → straight to the relay; else consent first.
        if (vm.driveAuth.isSignedIn) vm.connectCloud(ep) { if (it) onConnected() }
        else authLauncher.launch(vm.driveAuth.authorizeIntent(ep.account))
    }

    var showManual by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Cloud — scan the QR", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Sign the Mac into Google Drive (Settings ▸ Live Capture) and Start in Live Capture, then scan " +
                "the QR it shows — the same code works for Cloud. You'll sign in to the same Google account " +
                "the Mac uses.",
            style = MaterialTheme.typography.bodyMedium
        )

        if (hasCam) {
            val controller = remember { LifecycleCameraController(context) }
            val analyzer = remember {
                QrAnalyzer { payload ->
                    if (!busy) {
                        val ep = MacEndpoint.fromQrPayload(payload)
                        val relay = ep?.relayToken
                        // The combined QR carries the relay token (or a legacy cloud QR is all-relay); build a
                        // cloud endpoint from it — the phone chose Cloud here regardless of the QR's own mode.
                        if (relay != null) proceed(MacEndpoint("", 0, relay, ep.name, "cloud", ep.account))
                        else { status = "That QR has no cloud relay code — sign the Mac into Google Drive (Settings ▸ Live Capture), then rescan."; analyzerRef[0]?.rearm() }
                    }
                }.also { analyzerRef[0] = it }
            }
            DisposableEffect(Unit) { onDispose { analyzer.close() } }
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

        if (status.isNotEmpty()) Text(status, style = MaterialTheme.typography.bodySmall)
        else if (vm.statusMessage.isNotEmpty()) Text(vm.statusMessage, style = MaterialTheme.typography.bodySmall)

        TextButton(onClick = { showManual = !showManual }) {
            Text(if (showManual) "Hide manual entry" else "Enter the relay token manually")
        }
        if (showManual) {
            var token by remember { mutableStateOf("") }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(token, { token = it }, label = { Text("Relay token") }, singleLine = true)
                Button(onClick = {
                    val t = token.trim()
                    if (t.isNotEmpty()) proceed(MacEndpoint("", 0, t, "Mac", "cloud", null))
                }) { Text("Sign in & connect") }
            }
        }

        TextButton(onClick = onBack) { Text("← Choose connection type") }
    }
}
