package com.example.data.gemini

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import com.example.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import retrofit2.http.Body
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

@Serializable
data class GenerateContentRequest(
    val contents: List<Content>,
    val generationConfig: GenerationConfig? = null,
    val tools: List<JsonObject>? = null,
    val systemInstruction: Content? = null
)

@Serializable
data class Content(
    val parts: List<Part>,
    val role: String? = null
)

@Serializable
data class Part(
    val text: String? = null,
    val inlineData: InlineData? = null
)

@Serializable
data class InlineData(
    val mimeType: String,
    val data: String
)

@Serializable
data class ResponseFormat(
    val text: ResponseFormatText? = null
)

@Serializable
data class ResponseFormatText(
    val mimeType: String,
    val schema: JsonObject? = null
)

@Serializable
data class GenerationConfig(
    val responseFormat: ResponseFormat? = null,
    val temperature: Float? = null,
    val topP: Float? = null,
    val topK: Int? = null,
    val thinkingConfig: ThinkingConfig? = null,
    val imageConfig: ImageConfig? = null,
    val responseModalities: List<String>? = null,
    val speechConfig: SpeechConfig? = null
)

@Serializable
data class ThinkingConfig(
    val thinkingLevel: String
)

@Serializable
data class ImageConfig(
    val aspectRatio: String,
    val imageSize: String
)

@Serializable
data class SpeechConfig(
    val voiceConfig: VoiceConfig
)

@Serializable
data class VoiceConfig(
    val prebuiltVoiceConfig: PrebuiltVoiceConfig
)

@Serializable
data class PrebuiltVoiceConfig(
    val voiceName: String
)

@Serializable
data class GenerateContentResponse(
    val candidates: List<Candidate>? = null
)

@Serializable
data class Candidate(
    val content: Content? = null
)

interface GeminiApiService {
    @POST("v1beta/models/{model}:generateContent")
    suspend fun generateContent(
        @Path("model") model: String,
        @Query("key") apiKey: String,
        @Body request: GenerateContentRequest
    ): GenerateContentResponse
}

object GeminiClient {
    private const val BASE_URL = "https://generativelanguage.googleapis.com/"

    const val MODEL_FLASH = "gemini-3.5-flash"
    const val MODEL_FLASH_LITE = "gemini-3.1-flash-lite-preview"
    const val MODEL_PRO_PREVIEW = "gemini-3.1-pro-preview"

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    private val okHttpClient = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .addInterceptor(HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
        })
        .build()

    val service: GeminiApiService by lazy {
        Retrofit.Builder()
            .baseUrl(BASE_URL)
            .client(okHttpClient)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(GeminiApiService::class.java)
    }

    fun getApiKey(): String {
        return try {
            val key = BuildConfig.GEMINI_API_KEY
            if (key.isNotBlank() && !key.startsWith("placeholder")) key else ""
        } catch (e: Exception) {
            ""
        }
    }

    /**
     * Universal audio transcription supporting custom Whisper (whisper-asr webservice /asr, OpenAI /audio/transcriptions) and Gemini 3.5 Flash.
     */
    suspend fun transcribeAudioWithConfig(
        context: Context,
        audioBytes: ByteArray,
        mimeType: String = "audio/mp4"
    ): Result<String> = withContext(Dispatchers.IO) {
        val config = AiConfigManager.getInstance(context).configState.value

        if (config.mode == AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name) {
            var rawUrl = config.sttBaseUrl.trim()
            if (rawUrl.startsWith("http:", ignoreCase = true) && !rawUrl.startsWith("http://", ignoreCase = true)) {
                rawUrl = "http://" + rawUrl.substring(5).trimStart('/')
            } else if (rawUrl.startsWith("https:", ignoreCase = true) && !rawUrl.startsWith("https://", ignoreCase = true)) {
                rawUrl = "https://" + rawUrl.substring(6).trimStart('/')
            } else if (!rawUrl.startsWith("http://", ignoreCase = true) && !rawUrl.startsWith("https://", ignoreCase = true)) {
                rawUrl = "http://$rawUrl"
            }
            rawUrl = rawUrl.trimEnd('/')

            val apiKey = config.sttApiKey.trim().ifBlank { config.llmApiKey.trim() }
            val model = config.sttModel.trim().ifBlank { "whisper-1" }

            // Candidate URLs for whisper server:
            val candidateEndpoints = if (rawUrl.endsWith("/asr") || rawUrl.endsWith("/audio/transcriptions") || rawUrl.endsWith("/transcribe")) {
                listOf(rawUrl)
            } else {
                listOf(
                    "$rawUrl/asr",
                    if (rawUrl.endsWith("/v1")) "$rawUrl/audio/transcriptions" else "$rawUrl/v1/audio/transcriptions",
                    "$rawUrl/audio/transcriptions"
                )
            }

            for (targetUrl in candidateEndpoints) {
                try {
                    val isAsrEndpoint = targetUrl.endsWith("/asr")
                    val fullUrl = if (isAsrEndpoint) {
                        if (targetUrl.contains("?")) targetUrl else "$targetUrl?encode=true&task=transcribe&word_timestamps=false&output=json"
                    } else {
                        targetUrl
                    }

                    val multipartBuilder = MultipartBody.Builder()
                        .setType(MultipartBody.FORM)

                    if (isAsrEndpoint) {
                        // Whisper ASR webservice accepts 'audio_file'
                        multipartBuilder.addFormDataPart(
                            "audio_file",
                            "recording.mp4",
                            audioBytes.toRequestBody("audio/mp4".toMediaType())
                        )
                    } else {
                        // Standard OpenAI Whisper accepts 'file' and 'model'
                        multipartBuilder.addFormDataPart("model", model)
                        multipartBuilder.addFormDataPart(
                            "file",
                            "recording.mp4",
                            audioBytes.toRequestBody("audio/mp4".toMediaType())
                        )
                    }

                    val requestBuilder = Request.Builder()
                        .url(fullUrl)
                        .header("Accept", "application/json")
                        .post(multipartBuilder.build())

                    if (apiKey.isNotBlank()) {
                        requestBuilder.addHeader("Authorization", "Bearer $apiKey")
                    }

                    val response = okHttpClient.newCall(requestBuilder.build()).execute()
                    val body = response.body?.string() ?: ""

                    if (response.isSuccessful) {
                        var text = ""
                        if (body.contains("\"text\":")) {
                            text = body.substringAfter("\"text\":").substringAfter("\"").substringBefore("\"")
                                .replace("\\n", "\n").replace("\\\"", "\"")
                        } else {
                            text = body.trim()
                        }
                        if (text.isNotBlank()) {
                            return@withContext Result.success(text.trim())
                        }
                    }
                } catch (e: Exception) {
                    // Try next candidate endpoint or fallback
                }
            }
        }

        // Default or Custom Gemini transcription fallback
        transcribeAudio(audioBytes, mimeType)
    }

    /**
     * Universal Chat / LLM routing with support for Custom OpenAI-compatible endpoints & Gemini.
     */
    suspend fun generateChatWithConfig(
        context: Context,
        prompt: String,
        systemPrompt: String,
        isThinkingMode: Boolean = false,
        isFastMode: Boolean = false
    ): Result<Pair<String, String>> = withContext(Dispatchers.IO) {
        val config = AiConfigManager.getInstance(context).configState.value

        if (config.mode == AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name) {
            val baseUrl = config.llmBaseUrl.trim().trimEnd('/')
            val url = if (baseUrl.endsWith("/chat/completions")) baseUrl else "$baseUrl/chat/completions"
            val apiKey = config.llmApiKey.trim()
            val model = config.llmModel.trim().ifBlank { "gpt-4o" }

            try {
                val escapedPrompt = prompt.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "")
                val escapedSys = systemPrompt.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "")

                val payload = """
                    {
                        "model": "$model",
                        "messages": [
                            {"role": "system", "content": "$escapedSys"},
                            {"role": "user", "content": "$escapedPrompt"}
                        ],
                        "temperature": ${if (isThinkingMode) "0.7" else "0.3"}
                    }
                """.trimIndent()

                val requestBuilder = Request.Builder()
                    .url(url)
                    .post(payload.toRequestBody("application/json".toMediaType()))

                if (apiKey.isNotBlank()) {
                    requestBuilder.addHeader("Authorization", "Bearer $apiKey")
                }

                val response = okHttpClient.newCall(requestBuilder.build()).execute()
                val body = response.body?.string() ?: ""

                if (response.isSuccessful) {
                    val text = if (body.contains("\"content\":")) {
                        body.substringAfter("\"content\":").substringAfter("\"").substringBefore("\"")
                            .replace("\\n", "\n").replace("\\\"", "\"")
                    } else {
                        body
                    }
                    return@withContext Result.success(Pair(text.trim(), "$model (Custom LLM)"))
                } else {
                    return@withContext Result.failure(Exception("Custom LLM error HTTP ${response.code}: ${body.take(120)}"))
                }
            } catch (e: Exception) {
                return@withContext Result.failure(e)
            }
        }

        // Gemini native modes
        if (isThinkingMode) {
            val res = generateHighThinkingResponse(prompt, systemPrompt)
            res.map { Pair(it, "gemini-3.1-pro-preview (High Thinking)") }
        } else if (isFastMode) {
            val res = generateFastResponse(prompt, systemPrompt)
            res.map { Pair(it, "gemini-3.1-flash-lite") }
        } else {
            val res = generateGeneralAnalysis(prompt, systemPrompt)
            res.map { Pair(it, "gemini-3.5-flash") }
        }
    }

    /**
     * Transcribes audio using gemini-3.5-flash
     */
    suspend fun transcribeAudio(
        audioBytes: ByteArray,
        mimeType: String = "audio/mp4"
    ): Result<String> = withContext(Dispatchers.IO) {
        val apiKey = getApiKey()
        if (apiKey.isEmpty()) {
            return@withContext Result.failure(IllegalStateException("Gemini API key is not configured."))
        }

        try {
            val base64Audio = Base64.encodeToString(audioBytes, Base64.NO_WRAP)
            val request = GenerateContentRequest(
                contents = listOf(
                    Content(
                        parts = listOf(
                            Part(text = "You are a professional audio transcriber. Listen to this audio carefully and provide the verbatim and clean spoken transcription accurately. Do not add conversational intro or outro."),
                            Part(inlineData = InlineData(mimeType = mimeType, data = base64Audio))
                        )
                    )
                )
            )
            val response = service.generateContent(MODEL_FLASH, apiKey, request)
            val text = response.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
            if (!text.isNullOrBlank()) {
                Result.success(text.trim())
            } else {
                Result.failure(IllegalStateException("Empty transcription response from Gemini."))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Low-latency fast responses using gemini-3.1-flash-lite
     */
    suspend fun generateFastResponse(
        prompt: String,
        systemPrompt: String = "You are an AI Knowledge Companion. Provide rapid, concise, high-utility answers."
    ): Result<String> = withContext(Dispatchers.IO) {
        val apiKey = getApiKey()
        if (apiKey.isEmpty()) {
            return@withContext Result.failure(IllegalStateException("Gemini API key is not configured."))
        }

        try {
            val request = GenerateContentRequest(
                contents = listOf(
                    Content(parts = listOf(Part(text = prompt)))
                ),
                systemInstruction = Content(parts = listOf(Part(text = systemPrompt))),
                generationConfig = GenerationConfig(
                    temperature = 0.4f,
                    topP = 0.9f
                )
            )
            val response = service.generateContent(MODEL_FLASH_LITE, apiKey, request)
            val text = response.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
            if (!text.isNullOrBlank()) {
                Result.success(text.trim())
            } else {
                Result.failure(IllegalStateException("Empty response from Gemini Flash Lite."))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * High-Thinking deep reasoning mode using gemini-3.1-pro-preview
     * (ThinkingLevel.HIGH, no maxOutputTokens)
     */
    suspend fun generateHighThinkingResponse(
        prompt: String,
        systemPrompt: String = "You are an elite AI Knowledge Strategist. Use deep thinking and rigorous multi-stage reasoning to evaluate complex systems, cross-session architecture, decisions, and action plans."
    ): Result<String> = withContext(Dispatchers.IO) {
        val apiKey = getApiKey()
        if (apiKey.isEmpty()) {
            return@withContext Result.failure(IllegalStateException("Gemini API key is not configured."))
        }

        try {
            val request = GenerateContentRequest(
                contents = listOf(
                    Content(parts = listOf(Part(text = prompt)))
                ),
                systemInstruction = Content(parts = listOf(Part(text = systemPrompt))),
                generationConfig = GenerationConfig(
                    thinkingConfig = ThinkingConfig(thinkingLevel = "HIGH")
                )
            )
            val response = service.generateContent(MODEL_PRO_PREVIEW, apiKey, request)
            val text = response.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
            if (!text.isNullOrBlank()) {
                Result.success(text.trim())
            } else {
                Result.failure(IllegalStateException("Empty response from Gemini Pro High Thinking."))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * General task analysis using gemini-3.5-flash
     */
    suspend fun generateGeneralAnalysis(
        prompt: String,
        systemPrompt: String = "You are an AI Knowledge Engine orchestrator. Extract structured topics, decisions, action items, and entities from knowledge transcripts."
    ): Result<String> = withContext(Dispatchers.IO) {
        val apiKey = getApiKey()
        if (apiKey.isEmpty()) {
            return@withContext Result.failure(IllegalStateException("Gemini API key is not configured."))
        }

        try {
            val request = GenerateContentRequest(
                contents = listOf(
                    Content(parts = listOf(Part(text = prompt)))
                ),
                systemInstruction = Content(parts = listOf(Part(text = systemPrompt))),
                generationConfig = GenerationConfig(
                    temperature = 0.3f
                )
            )
            val response = service.generateContent(MODEL_FLASH, apiKey, request)
            val text = response.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
            if (!text.isNullOrBlank()) {
                Result.success(text.trim())
            } else {
                Result.failure(IllegalStateException("Empty response from Gemini Flash."))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
