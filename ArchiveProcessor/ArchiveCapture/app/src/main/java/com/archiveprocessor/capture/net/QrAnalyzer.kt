package com.archiveprocessor.capture.net

import androidx.annotation.OptIn
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

/** CameraX analyzer that decodes QR codes with ML Kit and reports the first raw value once.
 *  Closeable: call [close] when the pairing UI goes away so the native ML Kit detector is released. */
class QrAnalyzer(private val onQr: (String) -> Unit) : ImageAnalysis.Analyzer, java.io.Closeable {
    private val scanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    )
    @Volatile private var done = false
    @Volatile private var closed = false

    /** Re-arm after a decoded QR failed to connect, so pointing at the code again re-fires the callback.
     *  Without this, `done` latches on the first decode and the scanner is a dead end (can't retry). */
    fun rearm() { done = false }

    override fun close() { closed = true; runCatching { scanner.close() } }

    @OptIn(ExperimentalGetImage::class)
    override fun analyze(imageProxy: ImageProxy) {
        val media = imageProxy.image
        // `closed`: frames can still arrive after the pairing UI leaves (the controller is bound to the
        // Activity lifecycle), so no-op once closed — calling scanner.process on a closed ML Kit
        // detector throws on the main thread.
        if (media == null || done || closed) {
            imageProxy.close()
            return
        }
        val input = InputImage.fromMediaImage(media, imageProxy.imageInfo.rotationDegrees)
        scanner.process(input)
            .addOnSuccessListener { barcodes ->
                barcodes.firstOrNull()?.rawValue?.let {
                    if (!done) {
                        done = true
                        onQr(it)
                    }
                }
            }
            .addOnCompleteListener { imageProxy.close() }
    }
}
