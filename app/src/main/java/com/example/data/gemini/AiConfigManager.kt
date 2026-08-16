package com.example.data.gemini

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

enum class AiProviderMode(val displayName: String, val description: String) {
    DEFAULT_GEMINI("AI Studio Gemini", "Pre-configured Gemini 3.5 Flash & 3.1 Pro via AI Studio"),
    CUSTOM_OPENAI_COMPATIBLE("Custom OpenAI / Ollama / Groq", "Connect any OpenAI-compatible STT & LLM endpoint"),
    CUSTOM_GEMINI("Custom Gemini API", "Use your own Google Gemini API key & custom models")
}

@Serializable
data class AiConfig(
    val mode: String = AiProviderMode.DEFAULT_GEMINI.name,
    val llmBaseUrl: String = "https://api.openai.com/v1",
    val llmApiKey: String = "",
    val llmModel: String = "gpt-4o",
    val sttBaseUrl: String = "https://api.openai.com/v1",
    val sttApiKey: String = "",
    val sttModel: String = "whisper-1",
    val isVerified: Boolean = false,
    val lastVerificationMessage: String = "",
    val lastVerificationTime: Long = 0L
)

class AiConfigManager private constructor(context: Context) {

    private val prefs: SharedPreferences = context.getSharedPreferences("ai_custom_config_prefs", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _configState = MutableStateFlow(loadConfig())
    val configState: StateFlow<AiConfig> = _configState.asStateFlow()

    private val okHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(45, TimeUnit.SECONDS)
        .build()

    private fun loadConfig(): AiConfig {
        val raw = prefs.getString(KEY_CONFIG, null) ?: return AiConfig()
        return try {
            json.decodeFromString<AiConfig>(raw)
        } catch (e: Exception) {
            AiConfig()
        }
    }

    fun saveConfig(config: AiConfig) {
        prefs.edit().putString(KEY_CONFIG, json.encodeToString(config)).apply()
        _configState.value = config
    }

    fun resetToDefault() {
        val defaultConfig = AiConfig(mode = AiProviderMode.DEFAULT_GEMINI.name)
        saveConfig(defaultConfig)
    }

    suspend fun verifyLlmConnection(config: AiConfig): Result<String> = withContext(Dispatchers.IO) {
        val startTime = System.currentTimeMillis()
        try {
            when (config.mode) {
                AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name -> {
                    val baseUrl = config.llmBaseUrl.trim().trimEnd('/')
                    val url = if (baseUrl.endsWith("/chat/completions")) baseUrl else "$baseUrl/chat/completions"
                    
                    val payload = """
                        {
                            "model": "${config.llmModel.trim()}",
                            "messages": [
                                {"role": "system", "content": "You are a test ping service."},
                                {"role": "user", "content": "Reply with 'Connection verified successfully' in under 6 words."}
                            ],
                            "max_tokens": 20,
                            "temperature": 0.2
                        }
                    """.trimIndent()

                    val requestBuilder = Request.Builder()
                        .url(url)
                        .post(payload.toRequestBody("application/json".toMediaType()))

                    if (config.llmApiKey.isNotBlank()) {
                        requestBuilder.addHeader("Authorization", "Bearer ${config.llmApiKey.trim()}")
                    }

                    val response = okHttpClient.newCall(requestBuilder.build()).execute()
                    val latency = System.currentTimeMillis() - startTime
                    val body = response.body?.string() ?: ""

                    if (response.isSuccessful) {
                        // Extract content if possible
                        val responseSnippet = if (body.contains("\"content\":")) {
                            body.substringAfter("\"content\":").substringAfter("\"").substringBefore("\"")
                        } else {
                            "Status ${response.code} OK"
                        }
                        val msg = "Success (${latency}ms): Connected to ${config.llmModel}. Response: \"$responseSnippet\""
                        val updated = config.copy(
                            isVerified = true,
                            lastVerificationMessage = msg,
                            lastVerificationTime = System.currentTimeMillis()
                        )
                        saveConfig(updated)
                        Result.success(msg)
                    } else {
                        val errMsg = "HTTP ${response.code}: ${response.message}. Response: ${body.take(150)}"
                        Result.failure(Exception(errMsg))
                    }
                }

                AiProviderMode.CUSTOM_GEMINI.name -> {
                    val baseUrl = config.llmBaseUrl.trim().trimEnd('/')
                    val apiKey = config.llmApiKey.trim()
                    val model = config.llmModel.trim().ifBlank { "gemini-2.5-flash" }
                    val url = "$baseUrl/v1beta/models/$model:generateContent?key=$apiKey"

                    val payload = """
                        {
                            "contents": [
                                {
                                    "parts": [{"text": "Reply with 'Gemini connected' in 2 words."}]
                                }
                            ]
                        }
                    """.trimIndent()

                    val request = Request.Builder()
                        .url(url)
                        .post(payload.toRequestBody("application/json".toMediaType()))
                        .build()

                    val response = okHttpClient.newCall(request).execute()
                    val latency = System.currentTimeMillis() - startTime
                    val body = response.body?.string() ?: ""

                    if (response.isSuccessful) {
                        val msg = "Success (${latency}ms): Connected to Gemini ($model)."
                        val updated = config.copy(
                            isVerified = true,
                            lastVerificationMessage = msg,
                            lastVerificationTime = System.currentTimeMillis()
                        )
                        saveConfig(updated)
                        Result.success(msg)
                    } else {
                        Result.failure(Exception("HTTP ${response.code}: ${body.take(150)}"))
                    }
                }

                else -> {
                    // Default Gemini test
                    val res = GeminiClient.generateFastResponse("Say 'AI Studio Gemini ready' in 5 words.")
                    val latency = System.currentTimeMillis() - startTime
                    res.map { "Success (${latency}ms): AI Studio Gemini verified. ($it)" }
                }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun verifySttConnection(config: AiConfig): Result<String> = withContext(Dispatchers.IO) {
        val startTime = System.currentTimeMillis()
        try {
            when (config.mode) {
                AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name -> {
                    val rawUrl = sanitizeUrl(config.sttBaseUrl)
                    if (rawUrl.isBlank()) {
                        return@withContext Result.failure(Exception("STT Endpoint URL is empty"))
                    }

                    // Candidate URLs for whisper server:
                    val candidateUrls = if (rawUrl.endsWith("/asr") || rawUrl.endsWith("/audio/transcriptions") || rawUrl.endsWith("/transcribe")) {
                        listOf(rawUrl)
                    } else {
                        listOf(
                            "$rawUrl/asr", // whisper-asr webservice / fast-whisper server
                            if (rawUrl.endsWith("/v1")) "$rawUrl/audio/transcriptions" else "$rawUrl/v1/audio/transcriptions",
                            "$rawUrl/audio/transcriptions"
                        )
                    }

                    val key = config.sttApiKey.trim().ifBlank { config.llmApiKey.trim() }
                    var lastError = "Could not reach STT server"
                    val validWavBytes = createValidWavSilence(durationSeconds = 0.25f, sampleRate = 16000)

                    for (targetUrl in candidateUrls) {
                        try {
                            val isAsr = targetUrl.endsWith("/asr")
                            val urlWithQuery = if (isAsr) {
                                if (targetUrl.contains("?")) targetUrl else "$targetUrl?encode=true&task=transcribe&word_timestamps=false&output=json"
                            } else {
                                targetUrl
                            }

                            val requestBuilder = Request.Builder()
                                .url(urlWithQuery)
                                .header("Accept", "application/json")

                            if (key.isNotBlank()) {
                                requestBuilder.addHeader("Authorization", "Bearer $key")
                            }

                            val multipart = MultipartBody.Builder()
                                .setType(MultipartBody.FORM)

                            if (isAsr) {
                                multipart.addFormDataPart(
                                    "audio_file",
                                    "probe.wav",
                                    validWavBytes.toRequestBody("audio/wav".toMediaType())
                                )
                            } else {
                                multipart.addFormDataPart("model", config.sttModel.trim().ifBlank { "whisper-1" })
                                multipart.addFormDataPart(
                                    "file",
                                    "probe.wav",
                                    validWavBytes.toRequestBody("audio/wav".toMediaType())
                                )
                            }

                            val response = okHttpClient.newCall(requestBuilder.post(multipart.build()).build()).execute()
                            val latency = System.currentTimeMillis() - startTime
                            val responseBody = response.body?.string() ?: ""

                            if (response.isSuccessful || response.code in listOf(200, 400, 422)) {
                                return@withContext Result.success("STT Verified (${latency}ms): Connected to $targetUrl")
                            } else {
                                lastError = "HTTP ${response.code} on $targetUrl: ${responseBody.take(100)}"
                            }
                        } catch (e: java.net.UnknownHostException) {
                            lastError = "Unable to resolve host for '$targetUrl'. If domain DNS is offline, use the direct IP (e.g. http://132.145.181.76:9000/asr)."
                        } catch (e: Exception) {
                            lastError = "${e.javaClass.simpleName}: ${e.message}"
                        }
                    }

                    Result.failure(Exception(lastError))
                }
                else -> {
                    Result.success("Gemini STT ready via multimodal audio ingestion.")
                }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun sanitizeUrl(raw: String): String {
        var u = raw.trim()
        if (u.isBlank()) return ""
        if (u.startsWith("http:", ignoreCase = true) && !u.startsWith("http://", ignoreCase = true)) {
            u = "http://" + u.substring(5).trimStart('/')
        } else if (u.startsWith("https:", ignoreCase = true) && !u.startsWith("https://", ignoreCase = true)) {
            u = "https://" + u.substring(6).trimStart('/')
        } else if (!u.startsWith("http://", ignoreCase = true) && !u.startsWith("https://", ignoreCase = true)) {
            u = "http://$u"
        }
        return u.trimEnd('/')
    }

    private fun createValidWavSilence(durationSeconds: Float = 0.25f, sampleRate: Int = 16000): ByteArray {
        val numChannels = 1
        val bitsPerSample = 16
        val totalSamples = (durationSeconds * sampleRate).toInt()
        val dataSize = totalSamples * numChannels * (bitsPerSample / 8)
        val totalSize = 36 + dataSize
        val byteRate = sampleRate * numChannels * (bitsPerSample / 8)
        val blockAlign = numChannels * (bitsPerSample / 8)

        val buffer = java.nio.ByteBuffer.allocate(44 + dataSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt(totalSize)
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(16)
        buffer.putShort(1.toShort())
        buffer.putShort(numChannels.toShort())
        buffer.putInt(sampleRate)
        buffer.putInt(byteRate)
        buffer.putShort(blockAlign.toShort())
        buffer.putShort(bitsPerSample.toShort())
        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(dataSize)
        for (i in 0 until totalSamples) {
            buffer.putShort(0.toShort())
        }
        return buffer.array()
    }

    companion object {
        private const val KEY_CONFIG = "key_ai_custom_config_json"

        @Volatile
        private var instance: AiConfigManager? = null

        fun getInstance(context: Context): AiConfigManager {
            return instance ?: synchronized(this) {
                instance ?: AiConfigManager(context.applicationContext).also { instance = it }
            }
        }
    }
}
