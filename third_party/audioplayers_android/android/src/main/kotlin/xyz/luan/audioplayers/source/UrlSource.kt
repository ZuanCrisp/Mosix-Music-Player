package xyz.luan.audioplayers.source

import android.media.MediaPlayer
import android.os.ParcelFileDescriptor
import xyz.luan.audioplayers.player.SoundPoolPlayer
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.net.URL

data class UrlSource(
    val url: String,
    val isLocal: Boolean,
) : Source {
    override fun setForMediaPlayer(mediaPlayer: MediaPlayer) {
        val descriptor = if (isLocal && url.startsWith("/proc/self/fd/")) {
            url.removePrefix("/proc/self/fd/").toIntOrNull()?.takeIf { it >= 0 }
        } else null
        if (descriptor != null) {
            // AppFuse proxies (e.g. network SAF providers) reject a second
            // open. dup() preserves the already granted, seekable descriptor.
            ParcelFileDescriptor.fromFd(descriptor).use {
                mediaPlayer.setDataSource(it.fileDescriptor)
            }
        } else {
            mediaPlayer.setDataSource(url)
        }
    }

    override fun setForSoundPool(soundPoolPlayer: SoundPoolPlayer) {
        soundPoolPlayer.release()
        soundPoolPlayer.urlSource = this
    }

    fun getAudioPathForSoundPool(): String {
        if (isLocal) {
            return url.removePrefix("file://")
        }

        return loadTempFileFromNetwork().absolutePath
    }

    private fun loadTempFileFromNetwork(): File {
        val bytes = downloadUrl(URI.create(url).toURL())
        val tempFile = File.createTempFile("sound", "")
        FileOutputStream(tempFile).use {
            it.write(bytes)
            tempFile.deleteOnExit()
        }
        return tempFile
    }

    private fun downloadUrl(url: URL): ByteArray {
        val outputStream = ByteArrayOutputStream()
        url.openStream().use { stream ->
            val chunk = ByteArray(4096)
            while (true) {
                val bytesRead = stream.read(chunk).takeIf { it > 0 } ?: break
                outputStream.write(chunk, 0, bytesRead)
            }
        }
        return outputStream.toByteArray()
    }
}
