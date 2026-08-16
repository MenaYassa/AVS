package com.example.data.audio

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileInputStream

class AudioRecorder(private val context: Context) {
    private var mediaRecorder: MediaRecorder? = null
    private var currentOutputFile: File? = null
    private var isRecording = false

    private val recordingsDir: File by lazy {
        File(context.filesDir, "recordings").apply {
            if (!exists()) {
                mkdirs()
            }
        }
    }

    fun startRecording(): File? {
        try {
            val file = File(recordingsDir, "rec_${System.currentTimeMillis()}.m4a")
            currentOutputFile = file

            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(44100)
                setAudioEncodingBitRate(128000)
                setOutputFile(file.absolutePath)
                prepare()
                start()
            }
            isRecording = true
            Log.d("AudioRecorder", "Recording started successfully to: ${file.absolutePath}")
            return file
        } catch (e: SecurityException) {
            Log.e("AudioRecorder", "SecurityException: RECORD_AUDIO permission missing", e)
            cleanup()
            return null
        } catch (e: Exception) {
            Log.e("AudioRecorder", "Failed to start recording: ${e.message}", e)
            cleanup()
            return null
        }
    }

    fun getMaxAmplitude(): Int {
        return if (isRecording) {
            try {
                mediaRecorder?.maxAmplitude ?: 0
            } catch (e: Exception) {
                0
            }
        } else {
            0
        }
    }

    fun stopRecording(): ByteArray? {
        if (!isRecording) return null
        return try {
            mediaRecorder?.apply {
                try {
                    stop()
                } catch (e: Exception) {
                    Log.w("AudioRecorder", "Stop exception (possibly short recording): ${e.message}")
                }
                release()
            }
            mediaRecorder = null
            isRecording = false

            currentOutputFile?.let { file ->
                if (file.exists() && file.length() > 0) {
                    Log.d("AudioRecorder", "Recording saved: ${file.absolutePath}, size: ${file.length()} bytes")
                    val bytes = ByteArray(file.length().toInt())
                    FileInputStream(file).use { it.read(bytes) }
                    bytes
                } else {
                    Log.w("AudioRecorder", "Recording file is empty or missing")
                    null
                }
            }
        } catch (e: Exception) {
            Log.e("AudioRecorder", "Failed to stop recording: ${e.message}", e)
            cleanup()
            null
        }
    }

    fun cancel() {
        try {
            if (isRecording) {
                try {
                    mediaRecorder?.stop()
                } catch (e: Exception) {
                    // ignore
                }
            }
            cleanup()
            currentOutputFile?.delete()
            currentOutputFile = null
        } catch (e: Exception) {
            cleanup()
        }
    }

    private fun cleanup() {
        try {
            mediaRecorder?.release()
        } catch (e: Exception) {
            // ignore
        }
        mediaRecorder = null
        isRecording = false
    }
}
