"""AI command bus command names (architecture §4.11, spec §23).

A command is a versioned prompt asset that turns a session's canonical content
into an editable draft (`draft.schema.json`). Command names double as prompt
asset keys, so a command is immutable like every other prompt asset (§4.3).
"""

COMMAND_SHORTEN_SUMMARY = "shorten_summary"
COMMAND_EXPAND_SUMMARY = "expand_summary"
COMMAND_REWRITE_PROFESSIONAL = "rewrite_professional"
COMMAND_REWRITE_CASUAL = "rewrite_casual"
COMMAND_EXTRACT_TASKS = "extract_tasks"
COMMAND_MEETING_MINUTES = "meeting_minutes"
COMMAND_ACTION_PLAN = "action_plan"
COMMAND_EMAIL = "email"
COMMAND_REPORT = "report"
COMMAND_PRESENTATION_OUTLINE = "presentation_outline"
COMMAND_BLOG_POST = "blog_post"

COMMAND_NAMES: tuple[str, ...] = (
    COMMAND_SHORTEN_SUMMARY,
    COMMAND_EXPAND_SUMMARY,
    COMMAND_REWRITE_PROFESSIONAL,
    COMMAND_REWRITE_CASUAL,
    COMMAND_EXTRACT_TASKS,
    COMMAND_MEETING_MINUTES,
    COMMAND_ACTION_PLAN,
    COMMAND_EMAIL,
    COMMAND_REPORT,
    COMMAND_PRESENTATION_OUTLINE,
    COMMAND_BLOG_POST,
)
