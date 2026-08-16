package com.example.data.ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import com.example.data.gemini.GeminiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream

object RealOcrParser {

    /**
     * Extracts text directly from a Bitmap (e.g. captured via Camera preview).
     */
    suspend fun extractTextFromBitmap(context: Context, bitmap: Bitmap): Result<String> = withContext(Dispatchers.IO) {
        try {
            val scaledBitmap = scaleBitmapDown(bitmap, 1600)
            val outputStream = ByteArrayOutputStream()
            scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 85, outputStream)
            val imageBytes = outputStream.toByteArray()
            val base64Image = Base64.encodeToString(imageBytes, Base64.NO_WRAP)

            val apiKey = GeminiClient.getApiKey()
            if (apiKey.isNotBlank()) {
                val prompt = "Extract and transcribe all text, handwritten notes, tables, diagrams, and bullet points from this image cleanly and verbatim. Do not hallucinate or add preamble."
                val request = com.example.data.gemini.GenerateContentRequest(
                    contents = listOf(
                        com.example.data.gemini.Content(
                            parts = listOf(
                                com.example.data.gemini.Part(text = prompt),
                                com.example.data.gemini.Part(
                                    inlineData = com.example.data.gemini.InlineData(
                                        mimeType = "image/jpeg",
                                        data = base64Image
                                    )
                                )
                            )
                        )
                    )
                )

                val response = GeminiClient.service.generateContent(GeminiClient.MODEL_FLASH, apiKey, request)
                val extractedText = response.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
                if (!extractedText.isNullOrBlank()) {
                    return@withContext Result.success(extractedText.trim())
                }
            }

            Result.failure(Exception("Could not extract text via OCR. Please verify your internet connection."))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Extracts text from an image URI (camera photo, gallery picture) or file path
     * using Gemini Multimodal Vision API or fallback on-device processing.
     */
    suspend fun extractTextFromImageUri(context: Context, uri: Uri): Result<String> = withContext(Dispatchers.IO) {
        try {
            val inputStream: InputStream? = context.contentResolver.openInputStream(uri)
            val bitmap = BitmapFactory.decodeStream(inputStream)
                ?: return@withContext Result.failure(Exception("Failed to decode image from selected file"))

            return@withContext extractTextFromBitmap(context, bitmap)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Reads text or document content from a document URI (.txt, .md, .csv, .json, .pdf, etc.).
     */
    suspend fun extractTextFromDocumentUri(context: Context, uri: Uri, fileName: String?): Result<String> = withContext(Dispatchers.IO) {
        try {
            val contentResolver = context.contentResolver
            val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"

            // Check if it's an image
            if (mimeType.startsWith("image/")) {
                return@withContext extractTextFromImageUri(context, uri)
            }

            val inputStream: InputStream = contentResolver.openInputStream(uri)
                ?: return@withContext Result.failure(Exception("Cannot open document file"))

            val bytes = inputStream.use { it.readBytes() }
            if (bytes.isEmpty()) {
                return@withContext Result.failure(Exception("Selected file is empty"))
            }

            // If it's plain text, markdown, csv, json, email, etc.
            if (mimeType.contains("text") || mimeType.contains("json") || mimeType.contains("csv") ||
                fileName?.endsWith(".txt", true) == true || fileName?.endsWith(".md", true) == true ||
                fileName?.endsWith(".eml", true) == true || fileName?.endsWith(".csv", true) == true ||
                fileName?.endsWith(".json", true) == true
            ) {
                val text = String(bytes, Charsets.UTF_8)
                return@withContext Result.success(text.trim())
            }

            // For PDF or binary documents, use Gemini Multimodal Document Analysis
            val apiKey = GeminiClient.getApiKey()
            if (apiKey.isNotBlank()) {
                val base64Data = Base64.encodeToString(bytes, Base64.NO_WRAP)
                val docMime = if (mimeType.contains("pdf") || fileName?.endsWith(".pdf", true) == true) "application/pdf" else mimeType
                
                val prompt = "Read and extract all document content, paragraphs, headers, action points, and meeting notes from this document accurately. Preserve structure and formatting."
                val request = com.example.data.gemini.GenerateContentRequest(
                    contents = listOf(
                        com.example.data.gemini.Content(
                            parts = listOf(
                                com.example.data.gemini.Part(text = prompt),
                                com.example.data.gemini.Part(
                                    inlineData = com.example.data.gemini.InlineData(
                                        mimeType = docMime,
                                        data = base64Data
                                    )
                                )
                            )
                        )
                    )
                )

                val response = GeminiClient.service.generateContent(GeminiClient.MODEL_FLASH, apiKey, request)
                val extractedText = response.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
                if (!extractedText.isNullOrBlank()) {
                    return@withContext Result.success(extractedText.trim())
                }
            }

            // Fallback plain string decode
            val fallbackText = String(bytes, Charsets.UTF_8).filter { it.isLetterOrDigit() || it.isWhitespace() || it in ".,;:!?()[]{}-_#*\"'" }
            if (fallbackText.isNotBlank()) {
                Result.success(fallbackText.trim())
            } else {
                Result.failure(Exception("Unable to parse document format"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun scaleBitmapDown(bitmap: Bitmap, maxDimension: Int): Bitmap {
        val originalWidth = bitmap.width
        val originalHeight = bitmap.height
        var resizedWidth = maxDimension
        var resizedHeight = maxDimension

        if (originalHeight > originalWidth) {
            resizedHeight = maxDimension
            resizedWidth = (resizedHeight * originalWidth.toFloat() / originalHeight.toFloat()).toInt()
        } else if (originalWidth > originalHeight) {
            resizedWidth = maxDimension
            resizedHeight = (resizedWidth * originalHeight.toFloat() / originalWidth.toFloat()).toInt()
        } else {
            resizedHeight = maxDimension
            resizedWidth = maxDimension
        }

        return if (originalWidth > maxDimension || originalHeight > maxDimension) {
            Bitmap.createScaledBitmap(bitmap, resizedWidth, resizedHeight, true)
        } else {
            bitmap
        }
    }
}
