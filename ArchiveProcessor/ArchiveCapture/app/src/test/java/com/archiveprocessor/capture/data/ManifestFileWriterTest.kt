package com.archiveprocessor.capture.data

import java.io.IOException
import java.nio.file.Path
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManifestFileWriterTest {
    @Test
    fun `failed publish retains the last good manifest`() {
        val dir = Files.createTempDirectory("manifest-writer-test").toFile()
        val manifest = dir.resolve("session.json")
        manifest.writeText("GOOD")

        val replaced = ManifestFileWriter.replace(manifest, "NEW".toByteArray()) { _: Path, _: Path ->
            throw IOException("injected replacement failure")
        }

        assertFalse(replaced)
        assertEquals("GOOD", manifest.readText())
        assertTrue(dir.listFiles()?.none { it.name.endsWith(".tmp") } == true)
        dir.deleteRecursively()
    }

    @Test
    fun `an unwritable parent is reported, not thrown`() {
        // W23.m8 — createTempFile sat outside the try, so this threw straight past the function whose
        // Boolean is now the caller's only evidence that a snapshot reached disk. A regular file where the
        // parent directory belongs is the shape of that: mkdirs() can't fix it and the sibling can't be made.
        val dir = Files.createTempDirectory("manifest-writer-test").toFile()
        val notADirectory = dir.resolve("parent").apply { writeText("i am a file") }

        assertFalse(ManifestFileWriter.replace(notADirectory.resolve("session.json"), "NEW".toByteArray()))

        assertEquals("i am a file", notADirectory.readText())
        dir.deleteRecursively()
    }

    @Test
    fun `successful publish replaces the manifest`() {
        val dir = Files.createTempDirectory("manifest-writer-test").toFile()
        val manifest = dir.resolve("session.json")
        manifest.writeText("OLD")

        assertTrue(ManifestFileWriter.replace(manifest, "NEW".toByteArray()))
        assertEquals("NEW", manifest.readText())
        dir.deleteRecursively()
    }
}
