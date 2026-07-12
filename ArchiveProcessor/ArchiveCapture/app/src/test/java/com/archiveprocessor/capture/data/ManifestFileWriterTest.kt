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
    fun `successful publish replaces the manifest`() {
        val dir = Files.createTempDirectory("manifest-writer-test").toFile()
        val manifest = dir.resolve("session.json")
        manifest.writeText("OLD")

        assertTrue(ManifestFileWriter.replace(manifest, "NEW".toByteArray()))
        assertEquals("NEW", manifest.readText())
        dir.deleteRecursively()
    }
}
