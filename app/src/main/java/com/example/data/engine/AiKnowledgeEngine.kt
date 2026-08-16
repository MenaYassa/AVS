package com.example.data.engine

import com.example.data.model.*
import kotlinx.serialization.json.Json
import java.util.UUID

object AiKnowledgeEngine {

    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
        isLenient = true
    }

    fun cleanTranscript(raw: String): String {
        var text = raw.trim()
        val fillerRegex = Regex("(?i)\\b(um|uh|you know|like|sort of|kind of|i mean|ah)\\b[,\\s]*")
        text = text.replace(fillerRegex, " ")
        text = text.replace(Regex("\\s+"), " ").trim()
        if (text.isBlank()) return ""
        // Capitalize first letters of sentences
        return text.split(". ").joinToString(". ") { sentence ->
            if (sentence.isNotEmpty()) sentence.replaceFirstChar { it.uppercase() } else sentence
        }
    }

    fun analyze(
        rawText: String,
        persona: PromptPersona,
        audioDurationSec: Double? = null,
        audioPath: String? = null
    ): Session {
        val base = analyze(rawText, audioDurationSec, audioPath)
        val customSummary = when (persona) {
            PromptPersona.EXECUTIVE_BRIEF -> "Executive Brief: ${base.summary ?: "Key strategic highlights and decisions summarized."}"
            PromptPersona.TECH_ARCHITECTURE -> "Tech Architecture Review: System components, data flows, and technical decisions analyzed from: ${base.summary ?: ""}"
            PromptPersona.SALES_DISCOVERY -> "Sales Discovery: Client requirements, constraints, and commercial action items captured from: ${base.summary ?: ""}"
            PromptPersona.SPRINT_PLAN -> "Sprint Backlog: Prioritized task breakdowns and immediate execution milestones derived from: ${base.summary ?: ""}"
            PromptPersona.STUDY_GUIDE -> "Study Guide: Core conceptual hierarchy, key takeaways, and revision points from: ${base.summary ?: ""}"
        }
        return base.copy(
            summary = customSummary,
            tags = (base.tags + persona.label).distinct()
        )
    }

    fun analyze(
        rawText: String,
        audioDurationSec: Double? = null,
        audioPath: String? = null
    ): Session {
        val cleaned = cleanTranscript(rawText)
        val wordCount = cleaned.split(Regex("\\s+")).filter { it.isNotBlank() }.size
        val duration: Double? = if (audioPath != null || audioDurationSec != null) {
            audioDurationSec ?: (wordCount * 0.45)
        } else {
            null
        }

        // Handle empty or blank transcript
        if (cleaned.isBlank() || wordCount == 0) {
            val sessionId = "session_${UUID.randomUUID().toString().take(8)}"
            return Session(
                id = sessionId,
                userId = "user_default",
                title = if (audioPath != null) "Voice Recording (${String.format("%.1f", (duration ?: 1.0).coerceAtLeast(1.0))}s)" else "Document Note",
                alternativeTitles = emptyList(),
                summary = "No speech or text detected in this entry.",
                summaryConfidence = 0.0,
                extractionConfidence = 0.0,
                language = "en",
                status = SessionStatus.READY,
                durationSec = duration,
                wordCount = 0,
                originalTranscript = rawText.ifBlank { "No content." },
                cleanedTranscript = cleaned.ifBlank { "No content." },
                audioPath = audioPath,
                promptVersions = mapOf("cleanup" to "1.0", "extraction" to "1.0", "graph" to "1.0"),
                favorite = false,
                archived = false,
                deleted = false,
                pinned = false,
                tags = if (audioPath != null) listOf("Voice Note") else listOf("Document"),
                createdAt = System.currentTimeMillis(),
                updatedAt = System.currentTimeMillis(),
                topics = emptyList(),
                entities = emptyList(),
                relationships = emptyList()
            )
        }

        // Extract sentences
        val sentences = cleaned.split(Regex("[.?!]")).map { it.trim() }.filter { it.length > 3 }

        // Determine title from actual transcript
        val titleCandidate = when {
            sentences.isNotEmpty() && sentences[0].length in 6..70 -> sentences[0]
            cleaned.length <= 40 -> cleaned
            sentences.isNotEmpty() -> sentences[0].take(50) + "..."
            else -> "Knowledge Session: ${cleaned.take(35)}..."
        }

        val altTitles = listOf(
            "Overview: $titleCandidate",
            "Summary & Takeaways"
        )

        // Build Topics and Items strictly from user's transcript
        val topics = mutableListOf<Topic>()

        // 1. Action Items / Tasks
        val taskSentences = sentences.filter {
            it.contains("need to", true) || it.contains("must", true) || it.contains("will", true) ||
            it.contains("task", true) || it.contains("todo", true) || it.contains("should", true) ||
            it.contains("call", true) || it.contains("implement", true) || it.contains("fix", true) ||
            it.contains("do this", true) || it.contains("plan to", true)
        }

        if (taskSentences.isNotEmpty()) {
            val taskItems = taskSentences.take(5).mapIndexed { idx, s ->
                val priority = when {
                    s.contains("urgent", true) || s.contains("asap", true) || idx == 0 -> Priority.HIGH
                    s.contains("maybe", true) || s.contains("later", true) -> Priority.LOW
                    else -> Priority.MEDIUM
                }
                Item(
                    id = "item_${UUID.randomUUID().toString().take(8)}",
                    type = ItemType.ACTION_ITEM,
                    title = s.replaceFirstChar { it.uppercase() },
                    description = "Extracted from spoken statement",
                    position = idx,
                    priority = priority,
                    confidence = (0.92 - (idx * 0.03)).coerceAtLeast(0.7),
                    completed = false
                )
            }
            topics.add(
                Topic(
                    id = "topic_${UUID.randomUUID().toString().take(8)}",
                    title = "Key Action Items & Deliverables",
                    position = topics.size,
                    description = "Tasks and commitments identified in the session.",
                    confidence = 0.94,
                    items = taskItems
                )
            )
        }

        // 2. Core Decisions & Architectural Insights
        val decisionSentences = sentences.filter {
            it.contains("decide", true) || it.contains("agree", true) || it.contains("choose", true) ||
            it.contains("conclude", true) || it.contains("resolve", true) || it.contains("selected", true) ||
            it.contains("we decided", true) || it.contains("we chose", true)
        }

        if (decisionSentences.isNotEmpty()) {
            val decisionItems = decisionSentences.take(4).mapIndexed { idx, s ->
                Item(
                    id = "item_${UUID.randomUUID().toString().take(8)}",
                    type = ItemType.DECISION,
                    title = s.replaceFirstChar { it.uppercase() },
                    description = "Spoken consensus decision",
                    position = idx,
                    confidence = 0.90
                )
            }
            topics.add(
                Topic(
                    id = "topic_${UUID.randomUUID().toString().take(8)}",
                    title = "Decisions & Agreements",
                    position = topics.size,
                    description = "Choices and agreed directions from the session.",
                    confidence = 0.91,
                    items = decisionItems
                )
            )
        }

        // 3. Open Questions & Inquiries
        val questionSentences = sentences.filter {
            it.contains("?", true) || it.contains("how", true) || it.contains("what", true) ||
            it.contains("why", true) || it.contains("wonder", true) || it.contains("risk", true)
        }

        if (questionSentences.isNotEmpty()) {
            val questionItems = questionSentences.take(3).mapIndexed { idx, s ->
                Item(
                    id = "item_${UUID.randomUUID().toString().take(8)}",
                    type = if (s.contains("risk", true)) ItemType.RISK else ItemType.QUESTION,
                    title = s.replaceFirstChar { it.uppercase() },
                    description = "Open thread or inquiry",
                    position = idx,
                    confidence = 0.88
                )
            }
            topics.add(
                Topic(
                    id = "topic_${UUID.randomUUID().toString().take(8)}",
                    title = "Questions & Explorations",
                    position = topics.size,
                    description = "Unresolved queries flagged in the session.",
                    confidence = 0.88,
                    items = questionItems
                )
            )
        }

        // 4. Main Discussion Points if no explicit tasks/decisions
        if (topics.isEmpty() && sentences.isNotEmpty()) {
            val generalItems = sentences.take(4).mapIndexed { idx, s ->
                Item(
                    id = "item_${UUID.randomUUID().toString().take(8)}",
                    type = ItemType.IDEA,
                    title = s.replaceFirstChar { it.uppercase() },
                    description = "Key point from transcript",
                    position = idx,
                    confidence = 0.85
                )
            }
            topics.add(
                Topic(
                    id = "topic_${UUID.randomUUID().toString().take(8)}",
                    title = "Key Takeaways & Points",
                    position = 0,
                    description = "Key discussion points summarized from speech.",
                    confidence = 0.88,
                    items = generalItems
                )
            )
        }

        // Knowledge Graph extraction strictly from actual transcript text
        val entities = mutableListOf<GraphEntity>()
        val relations = mutableListOf<GraphRelation>()

        val rawWords = cleaned.split(Regex("[^a-zA-Z0-9_-]+")).filter { it.length > 2 }
        val commonStopWords = setOf("The", "This", "That", "When", "There", "And", "For", "With", "Maybe", "What", "Here", "Some", "Then", "Also", "Just", "Like", "Your", "Have", "Been", "From", "Will", "Need", "Should", "Would", "Could")
        val properNouns = rawWords.filter { it.first().isUpperCase() && !commonStopWords.contains(it) }.distinct()

        if (properNouns.isNotEmpty()) {
            properNouns.take(6).forEachIndexed { idx, name ->
                val type = when {
                    listOf("Ahmed", "Alex", "Sarah", "Elena", "Mena", "David", "John", "Michael", "Emma").contains(name) -> EntityType.PERSON
                    listOf("FastAPI", "Flutter", "Android", "Room", "Docker", "Redis", "Supabase", "Compose", "Kotlin", "Python", "Whisper", "Gemini", "GPT").contains(name) -> EntityType.TOOL
                    listOf("Google", "DeepMind", "Notion", "Slack", "OpenAI", "Microsoft", "Apple").contains(name) -> EntityType.ORGANIZATION
                    name.endsWith("Platform") || name.endsWith("App") || name.endsWith("Engine") || name.endsWith("System") -> EntityType.PROJECT
                    else -> EntityType.CONCEPT
                }
                entities.add(
                    GraphEntity(
                        id = "entity_${name.lowercase()}",
                        userId = "user_default",
                        type = type,
                        name = name,
                        canonicalName = name,
                        aliases = listOf(name.lowercase()),
                        confidence = (0.95 - (idx * 0.02)).coerceAtLeast(0.7)
                    )
                )
            }

            // Build relationships between detected entities
            if (entities.size >= 2) {
                for (i in 0 until (entities.size - 1)) {
                    val src = entities[i]
                    val tgt = entities[i + 1]
                    val relationType = when {
                        src.type == EntityType.PERSON && tgt.type == EntityType.PROJECT -> RelationType.LEADS
                        src.type == EntityType.PERSON && tgt.type == EntityType.TASK -> RelationType.ASSIGNED_TO
                        src.type == EntityType.PROJECT && tgt.type == EntityType.TOOL -> RelationType.DEPENDS_ON
                        else -> RelationType.DISCUSSES
                    }
                    relations.add(
                        GraphRelation(
                            id = "rel_${UUID.randomUUID().toString().take(8)}",
                            userId = "user_default",
                            sourceId = src.id,
                            targetId = tgt.id,
                            type = relationType,
                            weight = 1.0,
                            confidence = 0.90
                        )
                    )
                }
            }
        }

        // Tags based on actual words in text
        val tags = mutableListOf<String>()
        val lowerText = cleaned.lowercase()
        if (lowerText.contains("benchmark")) tags.add("Benchmark")
        if (lowerText.contains("architecture")) tags.add("Architecture")
        if (lowerText.contains("meeting")) tags.add("Meeting")
        if (lowerText.contains("plan") || lowerText.contains("roadmap")) tags.add("Roadmap")
        if (lowerText.contains("task") || lowerText.contains("todo")) tags.add("Action Items")
        if (lowerText.contains("design")) tags.add("Design")
        if (lowerText.contains("bug") || lowerText.contains("fix")) tags.add("Engineering")
        if (tags.isEmpty()) {
            tags.add(if (audioPath != null) "Voice Note" else "Document Note")
        }

        // Summary based directly on content
        val summary = if (sentences.size == 1) {
            sentences[0]
        } else if (sentences.size > 1) {
            sentences.take(3).joinToString(". ") + "."
        } else {
            cleaned
        }

        val sessionId = "session_${UUID.randomUUID().toString().take(8)}"

        return Session(
            id = sessionId,
            userId = "user_default",
            title = titleCandidate,
            alternativeTitles = altTitles,
            summary = summary,
            summaryConfidence = 0.92,
            extractionConfidence = 0.90,
            language = "en",
            status = SessionStatus.READY,
            durationSec = duration,
            wordCount = wordCount,
            originalTranscript = rawText,
            cleanedTranscript = cleaned,
            audioPath = audioPath,
            promptVersions = mapOf("cleanup" to "1.0", "extraction" to "1.0", "graph" to "1.0"),
            favorite = false,
            archived = false,
            deleted = false,
            pinned = false,
            tags = tags.distinct(),
            createdAt = System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis(),
            topics = topics,
            entities = entities,
            relationships = relations
        )
    }

    fun executeCommand(commandName: String, session: Session): CommandDraft {
        val title = session.title ?: "Session Knowledge"
        val summary = session.summary ?: ""
        val tasks = session.topics.flatMap { it.items }.filter { it.type == ItemType.ACTION_ITEM || it.type == ItemType.TASK }
        val decisions = session.topics.flatMap { it.items }.filter { it.type == ItemType.DECISION }

        val (draftTitle, draftBody, items) = when (commandName) {
            "meeting_minutes" -> {
                val body = buildString {
                    appendLine("# Meeting Minutes: $title")
                    appendLine()
                    appendLine("**Date:** ${java.text.SimpleDateFormat("MMMM dd, yyyy").format(java.util.Date(session.createdAt))}")
                    appendLine("**Participants:** ${session.entities.filter { it.type == EntityType.PERSON }.map { it.name }.ifEmpty { listOf("Project Team") }.joinToString(", ")}")
                    appendLine()
                    appendLine("## Executive Summary")
                    appendLine(summary)
                    appendLine()
                    appendLine("## Decisions Made")
                    if (decisions.isNotEmpty()) {
                        decisions.forEach { appendLine("- ${it.title}") }
                    } else {
                        appendLine("- No formal decisions recorded.")
                    }
                    appendLine()
                    appendLine("## Action Items")
                    if (tasks.isNotEmpty()) {
                        tasks.forEach { appendLine("- [ ] ${it.title} (${it.priority?.label ?: "Medium"} Priority)") }
                    } else {
                        appendLine("- [ ] Follow up on session takeaways.")
                    }
                }
                Triple("Meeting Minutes — $title", body, tasks.map { DraftItem(it.title, it.description, it.type, it.priority, 0.95) })
            }
            "action_plan" -> {
                val body = buildString {
                    appendLine("# Strategic Action Plan: $title")
                    appendLine()
                    appendLine("## Summary & Context")
                    appendLine(summary)
                    appendLine()
                    appendLine("## Action Items")
                    if (tasks.isNotEmpty()) {
                        tasks.forEachIndexed { i, t -> appendLine("${i + 1}. **${t.title}** — Priority: ${t.priority?.label ?: "Medium"}") }
                    } else {
                        appendLine("1. Review session takeaways and define next milestones.")
                    }
                }
                Triple("Action Plan — $title", body, tasks.map { DraftItem(it.title, it.description, it.type, it.priority, 0.92) })
            }
            "executive_summary" -> {
                val body = buildString {
                    appendLine("# Executive Briefing: $title")
                    appendLine()
                    appendLine("**Context & Rationale:**")
                    appendLine(summary)
                    appendLine()
                    if (decisions.isNotEmpty()) {
                        appendLine("**Decisions & Directives:**")
                        decisions.forEach { appendLine("- ${it.title}") }
                        appendLine()
                    }
                    if (tasks.isNotEmpty()) {
                        appendLine("**Next Deliverables:**")
                        tasks.forEach { appendLine("- ${it.title}") }
                    }
                }
                Triple("Executive Summary — $title", body, emptyList())
            }
            "email_draft" -> {
                val body = buildString {
                    appendLine("Subject: Recap: $title")
                    appendLine()
                    appendLine("Hi Team,")
                    appendLine()
                    appendLine("Here is a quick recap of our session regarding $title:")
                    appendLine()
                    appendLine(summary)
                    appendLine()
                    if (tasks.isNotEmpty()) {
                        appendLine("Action Items:")
                        tasks.forEach { appendLine("• ${it.title} (${it.priority?.label ?: "Standard"})") }
                        appendLine()
                    }
                    appendLine("Best regards,")
                }
                Triple("Email Draft — $title", body, tasks.map { DraftItem(it.title, it.description, it.type, it.priority, 0.90) })
            }
            "presentation_outline" -> {
                val body = buildString {
                    appendLine("# Presentation Outline: $title")
                    appendLine()
                    appendLine("## Slide 1: Overview")
                    appendLine("- $title")
                    appendLine()
                    appendLine("## Slide 2: Context")
                    appendLine("- $summary")
                    appendLine()
                    appendLine("## Slide 3: Action Items & Next Steps")
                    if (tasks.isNotEmpty()) {
                        tasks.forEach { appendLine("- ${it.title}") }
                    } else {
                        appendLine("- Review takeaways and next steps")
                    }
                }
                Triple("Presentation Outline — $title", body, emptyList())
            }
            "blog_post" -> {
                val body = buildString {
                    appendLine("# Exploring $title")
                    appendLine()
                    appendLine(summary)
                    appendLine()
                    if (decisions.isNotEmpty()) {
                        appendLine("## Key Insights")
                        decisions.forEach { appendLine("### ${it.title}") }
                    }
                }
                Triple("Blog Post — $title", body, emptyList())
            }
            "rewrite_professional" -> {
                val body = "Formal Summary: $summary\n\nDeliverables:\n" + tasks.joinToString("\n") { "• ${it.title}" }
                Triple("Professional Synthesis — $title", body, emptyList())
            }
            "shorten_summary" -> {
                val body = "TL;DR: $summary"
                Triple("TL;DR Summary — $title", body, emptyList())
            }
            else -> {
                val body = "Draft Notes:\n\n$summary"
                Triple("Draft — $title", body, emptyList())
            }
        }

        return CommandDraft(
            id = "draft_${UUID.randomUUID().toString().take(8)}",
            sessionId = session.id,
            command = commandName,
            title = draftTitle,
            body = draftBody,
            items = items,
            promptVersions = mapOf("command" to commandName, "version" to "1.0"),
            createdAt = System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis()
        )
    }

    fun answerChat(
        session: Session,
        query: String,
        history: List<ChatMessage>
    ): ChatMessage {
        val lower = query.lowercase()
        val allItems = session.topics.flatMap { it.items }
        val citations = mutableListOf<String>()

        val answer = when {
            lower.contains("task") || lower.contains("todo") || lower.contains("action") -> {
                val tasks = allItems.filter { it.type == ItemType.ACTION_ITEM || it.type == ItemType.TASK }
                citations.add("[topic: Action Items]")
                if (tasks.isNotEmpty()) {
                    "Action items in this session:\n" +
                            tasks.joinToString("\n") { "• ${it.title} [Priority: ${it.priority?.label ?: "Medium"}]" }
                } else {
                    "No explicit action items were found in this session."
                }
            }
            lower.contains("decision") || lower.contains("decide") || lower.contains("agree") -> {
                val decisions = allItems.filter { it.type == ItemType.DECISION }
                citations.add("[topic: Decisions]")
                if (decisions.isNotEmpty()) {
                    "The key decisions recorded are:\n" +
                            decisions.joinToString("\n") { "• ${it.title}" }
                } else {
                    "No explicit decisions were recorded in this session."
                }
            }
            lower.contains("who") || lower.contains("person") || lower.contains("people") -> {
                val people = session.entities.filter { it.type == EntityType.PERSON }
                citations.add("[graph: Entities]")
                if (people.isNotEmpty()) {
                    "People mentioned in this session: " + people.joinToString(", ") { it.name }
                } else {
                    "No specific individuals were mentioned in this session."
                }
            }
            lower.contains("summary") || lower.contains("about") || lower.contains("what") -> {
                citations.add("[summary]")
                citations.add("[transcript]")
                session.summary ?: "This session covers ${session.title}."
            }
            else -> {
                citations.add("[summary]")
                citations.add("[transcript]")
                "Based on session '${session.title}':\n${session.summary ?: "No details available."}"
            }
        }

        return ChatMessage(
            id = "chat_${UUID.randomUUID().toString().take(8)}",
            sessionId = session.id,
            role = ChatRole.ASSISTANT,
            content = answer,
            citations = citations,
            confidence = 0.94,
            promptVersions = mapOf("chat" to "2.0"),
            createdAt = System.currentTimeMillis()
        )
    }

    fun generateInsights(sessions: List<Session>): List<Insight> {
        if (sessions.isEmpty()) return emptyList()

        val insights = mutableListOf<Insight>()

        // 1. Cross-session Projects clustering
        val entityMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
        sessions.forEach { s ->
            s.entities.forEach { e ->
                val list = entityMap.getOrPut(e.name) { mutableListOf() }
                if (list.none { it.first == s.id }) {
                    list.add(Pair(s.id, s.title ?: "Untitled Session"))
                }
            }
        }

        entityMap.filter { it.value.size >= 2 }.forEach { (name, sessionList) ->
            val sources = sessionList.map { InsightSource(it.first, it.second, "Mentioned in session knowledge graph") }
            insights.add(
                Insight(
                    kind = InsightKind.PROJECT,
                    label = name,
                    sessionCount = sessionList.size,
                    mentionCount = sessionList.size * 2,
                    confidence = 0.95,
                    statement = "You've discussed '$name' across ${sessionList.size} separate sessions.",
                    sources = sources
                )
            )
        }

        // 2. Open Tasks across sessions
        val openTasks = sessions.flatMap { s ->
            s.topics.flatMap { t -> t.items }.filter { !it.completed && (it.type == ItemType.ACTION_ITEM || it.type == ItemType.TASK) }.map {
                Pair(it, s)
            }
        }

        if (openTasks.isNotEmpty()) {
            val highPriority = openTasks.filter { it.first.priority == Priority.HIGH }
            val sources = openTasks.take(4).map { InsightSource(it.second.id, it.second.title ?: "Session", it.first.title) }
            insights.add(
                Insight(
                    kind = InsightKind.TASK,
                    label = "${openTasks.size} Open Action Items",
                    sessionCount = openTasks.map { it.second.id }.distinct().size,
                    mentionCount = openTasks.size,
                    confidence = 0.92,
                    statement = "You have ${openTasks.size} pending action items across ${sources.size} sessions (${highPriority.size} marked High Priority).",
                    sources = sources
                )
            )
        }

        // 3. Shared Tags
        val tagMap = mutableMapOf<String, MutableList<Pair<String, String>>>()
        sessions.forEach { s ->
            s.tags.forEach { tag ->
                val list = tagMap.getOrPut(tag) { mutableListOf() }
                if (list.none { it.first == s.id }) {
                    list.add(Pair(s.id, s.title ?: "Session"))
                }
            }
        }

        tagMap.filter { it.value.size >= 2 }.forEach { (tag, sessionList) ->
            val sources = sessionList.map { InsightSource(it.first, it.second, "Tagged with #$tag") }
            insights.add(
                Insight(
                    kind = InsightKind.TAG,
                    label = "#$tag",
                    sessionCount = sessionList.size,
                    mentionCount = sessionList.size,
                    confidence = 0.89,
                    statement = "Topic '#$tag' recurs across ${sessionList.size} knowledge sessions.",
                    sources = sources
                )
            )
        }

        // 4. Repeated Decisions
        val allDecisions = sessions.flatMap { s ->
            s.topics.flatMap { t -> t.items }.filter { it.type == ItemType.DECISION }.map { Pair(it, s) }
        }
        if (allDecisions.size >= 2) {
            insights.add(
                Insight(
                    kind = InsightKind.DECISION,
                    label = "Decisions & Directives",
                    sessionCount = allDecisions.map { it.second.id }.distinct().size,
                    mentionCount = allDecisions.size,
                    confidence = 0.94,
                    statement = "Synthesized ${allDecisions.size} explicit decisions across your sessions.",
                    sources = allDecisions.take(4).map { InsightSource(it.second.id, it.second.title ?: "Session", it.first.title) }
                )
            )
        }

        return insights
    }

    fun answerGlobalRagQuery(
        sessions: List<Session>,
        query: String
    ): Pair<String, List<String>> {
        val lowerQuery = query.lowercase().trim()
        val citations = mutableListOf<String>()

        if (sessions.isEmpty()) {
            return Pair("You don't have any knowledge sessions recorded yet. Start by recording a voice thought or importing a document!", emptyList())
        }

        // Match sessions relevant to query
        val matchedSessions = sessions.filter { s ->
            val inTitle = s.title?.contains(lowerQuery, true) == true
            val inSummary = s.summary?.contains(lowerQuery, true) == true
            val inTranscript = s.cleanedTranscript?.contains(lowerQuery, true) == true
            val inEntities = s.entities.any { it.name.contains(lowerQuery, true) }
            val inTopics = s.topics.any { t ->
                t.title.contains(lowerQuery, true) || t.items.any { it.title.contains(lowerQuery, true) }
            }
            inTitle || inSummary || inTranscript || inEntities || inTopics
        }

        val targetSessions = if (matchedSessions.isNotEmpty()) matchedSessions else sessions.take(4)
        targetSessions.forEach {
            citations.add("[Session: ${it.title ?: "Untitled"}]")
        }

        val allTasks = targetSessions.flatMap { s -> s.topics.flatMap { it.items }.filter { it.type == ItemType.TASK || it.type == ItemType.ACTION_ITEM } }
        val allDecisions = targetSessions.flatMap { s -> s.topics.flatMap { it.items }.filter { it.type == ItemType.DECISION } }
        val allEntities = targetSessions.flatMap { it.entities }.distinctBy { it.name }

        val answer = buildString {
            appendLine("### Synthesized Knowledge Answer")
            appendLine()
            if (matchedSessions.isNotEmpty()) {
                appendLine("Found **${matchedSessions.size} relevant session(s)** in your knowledge base matching \"$query\":")
                appendLine()
                matchedSessions.forEach { s ->
                    appendLine("• **${s.title}**: ${s.summary?.take(180)}...")
                }
                appendLine()
            } else {
                appendLine("Here is a cross-session synthesis across your latest sessions:")
                appendLine()
            }

            if (lowerQuery.contains("task") || lowerQuery.contains("action") || lowerQuery.contains("todo") || lowerQuery.contains("pending")) {
                appendLine("#### Identified Action Items Across Sessions:")
                if (allTasks.isNotEmpty()) {
                    allTasks.take(6).forEach {
                        appendLine("- [${if (it.completed) "x" else " "}] **${it.title}** (${it.priority?.label ?: "Medium"} Priority)")
                    }
                } else {
                    appendLine("No uncompleted action items found in the matched sessions.")
                }
                appendLine()
            }

            if (lowerQuery.contains("decision") || lowerQuery.contains("decide") || lowerQuery.contains("agree")) {
                appendLine("#### Cross-Session Decisions:")
                if (allDecisions.isNotEmpty()) {
                    allDecisions.take(5).forEach {
                        appendLine("- **${it.title}**")
                    }
                } else {
                    appendLine("No explicit decisions found for this query.")
                }
                appendLine()
            }

            if (lowerQuery.contains("who") || lowerQuery.contains("person") || lowerQuery.contains("people") || lowerQuery.contains("team")) {
                val people = allEntities.filter { it.type == EntityType.PERSON }
                appendLine("#### Collaborators & People Mentioned:")
                if (people.isNotEmpty()) {
                    appendLine(people.joinToString(", ") { "**${it.name}**" })
                } else {
                    appendLine("No specific individuals identified in these sessions.")
                }
                appendLine()
            }

            appendLine("#### Direct Synthesis:")
            val combinedSummary = targetSessions.mapNotNull { it.summary }.joinToString(" ")
            appendLine(if (combinedSummary.isNotBlank()) combinedSummary else "Sessions cover topics: ${allEntities.take(5).joinToString { it.name }}")
        }

        return Pair(answer.trim(), citations)
    }

    fun generateExecutiveWeeklyBrief(sessions: List<Session>): String {
        if (sessions.isEmpty()) {
            return "# Weekly Knowledge Brief\n\nNo sessions recorded in this time window."
        }

        val totalWords = sessions.sumOf { it.wordCount ?: 0 }
        val totalDuration = sessions.mapNotNull { it.durationSec }.sum()
        val allTasks = sessions.flatMap { s -> s.topics.flatMap { it.items }.filter { it.type == ItemType.TASK || it.type == ItemType.ACTION_ITEM } }
        val pendingTasks = allTasks.filter { !it.completed }
        val completedTasks = allTasks.filter { it.completed }
        val allDecisions = sessions.flatMap { s -> s.topics.flatMap { it.items }.filter { it.type == ItemType.DECISION } }
        val allEntities = sessions.flatMap { it.entities }.distinctBy { it.name }
        val people = allEntities.filter { it.type == EntityType.PERSON }
        val projects = allEntities.filter { it.type == EntityType.PROJECT || it.type == EntityType.TOOL }

        return buildString {
            appendLine("# Executive Cross-Session Knowledge Brief")
            appendLine()
            appendLine("**Generated:** ${java.text.SimpleDateFormat("MMMM dd, yyyy - HH:mm").format(java.util.Date())}")
            appendLine("**Scope:** ${sessions.size} Knowledge Sessions • $totalWords total words • ${String.format("%.1f", totalDuration / 60)} audio mins")
            appendLine()
            appendLine("---")
            appendLine("## 1. High-Level Executive Summary")
            sessions.take(4).forEach { s ->
                appendLine("• **${s.title}**: ${s.summary}")
            }
            appendLine()
            appendLine("---")
            appendLine("## 2. Core Decisions & Strategic Directives")
            if (allDecisions.isNotEmpty()) {
                allDecisions.forEachIndexed { i, d ->
                    appendLine("${i + 1}. **${d.title}**")
                }
            } else {
                appendLine("- No formal cross-session decisions logged.")
            }
            appendLine()
            appendLine("---")
            appendLine("## 3. Action Items & Deliverable Backlog")
            appendLine("**Pending (${pendingTasks.size}):**")
            if (pendingTasks.isNotEmpty()) {
                pendingTasks.forEach {
                    appendLine("- [ ] **${it.title}** [Priority: ${it.priority?.label ?: "Medium"}]")
                }
            } else {
                appendLine("- No pending tasks!")
            }
            if (completedTasks.isNotEmpty()) {
                appendLine()
                appendLine("**Completed (${completedTasks.size}):**")
                completedTasks.forEach {
                    appendLine("- [x] ~~${it.title}~~")
                }
            }
            appendLine()
            appendLine("---")
            appendLine("## 4. Key Entities & Collaboration Graph")
            appendLine("• **Collaborators:** ${people.map { it.name }.ifEmpty { listOf("Project Team") }.joinToString(", ")}")
            appendLine("• **Projects & Tools:** ${projects.map { it.name }.ifEmpty { listOf("Core Engine") }.joinToString(", ")}")
        }
    }

    fun detectConflictsAndContradictions(sessions: List<Session>): List<ConflictInsight> {
        val conflicts = mutableListOf<ConflictInsight>()
        if (sessions.size < 2) return conflicts

        // Check for cross-session task or architectural contradictions
        val decisionsBySession = sessions.mapNotNull { s ->
            val decs = s.topics.flatMap { it.items }.filter { it.type == ItemType.DECISION }
            if (decs.isNotEmpty()) Pair(s, decs) else null
        }

        if (decisionsBySession.size >= 2) {
            for (i in 0 until (decisionsBySession.size - 1)) {
                val (sessA, decsA) = decisionsBySession[i]
                val (sessB, decsB) = decisionsBySession[i + 1]

                conflicts.add(
                    ConflictInsight(
                        id = "conflict_${UUID.randomUUID().toString().take(6)}",
                        topic = "Evolving Architectural Decisions",
                        description = "In '${sessA.title}', \"${decsA.first().title}\" was decided. In '${sessB.title}', \"${decsB.first().title}\" was subsequently discussed.",
                        sessionAId = sessA.id,
                        sessionATitle = sessA.title ?: "Session A",
                        sessionBId = sessB.id,
                        sessionBTitle = sessB.title ?: "Session B",
                        resolutionSuggestion = "Review both sessions and verify if '${sessB.title}' supercedes '${sessA.title}'."
                    )
                )
                break
            }
        }

        return conflicts
    }

    fun generateDiarizedTranscriptSegments(rawText: String, durationSec: Double?): List<TranscriptSegment> {
        val cleaned = cleanTranscript(rawText)
        val sentences = cleaned.split(Regex("[.?!]")).map { it.trim() }.filter { it.isNotEmpty() }
        if (sentences.isEmpty()) return emptyList()

        val totalDuration = durationSec ?: (sentences.size * 3.5)
        val secPerSentence = totalDuration / sentences.size.coerceAtLeast(1)

        val speakers = listOf("Speaker 1", "Speaker 2", "Speaker 1")
        return sentences.mapIndexed { idx, s ->
            val speaker = speakers[idx % speakers.size]
            val start = idx * secPerSentence
            val end = (idx + 1) * secPerSentence
            TranscriptSegment(
                speaker = speaker,
                text = s.replaceFirstChar { it.uppercase() } + ".",
                startSec = start,
                endSec = end
            )
        }
    }

    fun analyzeMultiDocumentBatch(documents: List<Pair<String, String>>): Session {
        val combinedText = documents.joinToString("\n\n") { (docName, content) ->
            "=== Document: $docName ===\n$content"
        }
        val session = analyze(combinedText, null, null)
        val allTags = (session.tags + listOf("Multi-Document Batch", "Document Scan")).distinct()
        return session.copy(
            title = "Multi-Doc Synthesis (${documents.size} files)",
            tags = allTags
        )
    }

    fun formatSessionForExport(session: Session, format: ExportFormat): String {
        val title = session.title ?: "Knowledge Session"
        val dateStr = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm").format(java.util.Date(session.createdAt))
        val tasks = session.topics.flatMap { it.items }.filter { it.type == ItemType.TASK || it.type == ItemType.ACTION_ITEM }
        val decisions = session.topics.flatMap { it.items }.filter { it.type == ItemType.DECISION }

        return when (format) {
            ExportFormat.OBSIDIAN_MARKDOWN -> buildString {
                appendLine("---")
                appendLine("title: \"$title\"")
                appendLine("date: $dateStr")
                appendLine("tags: [${session.tags.joinToString { "\"$it\"" }}]")
                appendLine("confidence: ${session.summaryConfidence ?: 0.9}")
                appendLine("---")
                appendLine()
                appendLine("# $title")
                appendLine()
                appendLine("## Summary")
                appendLine(session.summary ?: "No summary recorded.")
                appendLine()
                if (decisions.isNotEmpty()) {
                    appendLine("## Decisions")
                    decisions.forEach { appendLine("- ${it.title}") }
                    appendLine()
                }
                if (tasks.isNotEmpty()) {
                    appendLine("## Action Items")
                    tasks.forEach { appendLine("- [${if (it.completed) "x" else " "}] ${it.title} [Priority:: ${it.priority?.label ?: "Medium"}]") }
                    appendLine()
                }
                if (session.entities.isNotEmpty()) {
                    appendLine("## Knowledge Graph & Backlinks")
                    session.entities.forEach { e ->
                        appendLine("- [[${e.name}]] (${e.type.label})")
                    }
                    appendLine()
                }
                appendLine("## Transcript")
                appendLine(session.cleanedTranscript ?: "No transcript.")
            }

            ExportFormat.HTML_REPORT -> buildString {
                appendLine("<!DOCTYPE html>")
                appendLine("<html lang=\"en\">")
                appendLine("<head>")
                appendLine("  <meta charset=\"UTF-8\">")
                appendLine("  <title>$title</title>")
                appendLine("  <style>")
                appendLine("    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; padding: 32px; line-height: 1.6; }")
                appendLine("    .container { max-width: 800px; margin: 0 auto; background: #1e293b; padding: 32px; border-radius: 16px; border: 1px solid #334155; }")
                appendLine("    h1 { color: #818cf8; margin-top: 0; }")
                appendLine("    h2 { color: #38bdf8; border-bottom: 1px solid #334155; padding-bottom: 8px; margin-top: 24px; }")
                appendLine("    .badge { display: inline-block; background: #4338ca; color: white; padding: 4px 10px; border-radius: 12px; font-size: 12px; margin-right: 6px; }")
                appendLine("    .task { background: #0f172a; padding: 10px; border-radius: 8px; margin-bottom: 8px; border-left: 4px solid #f59e0b; }")
                appendLine("  </style>")
                appendLine("</head>")
                appendLine("<body>")
                appendLine("  <div class=\"container\">")
                appendLine("    <h1>$title</h1>")
                appendLine("    <p><em>$dateStr • ${(session.wordCount ?: 0)} words</em></p>")
                appendLine("    <div>${session.tags.joinToString(" ") { "<span class=\"badge\">#$it</span>" }}</div>")
                appendLine("    <h2>Executive Summary</h2>")
                appendLine("    <p>${session.summary ?: ""}</p>")
                if (decisions.isNotEmpty()) {
                    appendLine("    <h2>Decisions Made</h2>")
                    appendLine("    <ul>${decisions.joinToString("") { "<li><strong>${it.title}</strong></li>" }}</ul>")
                }
                if (tasks.isNotEmpty()) {
                    appendLine("    <h2>Action Items</h2>")
                    tasks.forEach { t ->
                        appendLine("    <div class=\"task\">${if (t.completed) "☑" else "☐"} ${t.title} (Priority: ${t.priority?.label ?: "Medium"})</div>")
                    }
                }
                appendLine("  </div>")
                appendLine("</body>")
                appendLine("</html>")
            }

            ExportFormat.NOTION_BLOCKS -> buildString {
                appendLine("{")
                appendLine("  \"parent\": { \"database_id\": \"notion_db_knowledge\" },")
                appendLine("  \"properties\": {")
                appendLine("    \"Title\": { \"title\": [{ \"text\": { \"content\": \"$title\" } }] },")
                appendLine("    \"Date\": { \"date\": { \"start\": \"$dateStr\" } },")
                appendLine("    \"Tags\": { \"multi_select\": [${session.tags.joinToString { "{\"name\": \"$it\"}" }}] }")
                appendLine("  },")
                appendLine("  \"children\": [")
                appendLine("    { \"object\": \"block\", \"type\": \"heading_1\", \"heading_1\": { \"rich_text\": [{ \"text\": { \"content\": \"Executive Summary\" } }] } },")
                appendLine("    { \"object\": \"block\", \"type\": \"paragraph\", \"paragraph\": { \"rich_text\": [{ \"text\": { \"content\": \"${session.summary ?: ""}\" } }] } }")
                appendLine("  ]")
                appendLine("}")
            }

            ExportFormat.JSON_SCHEMA -> {
                json.encodeToString(com.example.data.model.Session.serializer(), session)
            }

            ExportFormat.GOOGLE_TASKS -> buildString {
                appendLine("=== Action Items for Google Tasks / Reminders ===")
                appendLine("List: $title")
                appendLine()
                if (tasks.isNotEmpty()) {
                    tasks.forEachIndexed { i, t ->
                        appendLine("${i + 1}. [ ] ${t.title}")
                        appendLine("   Priority: ${t.priority?.label ?: "Medium"}")
                        appendLine("   Notes: Extracted from session '$title'")
                    }
                } else {
                    appendLine("No open action items in this session.")
                }
            }
        }
    }
}

