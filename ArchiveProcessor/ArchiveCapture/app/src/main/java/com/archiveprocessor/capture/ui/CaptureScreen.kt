package com.archiveprocessor.capture.ui

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.archiveprocessor.capture.BuildConfig
import com.archiveprocessor.capture.capture.CaptureViewModel
import com.archiveprocessor.capture.capture.CapturedItem
import com.archiveprocessor.capture.capture.GroupType
import com.archiveprocessor.capture.capture.UploadState
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CaptureScreen(vm: CaptureViewModel) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasCam by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        )
    }
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { hasCam = it }
    LaunchedEffect(Unit) { if (!hasCam) permLauncher.launch(Manifest.permission.CAMERA) }

    // "Save to phone" → shared gallery. API 29+ needs no permission; API ≤28 needs WRITE_EXTERNAL_STORAGE,
    // requested here on tap, then the save runs on grant.
    val writeLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) vm.saveToPhone() else vm.reportCaptureError("Storage permission denied — can't save a backup to the gallery. Enable it in Settings.")
    }
    fun requestSaveToPhone() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED) {
            vm.saveToPhone()
        } else {
            writeLauncher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }
    }

    val controller = remember { LifecycleCameraController(context) }
    LaunchedEffect(hasCam) { if (hasCam) controller.bindToLifecycle(lifecycleOwner) }

    // The strip shows only current in-flight work — document pages (queued/transferring) plus any failed
    // markers to retry. Confirmed uploads leave the phone, so images never pile up here.
    val strip = vm.items.filter { it.type == GroupType.DOCUMENT || it.state == UploadState.PENDING || it.state == UploadState.FAILED }
    // Auto-scroll the strip so the newest capture stays in view.
    val listState = rememberLazyListState()
    LaunchedEffect(strip.size) {
        if (strip.isNotEmpty()) listState.animateScrollToItem(strip.size - 1)
    }

    var showClearConfirm by remember { mutableStateOf(false) }
    var showRepairConfirm by remember { mutableStateOf(false) }

    // NOTE: system-bar icon contrast is set centrally in MainActivity (light icons whenever the capture
    // screen — which is always black — is up), so there is no per-screen status-bar override to fight.

    Column(Modifier.fillMaxSize().background(Color.Black)) {
        // Camera preview — top region only, letterboxed (FIT_CENTER) on black.
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            if (hasCam) {
                AndroidView(
                    factory = { ctx ->
                        PreviewView(ctx).apply {
                            this.controller = controller
                            scaleType = PreviewView.ScaleType.FIT_CENTER
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                )
            } else {
                Text("Camera permission needed to capture.", color = Color.White)
            }
        }

        // Controls region (below the preview). Padded above the nav bar (edge-to-edge insets) plus an
        // extra ergonomic lift so the shoot buttons sit higher in the thumb zone; the dark background is
        // applied first so it still fills down to the bottom edge behind the translucent nav bar.
        Column(
            Modifier
                .fillMaxWidth()
                .background(Color(0xFF141414))
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = 12.dp, vertical = 10.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Connection status + Re-pair. Once paired the app goes straight to this screen, so this is
            // the only way back to the QR scanner — e.g. to switch a USB-paired phone (host 127.0.0.1)
            // over to Wi-Fi. Captured photos are kept and upload after reconnecting.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(vm.endpoint?.let { "Connected · ${it.name}" } ?: "Not connected",
                     color = Color(0xFF8E8E93), style = MaterialTheme.typography.labelMedium)
                Spacer(Modifier.weight(1f))
                // Backup safety net: copy what's on the phone to the gallery if it won't transfer.
                if (vm.items.isNotEmpty()) {
                    TextButton(onClick = { requestSaveToPhone() }) { Text("Save to phone", color = Color.White) }
                }
                TextButton(
                    onClick = { showRepairConfirm = true },
                    modifier = Modifier.semantics { contentDescription = "Re-pair with a Mac" }
                ) { Text("Re-pair", color = Color.White) }
            }

            // End segment — above the photos and away from the shutter, to avoid accidental taps. This is
            // the ONLY "done" action: a document is finished when you tap End segment (there is no separate
            // "Finish" — its pages already streamed to the Mac, so ending the segment sends the completion
            // signal that makes the Mac present this segment's tag card). Tagging itself is done on the Mac.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                if (vm.items.isNotEmpty()) {
                    TextButton(onClick = { showClearConfirm = true }) { Text("Clear", color = Color.White) }
                }
                if (vm.items.any { it.state == UploadState.FAILED }) {
                    TextButton(onClick = { vm.retryFailed() }) { Text("Retry", color = Color.White) }
                }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = { vm.finishDocumentSegment() },
                    modifier = Modifier.semantics { contentDescription = "End segment" }
                ) { Text("End segment") }
            }

            // Transfer feedback: segments/markers fly to the Mac; images don't accumulate on the phone.
            val uploading = vm.items.count { it.state == UploadState.UPLOADING }
            if (vm.transferFlash != null || uploading > 0) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AnimatedVisibility(visible = vm.transferFlash != null, enter = fadeIn(), exit = fadeOut()) {
                        Text("⤴ ${vm.transferFlash ?: ""}", color = Color(0xFF34C759), style = MaterialTheme.typography.labelLarge)
                    }
                    Spacer(Modifier.weight(1f))
                    if (uploading > 0) Text("Transferring $uploading…", color = Color(0xFFFFCC00), style = MaterialTheme.typography.labelMedium)
                }
            }

            // Status line — surfaces capture errors (a failed shutter can't be silent; archival photos
            // can't be re-taken) and the recovered-segment prompt after a restart.
            if (vm.statusMessage.isNotEmpty()) {
                Text(vm.statusMessage, color = Color.White, style = MaterialTheme.typography.bodySmall,
                     modifier = Modifier.fillMaxWidth())
            }

            // Current segment (auto-scrolling; tap a page to toggle its P10 override). Show EVERY item the
            // model holds — including pages already UPLOADED — so the operator watches the segment grow as
            // photos are taken. Membership is decided solely by the model (`removeConfirmed` keeps
            // current-segment pages); do NOT gate visibility on upload/transfer state here.
            if (strip.isNotEmpty()) {
                LazyRow(state = listState, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(strip, key = { it.id }) { item ->
                        Thumb(
                            item = item,
                            isSelected = vm.selectedItemId == item.id && !vm.armed,
                            isArmed = vm.selectedItemId == item.id && vm.armed,
                            onTap = { vm.tapItem(item.id) },
                            onLongPress = { vm.toggleP10(item.id) }
                        )
                    }
                }
            }

            // Capture row: Box (red) · white shutter · Folder (purple). Shutter is at the very bottom.
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                val hasSelection = vm.selectedItemId != null
                Button(
                    onClick = {
                        if (vm.selectedItemId != null) vm.reclassifySelected(GroupType.BOX)
                        else takePicture(context, controller, vm) { vm.captureMarker(it, GroupType.BOX) }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F), contentColor = Color.White),
                    modifier = Modifier.semantics {
                        contentDescription = if (hasSelection) "Reclassify the selected photo as a box marker"
                                             else "Box. Capture a box-label marker"
                    }
                ) { Text("Box") }

                Button(
                    onClick = { takePicture(context, controller, vm) { vm.addDocumentPhoto(it) } },
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White),
                    modifier = Modifier.size(76.dp).border(3.dp, Color.LightGray, CircleShape)
                        .semantics { contentDescription = "Shutter. Capture a document page" }
                ) { }

                Button(
                    onClick = {
                        if (vm.selectedItemId != null) vm.reclassifySelected(GroupType.FOLDER)
                        else takePicture(context, controller, vm) { vm.captureMarker(it, GroupType.FOLDER) }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF7B1FA2), contentColor = Color.White),
                    modifier = Modifier.semantics {
                        contentDescription = if (hasSelection) "Reclassify the selected photo as a folder marker"
                                             else "Folder. Capture a folder-label marker"
                    }
                ) { Text("Folder") }
            }
        }
    }

    // Segment tag sheet. Gesture-dismiss is DISABLED (confirmValueChange blocks swipe-to-hide; the
    // scrim/back onDismissRequest is a no-op) so an accidental swipe can't silently strand the just-ended
    // document. The operator must choose: Apply & continue / Skip (both end the segment and send it to the
    // Mac) or Cancel — keep shooting (End segment was a mistake; keep adding to the same document).
    if (vm.pendingTagGroupId != null) {
        val sheetState = rememberModalBottomSheetState(
            skipPartiallyExpanded = true,
            confirmValueChange = { it != SheetValue.Hidden }
        )
        ModalBottomSheet(onDismissRequest = { }, sheetState = sheetState) {
            SegmentTagSheet(
                recentYears = vm.recentYears(),
                onApply = { p, y, m -> vm.applyTagsAndContinue(p, y, m) },
                onCancel = { vm.cancelTagSheet() }
            )
        }
    }

    // Confirm before clearing (deletes photos from the phone — destructive).
    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title = { Text("Clear all photos?") },
            text = { Text("This permanently deletes all ${vm.items.size} captured photo(s) from this phone and cannot be undone.") },
            confirmButton = {
                TextButton(onClick = { vm.clearSession(); showClearConfirm = false }) {
                    Text("Clear", color = Color(0xFFD32F2F))
                }
            },
            dismissButton = { TextButton(onClick = { showClearConfirm = false }) { Text("Cancel") } }
        )
    }

    // Re-pair: disconnect and return to the pairing screen (e.g. to move from USB to Wi-Fi). Non-destructive.
    if (showRepairConfirm) {
        AlertDialog(
            onDismissRequest = { showRepairConfirm = false },
            title = { Text("Re-pair with a Mac?") },
            text = { Text("Disconnects from ${vm.endpoint?.name ?: "the Mac"} and returns to the pairing screen so you can scan a QR — e.g. to switch from USB to Wi-Fi. Any captured photos are kept and upload once you reconnect.") },
            confirmButton = { TextButton(onClick = { vm.disconnect(); showRepairConfirm = false }) { Text("Re-pair") } },
            dismissButton = { TextButton(onClick = { showRepairConfirm = false }) { Text("Cancel") } }
        )
    }
}

private fun takePicture(
    context: android.content.Context,
    controller: LifecycleCameraController,
    vm: CaptureViewModel,
    onSaved: (File) -> Unit
) {
    val captureToken = vm.beginCaptureToken()
    if (captureToken == null) {
        vm.reportCaptureError("Still clearing the previous session — try the photo again.")
        return
    }
    val file = vm.newCaptureFile()
    fun deliverIfCurrent() {
        if (vm.isCaptureTokenCurrent(captureToken)) onSaved(file)
        else { runCatching { file.delete() } }
    }
    // TEST SEAM (DEBUG-ONLY — stripped from release by the BuildConfig.DEBUG guard). For a deterministic,
    // headless phone↔Mac E2E: if the harness has pushed an inject image to files/test_inject.jpg
    // (adb shell run-as … cp … files/test_inject.jpg), use ITS pixels instead of the camera — copied into
    // the exact URL vm.newCaptureFile() chose — then route through the SAME onSaved() (addDocumentPhoto /
    // captureMarker) as a real shot. So the durable on-phone queue + upload path is byte-identical to a
    // real capture; the ONLY change is the pixel source. The inject file is consumed (deleted) so each
    // shutter tap needs a fresh push. No inject file (or a release build) → the normal CameraX path below
    // runs UNCHANGED.
    if (BuildConfig.DEBUG) {
        val inject = File(context.filesDir, "test_inject.jpg")
        if (inject.exists()) {
            val copied = runCatching {
                inject.inputStream().use { input -> file.outputStream().use { output -> input.copyTo(output) } }
            }.isSuccess
            runCatching { inject.delete() }   // consume: each shutter tap needs a fresh push
            if (copied) {
                deliverIfCurrent()
            } else {
                runCatching { file.delete() }
                vm.reportCaptureError("Test inject failed — please retake.")
            }
            return
        }
    }
    val opts = ImageCapture.OutputFileOptions.Builder(file).build()
    controller.takePicture(
        opts,
        ContextCompat.getMainExecutor(context),
        object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(results: ImageCapture.OutputFileResults) { deliverIfCurrent() }
            override fun onError(exception: ImageCaptureException) {
                // A failed capture must NOT be silent — an archival page can't be re-taken. Remove any
                // partial file and surface the failure so the operator re-shoots.
                runCatching { file.delete() }
                if (vm.isCaptureTokenCurrent(captureToken)) {
                    vm.reportCaptureError("Capture failed — please retake. (${exception.message ?: "camera error"})")
                }
            }
        }
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Thumb(
    item: CapturedItem,
    isSelected: Boolean,
    isArmed: Boolean,
    onTap: () -> Unit,
    onLongPress: () -> Unit
) {
    val bmp: ImageBitmap? = remember(item.file.path) { decodeThumb(item.file.path) }
    // Once a photo is saved to the phone's gallery it is safe locally, so it must no longer READ as failed:
    // its status dot turns teal (with a saved-badge below) regardless of the upload/queue state, which is
    // unchanged underneath — this is display state only (the item can still be UPLOADING/FAILED for the Mac).
    val stateColor = if (item.savedToPhone) Color(0xFF30B0C7) else when (item.state) {
        UploadState.UPLOADED -> Color(0xFF34C759)
        UploadState.UPLOADING -> Color(0xFFFFCC00)
        UploadState.FAILED -> Color(0xFFFF3B30)
        UploadState.PENDING -> Color.Gray
    }
    val isP10 = item.priority == "P10"
    val ring = when {
        isArmed -> Color(0xFFFF3B30)     // red: tap again to delete
        isSelected -> Color(0xFF0A84FF)  // blue: selected
        isP10 -> Color(0xFFFFD60A)       // gold: P10
        else -> null
    }
    // TalkBack label: type + status (+ P10 / delete-armed) so the thumbnails aren't unlabeled.
    val typeLabel = when (item.type) {
        GroupType.DOCUMENT -> "Document page"
        GroupType.BOX -> "Box marker"
        GroupType.FOLDER -> "Folder marker"
    }
    val statusLabel = when {
        item.savedToPhone -> "saved to phone gallery"
        item.state == UploadState.UPLOADED -> "sent to Mac"
        item.state == UploadState.UPLOADING -> "sending to Mac"
        item.state == UploadState.FAILED -> "upload failed, will retry"
        else -> "queued to send"
    }
    val a11yLabel = buildString {
        append(typeLabel); append(", "); append(statusLabel)
        if (isP10) append(", priority P10")
        if (isArmed) append(", tap again to delete")
    }
    Box(
        Modifier.size(64.dp).clip(RoundedCornerShape(6.dp)).background(Color.DarkGray)
            .then(if (ring != null) Modifier.border(3.dp, ring, RoundedCornerShape(6.dp)) else Modifier)
            .combinedClickable(onClick = onTap, onLongClick = onLongPress)
            .semantics { contentDescription = a11yLabel }
    ) {
        if (bmp != null) {
            Image(bitmap = bmp, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Box(Modifier.align(Alignment.BottomStart).padding(3.dp).size(10.dp).clip(CircleShape).background(stateColor))
        // "Saved to phone" affordance: a small check badge so a gallery-saved photo reads as safe, not failed.
        if (item.savedToPhone && !isArmed) {
            Box(
                Modifier.align(Alignment.BottomEnd).padding(2.dp).size(14.dp).clip(CircleShape)
                    .background(Color(0xFF30B0C7)),
                contentAlignment = Alignment.Center
            ) {
                Text("✓", color = Color.White, style = MaterialTheme.typography.labelSmall)
            }
        }
        if (isP10 && !isArmed) {
            Box(Modifier.align(Alignment.TopEnd).padding(2.dp).clip(RoundedCornerShape(3.dp)).background(Color.Red)) {
                Text("P10", color = Color.White, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 2.dp))
            }
        }
        if (isArmed) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)), contentAlignment = Alignment.Center) {
                Text("✕", color = Color.White, style = MaterialTheme.typography.headlineMedium)
            }
        }
    }
}

/** Downsampled thumbnail decode so the strip never loads full-resolution camera JPEGs. */
private fun decodeThumb(path: String, target: Int = 200): ImageBitmap? = try {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    var sample = 1
    while (bounds.outWidth / sample > target || bounds.outHeight / sample > target) sample *= 2
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    BitmapFactory.decodeFile(path, opts)?.asImageBitmap()
} catch (e: Exception) {
    null
}
