# AI Knowledge Companion 🧠🎙️

> **An offline-first, AI-powered Universal Knowledge Engine & Companion.**  
> Transforms unstructured voice notes, conversations, documents, emails, PDFs, and images into structured knowledge graphs, action items, insights, and executable workflows.

---

## 🌟 Overview

**AI Knowledge Companion** is not just a voice recorder—it is an end-to-end **AI Knowledge Engine** built for deep comprehension, synthesis, and actionable productivity. It pairs native mobile client apps with a high-throughput, modular Python processing pipeline and Supabase cloud synchronization.

```
                   ┌─────────────────────────────────────────────────┐
                   │            UNIVERSAL INPUT PIPELINE             │
                   │  Voice • Notes • OCR • PDFs • Emails • Docs    │
                   └────────────────────────┬────────────────────────┘
                                            ▼
                   ┌─────────────────────────────────────────────────┐
                   │         9-STAGE ORCHESTRATED AI PIPELINE        │
                   │   Cleanup ──► Segmentation ──► Classification   │
                   │      ▲             ▲                  ▲         │
                   │   Entity Ext. ◄── Task Ext. ◄── Knowledge Ext. │
                   │      ▼             ▼                  ▼         │
                   │    Tags   ──────► Validation ────► Embedding   │
                   └────────────────────────┬────────────────────────┘
                                            ▼
  ┌─────────────────────────────────────────┼─────────────────────────────────────────┐
  ▼                                         ▼                                         ▼
┌─────────────────────────┐   ┌───────────────────────────┐   ┌───────────────────────────┐
│     KNOWLEDGE GRAPH     │   │   PRODUCTIVITY & CHAT     │   │     HYBRID SEARCH & SYNC  │
│ • In-memory radial map  │   │ • 11 AI Command Bus tasks │   │ • SQLite FTS5 Full-Text   │
│ • Entity merge/relabel  │   │ • Grounded context chat   │   │ • MiniLM-L6-v2 Embeddings │
│ • BFS multi-hop explore │   │ • Notion / Slack Plugins  │   │ • CRDT/Diff sync engine   │
└─────────────────────────┘   └───────────────────────────┘   └───────────────────────────┘
```

---

## 🚀 Key Features

### 1. Universal Input Pipeline
- **Voice & Audio**: Real-time waveform visualizer, high-fidelity capture, and multi-provider STT (Whisper, Deepgram, AssemblyAI).
- **Document & File Parser**: Native parser engine for `.eml`, `.txt`, `.md`, `.rtf`, `.docx`, `.odt`, `.csv`, `.json`, and `.xml`.
- **OCR Intelligence**: Camera scan and image/PDF/screenshot ingestion with text isolation and pipeline feeding.
- **Manual Notes**: Direct thought capture without audio intermediaries.

### 2. 9-Stage AI Processing Orchestrator
- **Modular Pipeline**: Cleanup $\rightarrow$ Segmentation $\rightarrow$ Classification $\rightarrow$ Entity Extraction $\rightarrow$ Task Extraction $\rightarrow$ Knowledge Extraction $\rightarrow$ Tagging $\rightarrow$ JSON Schema Validation $\rightarrow$ Vector Embedding.
- **Immutable Prompt Assets**: Prompt versioning in JSON format with strict schema validation; prevents prompt drift.
- **Resumable Execution**: Intermediate-stage caching with automatic fallback and token-budget management.

### 3. Interactive Editing & Version History
- **Op-Log Architecture**: 15 distinct editing operations with infinite bidirectional Undo/Redo.
- **Point-in-Time Snapshots**: Structural diffing between session iterations with instant rollback.
- **Non-Destructive AI Re-Runs**: Re-process or refine transcripts while preserving user-edited entities and notes.

### 4. Knowledge Graph & Cross-Session Intelligence
- **Interactive Visualizer**: Custom radial layout with edge rendering, relationship labeling, and node focus.
- **Graph Mutation**: Merge duplicate entities, rename nodes, add relationships, and explore multi-hop connections.
- **Pattern Detection**: Automated detection of recurring projects, frequent collaborators, open blockers, and repeated decisions.

### 5. AI Productivity & Command Bus
- **11 Actionable AI Commands**: Generate meeting summaries, action matrices, quizzes, follow-up emails, decision trees, and flashcards.
- **Drafts First**: AI output is generated as non-destructive drafts requiring user review before merging.
- **Grounded Session Chat**: Multi-turn contextual chat powered by session content and opt-in user memory citations.
- **Third-Party Plugins**: Direct outbound publishing to **Notion** workspaces and **Slack** channels.

### 6. Hybrid Search & Cloud Sync
- **Local Hybrid Search**: Full-Text Search (SQLite FTS5) combined with local float32 vector cosine similarity ranking.
- **Sync Engine**: Diff-based outbox synchronization with conflict resolution and anchor translation.
- **Privacy First**: Optional auto-deletion of raw audio recordings post-transcription with local-only storage modes.

---

## 🏗️ Repository Structure

```
├── app/                  # Android Native Jetpack Compose Application
│   ├── src/main/java/    # Compose UI, Room DB v3, Gemini AI & Audio Services
│   └── build.gradle.kts  # Android build configuration
├── src/                  # Flutter Cross-Platform Client Application
│   ├── lib/              # Riverpod controllers, Drift SQLite schema v10, UI screens
│   └── test/             # 339 unit & widget tests (hermetic testing harnesses)
├── engine/               # Python/FastAPI Knowledge Engine Backend
│   ├── app/              # 9-stage pipeline, universal inputs, providers, plugins
│   ├── prompts/          # Versioned JSON prompt assets
│   └── tests/            # 317 hermetic pytest test cases
├── docs/                 # Authoritative Product & Technical Documentation
│   ├── spec.md           # Master product specification (31 sections)
│   ├── architecture.md   # Binding technical architecture baseline
│   └── Roadmap.md        # Phased milestone delivery log (Phases 1-6)
├── supabase/             # Cloud Database Migrations & Security Policies
│   └── migrations/       # PostgreSQL schemas, RLS policies, pgvector & FTS indexes
└── app_status.md         # Real-time subsystem health & test verification log
```

---

## 💻 Tech Stack

| Component | Technologies |
|---|---|
| **Android Client** | Kotlin, Jetpack Compose, Material 3, Room DB v3, Kotlin Coroutines, Gemini REST API |
| **Flutter Client** | Dart, Flutter, Riverpod, Drift (SQLite), `just_audio`, `record`, `go_router` |
| **Backend Engine** | Python 3.11+, FastAPI, Pydantic v2, Redis / RQ, SSE Streaming, `pgvector` |
| **AI & LLM Providers** | Google Gemini (Flash-Lite / Pro Thinking), OpenAI, Anthropic Claude, Whisper, Deepgram, AssemblyAI |
| **Cloud & Auth** | Supabase (PostgreSQL, Row-Level Security, Storage, GoTrue Auth) |
| **Testing** | Pytest (317 tests), Flutter Test (339 tests), Robolectric, JSON Schema Contract Validations |

---

## ⚡ Quickstart Guide

### 1. Android Client (`app/`)
```sh
# Verify and compile the Android applet
compile_applet
```
*Configured with Jetpack Compose, Room persistence, Document OCR scanner, and live Audio Visualizer.*

### 2. Flutter Client (`src/`)
```sh
cd src
~/flutter/flutter/bin/flutter analyze --no-pub
~/flutter/flutter/bin/flutter test --no-pub
```

### 3. Knowledge Engine Backend (`engine/`)
```sh
cd engine
uv sync
uv run ruff check .
uv run pytest
uv run uvicorn app.main:app --reload --port 8080
```

---

## 🧪 Quality & Test Verification

- **Flutter Client**: `339 passed`, `0 failed`, `3 skipped` (`flutter analyze` clean).
- **Engine Backend**: `317 passed`, `0 failed` (`ruff` clean).
- **Retrieval Quality**: Precision@5 evaluation verified across 23-session goldens.
- **Contract Parity**: Shared JSON Schema validation between Python backend and Dart data layer.

---

## 📖 Documentation Index

- 📘 [Product Specification](docs/spec.md) — Comprehensive user journeys, state machines, and UX requirements.
- 📐 [System Architecture](docs/architecture.md) — Binding technical architecture, database schemas, and API contracts.
- 🗺️ [Development Roadmap](docs/Roadmap.md) — Phased milestone delivery history and task log.
- 📊 [System Status](app_status.md) — Detailed verification status and subsystem breakdown.

---

## 📄 License
This project is proprietary and confidential. All rights reserved.
