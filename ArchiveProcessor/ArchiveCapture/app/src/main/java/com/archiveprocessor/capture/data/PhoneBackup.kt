package com.archiveprocessor.capture.data

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/** Exports captured JPEGs to the phone's shared photo gallery (Pictures/Archive Capture), so the
 *  operator has a retrievable local backup if photos can't transfer to the Mac. On API 29+ this uses
 *  scoped-storage MediaStore (no permission); on API ≤28 it needs WRITE_EXTERNAL_STORAGE (the caller
 *  requests it before invoking). Copies are independent of the app's own queue — clearing the session
 *  never touches them. */
object PhoneBackup {
    private const val ALBUM = "Archive Capture"

    /** Copy one JPEG into the shared gallery. Returns true on success; never throws. */
    fun saveJpegToGallery(context: Context, file: File): Boolean {
        if (!file.exists()) return false
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$ALBUM")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = try {
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        } catch (e: Exception) { null } ?: return false
        return try {
            val wrote = resolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out) }; true
            } ?: false
            if (!wrote) throw java.io.IOException("could not open output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val done = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            }
            true
        } catch (e: Exception) {
            // Any failure after the row was inserted (open/copy/update threw, or the stream was null) →
            // roll back the half-created gallery entry so no orphaned pending row or corrupt/partial image
            // is left behind (which would also make the saved-count disagree with what's on disk).
            runCatching { resolver.delete(uri, null, null) }
            false
        }
    }
}
