library;

import 'package:flutter/material.dart';

/// The 11 AI Rewrite Tools commands (spec §23, architecture §4.11).
///
/// Each command maps 1:1 to an engine prompt asset (`commands/<name>.1.json`).
/// The catalog provides UI labels, icons, and grouping for the command palette.

enum CommandCategory { summary, rewrite, extract, document, plan }

/// A single AI command surfaced to the user.
class Command {
  const Command({
    required this.name,
    required this.label,
    required this.icon,
    required this.category,
    required this.description,
  });

  /// Engine command name (must match `COMMAND_NAMES` in the engine).
  final String name;

  /// User-visible label.
  final String label;

  /// Material icon.
  final IconData icon;

  /// High-level grouping in the palette.
  final CommandCategory category;

  /// Short description for the palette.
  final String description;
}

/// The canonical list of AI commands.
const List<Command> kAllCommands = [
  Command(
    name: 'shorten_summary',
    label: 'Shorten summary',
    icon: Icons.summarize,
    category: CommandCategory.summary,
    description: 'Condense the session summary to 2-3 sentences',
  ),
  Command(
    name: 'expand_summary',
    label: 'Expand summary',
    icon: Icons.summarize,
    category: CommandCategory.summary,
    description: 'Write a detailed summary with all key points',
  ),
  Command(
    name: 'rewrite_professional',
    label: 'Rewrite professionally',
    icon: Icons.business,
    category: CommandCategory.rewrite,
    description: 'Formal, concise tone for workplace audiences',
  ),
  Command(
    name: 'rewrite_casual',
    label: 'Rewrite casually',
    icon: Icons.chat_bubble_outline,
    category: CommandCategory.rewrite,
    description: 'Friendly, conversational tone',
  ),
  Command(
    name: 'extract_tasks',
    label: 'Extract tasks',
    icon: Icons.task_alt,
    category: CommandCategory.extract,
    description: 'List all action items and commitments',
  ),
  Command(
    name: 'meeting_minutes',
    label: 'Meeting minutes',
    icon: Icons.event_note,
    category: CommandCategory.document,
    description: 'Structured minutes with decisions and actions',
  ),
  Command(
    name: 'action_plan',
    label: 'Action plan',
    icon: Icons.flag,
    category: CommandCategory.plan,
    description: 'Ordered steps with priorities from the session',
  ),
  Command(
    name: 'email',
    label: 'Draft email',
    icon: Icons.email_outlined,
    category: CommandCategory.document,
    description: 'Professional email from the session content',
  ),
  Command(
    name: 'report',
    label: 'Generate report',
    icon: Icons.article_outlined,
    category: CommandCategory.document,
    description: 'Structured report with background, findings, next steps',
  ),
  Command(
    name: 'presentation_outline',
    label: 'Presentation outline',
    icon: Icons.slideshow_outlined,
    category: CommandCategory.plan,
    description: 'Slide-by-slide outline with key points',
  ),
  Command(
    name: 'blog_post',
    label: 'Write blog post',
    icon: Icons.rss_feed,
    category: CommandCategory.document,
    description: 'Engaging blog post for a general audience',
  ),
];

/// Commands grouped by category for the palette UI.
Map<CommandCategory, List<Command>> get commandsByCategory {
  final map = <CommandCategory, List<Command>>{};
  for (final cmd in kAllCommands) {
    map.putIfAbsent(cmd.category, () => []).add(cmd);
  }
  return map;
}