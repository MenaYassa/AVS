package com.example.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

enum class SessionStatus {
    @SerialName("recording") RECORDING,
    @SerialName("uploading") UPLOADING,
    @SerialName("transcribing") TRANSCRIBING,
    @SerialName("cleaning") CLEANING,
    @SerialName("analyzing") ANALYZING,
    @SerialName("validating") VALIDATING,
    @SerialName("ready") READY,
    @SerialName("edited") EDITED,
    @SerialName("synced") SYNCED,
    @SerialName("failed") FAILED,
    @SerialName("cancelled") CANCELLED;

    val isProcessing: Boolean
        get() = this in listOf(UPLOADING, TRANSCRIBING, CLEANING, ANALYZING, VALIDATING)

    val isTerminal: Boolean
        get() = this == FAILED || this == CANCELLED
}

enum class ItemType(val label: String) {
    @SerialName("idea") IDEA("Idea"),
    @SerialName("task") TASK("Task"),
    @SerialName("decision") DECISION("Decision"),
    @SerialName("question") QUESTION("Question"),
    @SerialName("problem") PROBLEM("Problem"),
    @SerialName("risk") RISK("Risk"),
    @SerialName("goal") GOAL("Goal"),
    @SerialName("event") EVENT("Event"),
    @SerialName("reminder") REMINDER("Reminder"),
    @SerialName("reference") REFERENCE("Reference"),
    @SerialName("observation") OBSERVATION("Observation"),
    @SerialName("opportunity") OPPORTUNITY("Opportunity"),
    @SerialName("actionItem") ACTION_ITEM("Action Item");

    companion object {
        fun fromWire(value: String?): ItemType {
            if (value == null) return IDEA
            return entries.find { it.name.equals(value, ignoreCase = true) || it.label.equals(value, ignoreCase = true) } ?: IDEA
        }
    }
}

enum class Priority(val label: String) {
    @SerialName("low") LOW("Low"),
    @SerialName("medium") MEDIUM("Medium"),
    @SerialName("high") HIGH("High");

    companion object {
        fun fromWire(value: String?): Priority? {
            if (value == null) return null
            return entries.find { it.name.equals(value, ignoreCase = true) }
        }
    }
}

enum class EntityType(val wireName: String, val label: String) {
    @SerialName("person") PERSON("person", "Person"),
    @SerialName("project") PROJECT("project", "Project"),
    @SerialName("organization") ORGANIZATION("organization", "Organization"),
    @SerialName("idea") IDEA("idea", "Idea"),
    @SerialName("task") TASK("task", "Task"),
    @SerialName("decision") DECISION("decision", "Decision"),
    @SerialName("event") EVENT("event", "Event"),
    @SerialName("product") PRODUCT("product", "Product"),
    @SerialName("tool") TOOL("tool", "Tool"),
    @SerialName("place") PLACE("place", "Place"),
    @SerialName("concept") CONCEPT("concept", "Concept"),
    @SerialName("date") DATE("date", "Date");

    companion object {
        fun fromWire(value: String?): EntityType {
            if (value == null) return CONCEPT
            return entries.find { it.wireName.equals(value, ignoreCase = true) || it.name.equals(value, ignoreCase = true) } ?: CONCEPT
        }
    }
}

enum class RelationType(val wireName: String, val label: String) {
    @SerialName("participates_in") PARTICIPATES_IN("participates_in", "participates in"),
    @SerialName("leads") LEADS("leads", "leads"),
    @SerialName("discusses") DISCUSSES("discusses", "discusses"),
    @SerialName("depends_on") DEPENDS_ON("depends_on", "depends on"),
    @SerialName("assigned_to") ASSIGNED_TO("assigned_to", "assigned to"),
    @SerialName("related_to") RELATED_TO("related_to", "related to");

    companion object {
        fun fromWire(value: String?): RelationType {
            if (value == null) return RELATED_TO
            return entries.find { it.wireName.equals(value, ignoreCase = true) || it.name.equals(value, ignoreCase = true) } ?: RELATED_TO
        }
    }
}

@Serializable
data class Item(
    val id: String,
    val type: ItemType = ItemType.IDEA,
    val title: String,
    val description: String = "",
    val position: Int = 0,
    val priority: Priority? = null,
    val timestampSec: Double? = null,
    val confidence: Double? = null,
    val completed: Boolean = false
)

@Serializable
data class Topic(
    val id: String,
    val title: String,
    val position: Int = 0,
    val description: String = "",
    val confidence: Double? = null,
    val items: List<Item> = emptyList()
)

@Serializable
data class GraphEntity(
    val id: String,
    val userId: String = "",
    val type: EntityType = EntityType.CONCEPT,
    val name: String,
    val canonicalName: String? = null,
    val aliases: List<String> = emptyList(),
    val mentions: Int = 1,
    val confidence: Double? = null
)

@Serializable
data class GraphRelation(
    val id: String,
    val userId: String = "",
    val sourceId: String,
    val targetId: String,
    val type: RelationType = RelationType.RELATED_TO,
    val weight: Double = 1.0,
    val confidence: Double? = null,
    val sessionId: String? = null
)

@Serializable
data class Session(
    val id: String,
    val userId: String = "user_default",
    val title: String? = null,
    val alternativeTitles: List<String> = emptyList(),
    val summary: String? = null,
    val summaryConfidence: Double? = null,
    val extractionConfidence: Double? = null,
    val language: String? = "en",
    val status: SessionStatus = SessionStatus.READY,
    val durationSec: Double? = null,
    val wordCount: Int? = null,
    val originalTranscript: String? = null,
    val cleanedTranscript: String? = null,
    val audioPath: String? = null,
    val audioRemoteUrl: String? = null,
    val promptVersions: Map<String, String> = emptyMap(),
    val favorite: Boolean = false,
    val archived: Boolean = false,
    val deleted: Boolean = false,
    val pinned: Boolean = false,
    val tags: List<String> = emptyList(),
    val lastError: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val topics: List<Topic> = emptyList(),
    val entities: List<GraphEntity> = emptyList(),
    val relationships: List<GraphRelation> = emptyList(),
    val segments: List<TranscriptSegment> = emptyList()
)

@Serializable
data class SessionVersion(
    val id: String,
    val sessionId: String,
    val versionNumber: Int,
    val title: String,
    val snapshotJson: String,
    val changeDescription: String,
    val createdAt: Long = System.currentTimeMillis()
)

@Serializable
data class DraftItem(
    val title: String,
    val body: String = "",
    val type: ItemType? = null,
    val priority: Priority? = null,
    val confidence: Double? = null
)

@Serializable
data class CommandDraft(
    val id: String,
    val sessionId: String,
    val command: String,
    val title: String,
    val body: String,
    val items: List<DraftItem> = emptyList(),
    val promptVersions: Map<String, String> = emptyMap(),
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis()
)

@Serializable
enum class ChatRole {
    @SerialName("user") USER,
    @SerialName("assistant") ASSISTANT
}

@Serializable
data class ChatMessage(
    val id: String,
    val sessionId: String,
    val role: ChatRole,
    val content: String,
    val citations: List<String> = emptyList(),
    val confidence: Double? = null,
    val promptVersions: Map<String, String> = emptyMap(),
    val createdAt: Long = System.currentTimeMillis()
)

enum class InsightKind(val label: String) {
    ENTITY("Entity"),
    TAG("Tag"),
    PERSON("Person"),
    PROJECT("Project"),
    TASK("Open Task"),
    DECISION("Decision")
}

@Serializable
data class InsightSource(
    val sessionId: String,
    val title: String,
    val snippet: String? = null
)

@Serializable
data class Insight(
    val kind: InsightKind,
    val label: String,
    val sessionCount: Int,
    val mentionCount: Int = 0,
    val confidence: Double,
    val statement: String,
    val sources: List<InsightSource>
)

@Serializable
data class PluginTargetStatus(
    val kind: String,
    val displayName: String,
    val connected: Boolean = false,
    val configured: Boolean = true,
    val iconName: String = "notion"
)

@Serializable
data class TranscriptSegment(
    val speaker: String,
    val text: String,
    val startSec: Double,
    val endSec: Double,
    val id: String = "seg_${java.util.UUID.randomUUID().toString().take(8)}",
    val confidence: Double = 0.95
)

@Serializable
data class ConflictInsight(
    val id: String,
    val topic: String,
    val description: String,
    val sessionAId: String,
    val sessionATitle: String,
    val sessionBId: String,
    val sessionBTitle: String,
    val resolutionSuggestion: String
)

enum class ExportFormat(val label: String, val extension: String) {
    OBSIDIAN_MARKDOWN("Obsidian Markdown (.md)", "md"),
    HTML_REPORT("Executive HTML Report (.html)", "html"),
    NOTION_BLOCKS("Notion Database Payload (.json)", "json"),
    JSON_SCHEMA("Canonical AI JSON Schema (.json)", "json"),
    GOOGLE_TASKS("Google Tasks & Reminders List", "txt")
}

enum class PromptPersona(val title: String, val subtitle: String, val systemDirective: String) {
    EXECUTIVE_BRIEF(
        "Executive Brief",
        "High-level executive takeaways, decisions, and business impact",
        "Synthesize this meeting from the perspective of an executive briefing: highlight strategic decisions, milestones, budget/resource impacts, and leadership directives."
    ),
    TECH_ARCHITECTURE(
        "Technical Architecture Review",
        "Focus on system design, APIs, scalability, and stack decisions",
        "Analyze this session with a deep technical architectural lens: extract database choices, API protocols, microservices, latency trade-offs, and engineer assignments."
    ),
    SALES_DISCOVERY(
        "Sales & Client Discovery",
        "Extract client pain points, budget, timeline, and next steps",
        "Structure this call around customer discovery: capture client pain points, timeline constraints, budget mentions, competitors, and explicit sales action items."
    ),
    SPRINT_PLAN(
        "Action-Driven Sprint Plan",
        "Organize deliverables by priority, estimate, and owner",
        "Deconstruct this conversation into a clean agile sprint backlog: group items into High/Medium/Low priority, assign owners, and write clear acceptance criteria."
    ),
    STUDY_GUIDE(
        "Academic & Research Guide",
        "Concept definitions, key formulas, and review questions",
        "Transform this knowledge into a comprehensive study guide: outline core concept hierarchies, summarize theories, and formulate active recall questions."
    );

    val label: String get() = title
}
