import 'dart:convert';

import '../../domain/entities/chat_message.dart';
import '../../domain/entities/command_draft.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/graph.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/provider_setting.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../local/database.dart';

/// Maps between domain entities and drift rows.

Session sessionFromRow(SessionRow row, List<Topic> topics) => Session(
      id: row.id,
      userId: row.userId,
      title: row.title,
      alternativeTitles:
          (jsonDecode(row.altTitlesJson ?? '[]') as List<dynamic>).cast<String>(),
      summary: row.summary,
      summaryConfidence: row.summaryConfidence,
      extractionConfidence: row.extractionConfidence,
      language: row.language,
      status: SessionStatus.values
              .where((s) => s.name == row.status)
              .firstOrNull ??
          SessionStatus.recording,
      durationSec: row.durationSec,
      wordCount: row.wordCount,
      originalTranscript: row.originalTranscript,
      cleanedTranscript: row.cleanedTranscript,
      audioPath: row.audioPath,
      audioRemoteUrl: row.audioRemoteUrl,
      promptVersions: row.promptVersionsJson == null
          ? const {}
          : (jsonDecode(row.promptVersionsJson!) as Map<String, dynamic>),
      favorite: row.favorite,
      archived: row.archived,
      deleted: row.deleted,
      pinned: row.pinned,
      lastError: row.lastErrorJson,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      topics: topics,
    );

SessionRow sessionToRow(Session s) => SessionRow(
      id: s.id,
      userId: s.userId,
      title: s.title,
      altTitlesJson: jsonEncode(s.alternativeTitles),
      summary: s.summary,
      summaryConfidence: s.summaryConfidence,
      extractionConfidence: s.extractionConfidence,
      language: s.language,
      status: s.status.name,
      durationSec: s.durationSec,
      wordCount: s.wordCount,
      originalTranscript: s.originalTranscript,
      cleanedTranscript: s.cleanedTranscript,
      audioPath: s.audioPath,
      audioRemoteUrl: s.audioRemoteUrl,
      promptVersionsJson: s.promptVersions.isEmpty
          ? null
          : jsonEncode(s.promptVersions),
      favorite: s.favorite,
      archived: s.archived,
      deleted: s.deleted,
      pinned: s.pinned,
      lastErrorJson: s.lastError,
      createdAt: s.createdAt ?? DateTime.now().toUtc(),
      updatedAt: s.updatedAt ?? DateTime.now().toUtc(),
    );

Topic topicFromRow(TopicRow row, List<ItemRow> itemRows) => Topic(
      id: row.id,
      title: row.title,
      description: row.description,
      position: row.position,
      confidence: row.confidence,
      items: itemRows
          .where((i) => i.topicId == row.id)
          .map(itemFromRow)
          .toList(),
    );

TopicRow topicToRow(Session session, Topic t) => TopicRow(
      id: t.id,
      sessionId: session.id,
      position: t.position,
      title: t.title,
      description: t.description,
      confidence: t.confidence,
    );

Item itemFromRow(ItemRow row) => Item(
      id: row.id,
      type: ItemType.values.where((t) => t.name == row.type).firstOrNull ??
          ItemType.idea,
      title: row.title,
      description: row.description,
      position: row.position,
      priority: Priority.values
              .where((p) => p.name == row.priority)
              .firstOrNull,
      timestampSec: row.timestampSec,
      confidence: row.confidence,
    );

ItemRow itemToRow(Topic topic, Item item) => ItemRow(
      id: item.id,
      topicId: topic.id,
      position: item.position,
      type: item.type.name,
      title: item.title,
      description: item.description,
      priority: item.priority?.name,
      timestampSec: item.timestampSec,
      confidence: item.confidence,
    );

Job jobFromRow(JobRow row) => Job(
      id: row.id,
      userId: row.userId,
      kind: JobKind.values.where((k) => k.name == row.kind).firstOrNull ??
          JobKind.analyze,
      status: JobStatus.values
              .where((s) => s.name == row.status)
              .firstOrNull ??
          JobStatus.queued,
      stage: row.stage,
      inputRef: row.inputRef,
      resultJson: row.resultJson,
      errorJson: row.errorJson,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );

JobRow jobToRow(Job j) => JobRow(
      id: j.id,
      userId: j.userId,
      kind: j.kind.name,
      status: j.status.name,
      stage: j.stage,
      inputRef: j.inputRef,
      resultJson: j.resultJson,
      errorJson: j.errorJson,
      createdAt: j.createdAt ?? DateTime.now().toUtc(),
      updatedAt: j.updatedAt ?? DateTime.now().toUtc(),
    );

ProviderSetting providerSettingFromRow(ProviderSettingRow row) =>
    ProviderSetting.fromConfigJson(
      row.id,
      row.userId,
      ProviderKind.values.where((k) => k.name == row.kind).firstOrNull ??
          ProviderKind.llm,
      row.provider,
      row.configJson ?? '{}',
      enabled: row.enabled,
    );

ProviderSettingRow providerSettingToRow(ProviderSetting p) => ProviderSettingRow(
      id: p.id,
      userId: p.userId,
      kind: p.kind.name,
      provider: p.provider,
      configJson: p.configJson,
      enabled: p.enabled,
    );

Tag tagFromRow(TagRow row) => Tag(
      id: row.id,
      userId: row.userId,
      name: row.name,
      color: row.color,
    );

TagRow tagToRow(Tag t) => TagRow(
      id: t.id,
      userId: t.userId,
      name: t.name,
      color: t.color,
    );

GraphEntity entityFromRow(EntityRow row) => GraphEntity(
      id: row.id,
      userId: row.userId,
      type: EntityType.fromWire(row.type) ?? EntityType.idea,
      name: row.name,
      canonicalName: row.canonicalName,
      aliases: (jsonDecode(row.aliasesJson ?? '[]') as List<dynamic>).cast<String>(),
    );

EntityRow entityToRow(GraphEntity e) => EntityRow(
      id: e.id,
      userId: e.userId,
      type: e.type.wireName,
      name: e.name,
      canonicalName: e.canonicalName,
      aliasesJson: jsonEncode(e.aliases),
    );

GraphRelation relationFromRow(RelationshipRow row) => GraphRelation(
      id: row.id,
      userId: row.userId,
      sourceId: row.sourceId,
      targetId: row.targetId,
      type: RelationType.fromWire(row.type) ?? RelationType.relatedTo,
      weight: row.weight,
      confidence: row.confidence,
      sessionId: row.sessionId,
    );

RelationshipRow relationToRow(GraphRelation r, {String? sessionId}) =>
    RelationshipRow(
      id: r.id,
      userId: r.userId,
      sourceId: r.sourceId,
      targetId: r.targetId,
      type: r.type.wireName,
      weight: r.weight,
      confidence: r.confidence,
      sessionId: sessionId ?? r.sessionId,
      deleted: false,
    );

/// Maps between Draft entities and drift rows.
CommandDraft draftFromRow(DraftRow row) => CommandDraft(
      id: row.id,
      sessionId: row.sessionId,
      command: row.command,
      title: row.title,
      body: row.body,
      items: row.itemsJson == null
          ? const []
          : (jsonDecode(row.itemsJson!) as List<dynamic>)
              .map((e) => DraftItem.fromJson(e as Map<String, dynamic>))
              .toList(),
      promptVersions: row.promptVersionsJson == null
          ? const {}
          : (jsonDecode(row.promptVersionsJson!) as Map<String, dynamic>),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );

DraftRow draftToRow(CommandDraft d) => DraftRow(
      id: d.id,
      sessionId: d.sessionId,
      command: d.command,
      title: d.title,
      body: d.body,
      itemsJson: d.items.isEmpty
          ? null
          : jsonEncode(d.items.map((i) => i.toJson()).toList()),
      promptVersionsJson: d.promptVersions.isEmpty
          ? null
          : jsonEncode(d.promptVersions),
      createdAt: d.createdAt ?? DateTime.now().toUtc(),
      updatedAt: d.updatedAt ?? DateTime.now().toUtc(),
    );

/// Maps between ChatMessage entities and drift rows.
ChatMessage chatMessageFromRow(ChatMessageRow row) => ChatMessage(
      id: row.id,
      sessionId: row.sessionId,
      role: ChatRole.values
              .where((r) => r.name == row.role)
              .firstOrNull ??
          ChatRole.user,
      content: row.content,
      citations: row.citationsJson == null
          ? const []
          : (jsonDecode(row.citationsJson!) as List<dynamic>).cast<String>(),
      confidence: row.confidence,
      promptVersions: row.promptVersionsJson == null
          ? const {}
          : (jsonDecode(row.promptVersionsJson!) as Map<String, dynamic>),
      createdAt: row.createdAt,
    );

ChatMessageRow chatMessageToRow(ChatMessage m) => ChatMessageRow(
      id: m.id,
      sessionId: m.sessionId,
      role: m.role.name,
      content: m.content,
      citationsJson: m.citations.isEmpty
          ? null
          : jsonEncode(m.citations),
      confidence: m.confidence,
      promptVersionsJson: m.promptVersions.isEmpty
          ? null
          : jsonEncode(m.promptVersions),
      createdAt: m.createdAt ?? DateTime.now().toUtc(),
    );
