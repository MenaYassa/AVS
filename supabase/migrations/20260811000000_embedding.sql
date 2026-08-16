-- Migration: pgvector extension and embedding columns for Phase 6 semantic search.
-- Adds vector support and a session-level embedding column.

begin;

-- Enable pgvector extension
create extension if not exists vector;

-- Add embedding column to sessions (384 dimensions for all-MiniLM-L6-v2)
alter table sessions add column if not exists embedding vector(384);

-- Create HNSW index for fast cosine similarity search
create index if not exists idx_sessions_embedding on sessions using hnsw (embedding vector_cosine_ops);

commit;
