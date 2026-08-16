-- Initial cloud schema (architecture §5.3, §7.2; roadmap §1.3).
--
-- Tables mirror the drift v2 session graph the app actually syncs (sessions,
-- topics, items) plus the audio bucket. Every user table is RLS-scoped to
-- `auth.uid()::text`; ownership is enforced server-side, never by the client (§5.4).
-- Columns match the PostgREST calls in `SupabaseSyncRepository` exactly
-- (including JSON-as-text for the _json columns, per the client contract).

-- ---------------------------------------------------------------------------
-- sessions
-- ---------------------------------------------------------------------------

create table if not exists public.sessions (
  id                      text primary key,
  user_id                 text not null,
  title                   text,
  alt_titles_json         text,
  summary                 text,
  summary_confidence      double precision,
  extraction_confidence   double precision,
  language                text,
  status                  text not null default 'recording',
  duration_sec            double precision,
  word_count              bigint,
  original_transcript     text,
  cleaned_transcript      text,
  audio_remote_url        text,
  prompt_versions_json    text,
  favorite                boolean not null default false,
  archived                boolean not null default false,
  deleted                 boolean not null default false,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- Incremental pull is `user_id`-scoped, ordered by `updated_at` (§4.13).
create index if not exists sessions_user_updated_idx
  on public.sessions (user_id, updated_at);

alter table public.sessions enable row level security;

-- CLI migrations must grant table privileges explicitly (the managed
-- dashboard's default-privileges do not exist on fresh stacks).
grant select, insert, update, delete on public.sessions to authenticated;
grant all privileges on public.sessions to service_role;

create policy "sessions_owned_by_authenticated_user"
  on public.sessions
  for all
  to authenticated
  using (user_id = auth.uid()::text)
  with check (user_id = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- topics
-- ---------------------------------------------------------------------------

create table if not exists public.topics (
  id           text primary key,
  session_id   text not null,
  position     integer not null,
  title        text not null,
  description  text not null default '',
  confidence   double precision
);

create index if not exists topics_session_idx on public.topics (session_id);

alter table public.topics enable row level security;

grant select, insert, update, delete on public.topics to authenticated;
grant all privileges on public.topics to service_role;

create policy "topics_owned_by_authenticated_user"
  on public.topics
  for all
  to authenticated
  using (session_id in (select id from public.sessions where user_id = auth.uid()::text))
  with check (session_id in (select id from public.sessions where user_id = auth.uid()::text));

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------

create table if not exists public.items (
  id             text primary key,
  topic_id       text not null,
  position       integer not null,
  type           text not null,
  title          text not null,
  description    text not null default '',
  priority       text,
  timestamp_sec  double precision,
  confidence     double precision
);

create index if not exists items_topic_idx on public.items (topic_id);

alter table public.items enable row level security;

grant select, insert, update, delete on public.items to authenticated;
grant all privileges on public.items to service_role;

create policy "items_owned_by_authenticated_user"
  on public.items
  for all
  to authenticated
  using (topic_id in (
    select t.id from public.topics t
    join public.sessions s on s.id = t.session_id
    where s.user_id = auth.uid()::text
  ))
  with check (topic_id in (
    select t.id from public.topics t
    join public.sessions s on s.id = t.session_id
    where s.user_id = auth.uid()::text
  ));

-- ---------------------------------------------------------------------------
-- Audio storage (architecture §7.2): sessions/{user_id}/{session_id}.m4a
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('sessions', 'sessions', false)
on conflict (id) do nothing;

create policy "sessions_bucket_access_own_folder"
  on storage.objects
  for all
  to authenticated
  using (
    bucket_id = 'sessions'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'sessions'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
