import 'dart:convert';

import 'enums.dart';

/// An AI job tracked by the engine (architecture §4.2).
class Job {
  const Job({
    required this.id,
    required this.userId,
    required this.kind,
    required this.status,
    this.stage,
    this.sessionStatus,
    this.stageLabel,
    this.inputRef,
    this.intermediatesJson,
    this.resultJson,
    this.errorJson,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String userId;
  final JobKind kind;
  final JobStatus status;

  /// Current pipeline stage name when running (architecture §4.2).
  final String? stage;

  /// Session lifecycle projection of the job (architecture §4.5).
  final String? sessionStatus;

  /// Human-readable label for the current stage (UI rendering).
  final String? stageLabel;
  final String? inputRef;
  final String? intermediatesJson;
  final String? resultJson;
  final String? errorJson;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Job copyWith({
    JobStatus? status,
    String? stage,
    String? sessionStatus,
    String? stageLabel,
    String? intermediatesJson,
    String? resultJson,
    String? errorJson,
    DateTime? updatedAt,
    bool clearError = false,
    bool clearResult = false,
  }) {
    return Job(
      id: id,
      userId: userId,
      kind: kind,
      status: status ?? this.status,
      stage: stage ?? this.stage,
      sessionStatus: sessionStatus ?? this.sessionStatus,
      stageLabel: stageLabel ?? this.stageLabel,
      inputRef: inputRef,
      intermediatesJson: intermediatesJson ?? this.intermediatesJson,
      resultJson: clearResult ? null : (resultJson ?? this.resultJson),
      errorJson: clearError ? null : (errorJson ?? this.errorJson),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Nested engine payloads (`intermediates`/`result`/`error`) arrive as JSON
  /// objects; normalize them to JSON strings so callers can `jsonDecode`.
  static String? _encode(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return jsonEncode(value);
  }

  factory Job.fromJson(Map<String, dynamic> json) => Job(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        kind: JobKind.values.firstWhere(
            (k) => k.name == json['kind'],
            orElse: () => JobKind.analyze),
        status: JobStatus.values.firstWhere(
            (s) => s.name == json['status'],
            orElse: () => JobStatus.queued),
        stage: json['stage'] as String?,
        sessionStatus: json['session_status'] as String?,
        stageLabel: json['stage_label'] as String?,
        inputRef: json['input_ref'] as String?,
        intermediatesJson: _encode(json['intermediates']),
        resultJson: _encode(json['result']),
        errorJson: _encode(json['error']),
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );
}
