package dev.overalls.mila.nativeui

import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import org.junit.Assert.*
import org.junit.Test

class MilaSnapshotsTest {
    private val deployment = MilaDeployment("mgmt.example.test", 22)
    private fun snapshot(time: Long): ByteArray = """{"version":1,"host":"mgmt.example.test","port":22,"saved_at":$time,"machines":[]}""".toByteArray()
    // Native ABI tests exercise Rust validation; these JVM tests isolate durable
    // filesystem, restart and generation behavior through the validated seam.
    private fun store(directory: java.io.File): MilaSnapshotStore = MilaSnapshotStore(directory) { bytes, target ->
        runCatching {
            val root = org.json.JSONObject(bytes.toString(Charsets.UTF_8))
            require(root.getInt("version") == 1 && root.getString("host") == target.host && root.getInt("port") == target.port)
            root.getLong("saved_at")
        }.getOrNull()
    }

    @Test fun restartNewestWinsAndStaleGenerationCannotWrite() {
        val root = Files.createTempDirectory("mila-snapshot-test").toFile()
        try {
            val directory = java.io.File(root, "snapshots")
            val cache = store(directory)
            val generation = cache.bind(deployment)
            assertTrue(cache.save(snapshot(20), deployment, generation))
            assertFalse(cache.save(snapshot(10), deployment, generation))
            cache.bind(MilaDeployment("other.example.test", 22))
            assertFalse(cache.save(snapshot(30), deployment, generation))
            assertNotNull(store(directory).load(deployment))
            assertNull(store(directory).load(deployment.copy(port = 2222)))
            val bytes = directory.listFiles()!!.single().readText()
            assertTrue(bytes.contains("\"saved_at\":20"))
            cache.forget(deployment)
            assertNull(store(directory).load(deployment))
        } finally { root.deleteRecursively() }
    }

    @Test fun sharedAndSymlinkedStorageRefused() {
        val root = Files.createTempDirectory("mila-snapshot-test").toFile()
        try {
            val directory = java.io.File(root, "snapshots")
            val cache = store(directory)
            val generation = cache.bind(deployment)
            assertTrue(cache.save(snapshot(1), deployment, generation))
            val path = directory.listFiles()!!.single().toPath()
            Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rw-r-----"))
            assertTrue(runCatching { cache.load(deployment) }.isFailure)
            Files.delete(path)
            Files.createSymbolicLink(path, root.toPath())
            assertTrue(runCatching { cache.load(deployment) }.isFailure)
        } finally { root.deleteRecursively() }
    }
}
