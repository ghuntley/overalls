package dev.overalls.mila.nativeui

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest

/**
 * @cc [owner:ghuntley,label:security;privacy] mila-android-durable-snapshot
 * Only complete Rust-validated snapshot bytes may persist. Every read and write
 * binds the management host and SSH port. A new bind fences previous generations;
 * atomically replaced owner-only regular files retain the newest saved_at. Cached
 * rows are display-only and never establish authenticated session authority.
 */
internal class MilaSnapshotStore(
    private val directory: File,
    private val validate: (ByteArray, MilaDeployment) -> Long? = { bytes, deployment ->
        runCatching { MilaRustFfi.snapshotSavedAt(bytes, deployment.host, deployment.port) }.getOrNull()
    },
) {
    private var generation = 0L
    private var target: MilaDeployment? = null

    @Synchronized fun bind(deployment: MilaDeployment?): Long {
        generation += 1
        target = deployment
        return generation
    }

    @Synchronized fun load(deployment: MilaDeployment): MilaSessionListing? = read(deployment)?.let { MilaSessionListing.decode(it) }

    @Synchronized fun save(bytes: ByteArray, deployment: MilaDeployment, expectedGeneration: Long): Boolean {
        if (generation != expectedGeneration || target != deployment) return false
        require(bytes.size <= MAX_BYTES)
        val fresh = validate(bytes, deployment) ?: throw IllegalArgumentException("invalid snapshot")
        val existing = read(deployment)
        if (existing != null && (validate(existing, deployment) ?: error("invalid snapshot")) >= fresh) return false
        ensureDirectory()
        val temporary = Files.createTempFile(directory.toPath(), "snapshot-", ".new", PosixFilePermissions.asFileAttribute(FILE_PERMISSIONS))
        try {
            java.nio.channels.FileChannel.open(temporary, java.nio.file.StandardOpenOption.WRITE).use { channel ->
                val buffer = java.nio.ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) channel.write(buffer)
                channel.force(true)
            }
            Files.move(temporary, path(deployment), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { Files.deleteIfExists(temporary) }
        return true
    }

    @Synchronized fun forget(deployment: MilaDeployment) {
        if (target == deployment) generation += 1
        if (directory.exists()) {
            requireOwnerOnly(directory.toPath(), true)
            Files.deleteIfExists(path(deployment))
        }
    }

    private fun path(deployment: MilaDeployment): java.nio.file.Path {
        val authority = "${deployment.host}:${deployment.port}"
        val digest = MessageDigest.getInstance("SHA-256").digest(authority.toByteArray(Charsets.UTF_8))
        return directory.toPath().resolve(digest.joinToString("") { "%02x".format(it) } + ".json")
    }

    private fun read(deployment: MilaDeployment): ByteArray? {
        if (!directory.exists()) return null
        requireOwnerOnly(directory.toPath(), true)
        val path = path(deployment)
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return null
        requireOwnerOnly(path, false)
        require(Files.size(path) <= MAX_BYTES)
        val bytes = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { stream ->
            val output = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            while (output.size() <= MAX_BYTES) {
                val count = stream.read(chunk, 0, minOf(chunk.size, MAX_BYTES + 1 - output.size()))
                if (count < 0) break
                output.write(chunk, 0, count)
            }
            output.toByteArray()
        }
        require(bytes.size <= MAX_BYTES && validate(bytes, deployment) != null)
        return bytes
    }

    private fun ensureDirectory() {
        Files.createDirectories(directory.toPath(), PosixFilePermissions.asFileAttribute(DIRECTORY_PERMISSIONS))
        requireOwnerOnly(directory.toPath(), true)
    }

    private fun requireOwnerOnly(path: java.nio.file.Path, isDirectory: Boolean) {
        require(!Files.isSymbolicLink(path))
        require(if (isDirectory) Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) else Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
        require(Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS).none { it in OTHER_PERMISSIONS })
    }

    companion object {
        private const val MAX_BYTES = 1 shl 20
        private val FILE_PERMISSIONS = PosixFilePermissions.fromString("rw-------")
        private val DIRECTORY_PERMISSIONS = PosixFilePermissions.fromString("rwx------")
        private val OTHER_PERMISSIONS = setOf(PosixFilePermission.GROUP_READ, PosixFilePermission.GROUP_WRITE,
            PosixFilePermission.GROUP_EXECUTE, PosixFilePermission.OTHERS_READ, PosixFilePermission.OTHERS_WRITE, PosixFilePermission.OTHERS_EXECUTE)
    }
}
