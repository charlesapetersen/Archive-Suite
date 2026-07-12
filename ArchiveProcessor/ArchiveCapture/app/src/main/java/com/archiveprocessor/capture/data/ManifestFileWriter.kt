package com.archiveprocessor.capture.data

import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

/** Crash-safe manifest replacement. The previous destination is never explicitly removed: an unsuccessful
 * publish leaves it intact, while the fully-written/fsynced temporary sibling is installed with replacement
 * semantics in one filesystem operation. */
internal object ManifestFileWriter {
    internal fun replace(
        destination: File,
        bytes: ByteArray,
        move: (Path, Path) -> Unit = ::moveReplacing
    ): Boolean {
        val parent = destination.parentFile ?: return false
        parent.mkdirs()
        val temporary = File.createTempFile("${destination.name}.", ".tmp", parent)
        return try {
            FileOutputStream(temporary).use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
            move(temporary.toPath(), destination.toPath())
            true
        } catch (_: Exception) {
            false
        } finally {
            // After a successful move the temporary path no longer exists. On failure it is ours to clean.
            temporary.delete()
        }
    }

    private fun moveReplacing(source: Path, destination: Path) {
        try {
            Files.move(source, destination,
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (_: AtomicMoveNotSupportedException) {
            // Same-directory replacement is still preferable to deleting the good destination first.
            Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
