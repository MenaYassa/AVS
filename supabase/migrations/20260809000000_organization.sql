-- P4-B organization (roadmap §4.2; spec §19): pinned sessions, tags, and the
-- session<->tag join. The org flags from initial_schema (favorite/archived/
-- deleted) are joined by `pinned`, which ships on the canonical session JSON
-- and on every PostgREST write in `SupabaseSyncRepository`. Tags are
-- first-class, user-owned rows; `session_tags` inherits ownership through the
-- sessions FK, exactly like `topics`.

alter table public.sessions
  add column if not exists pinned boolean not null default false;

-- ---------------------------------------------------------------------------
-- tags
-- ---------------------------------------------------------------------------

create table if not exists public.tags (
  id       text primary key,
  user_id  text not null,
  name     text not null,
  color    text
);

create index if not exists tags_user_name_idx on public.tags (user_id, name);

alter table public.tags enable row level security;

grant select, insert, update, delete on public.tags to authenticated;
grant all privileges on public.tags to service_role;

create policy "tags_owned_by_authenticated_user"
  on public.tags
  for all
  to authenticated
  using (user_id = auth.uid()::text)
  with check (user_id = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- session_tags
-- ---------------------------------------------------------------------------

create table if not exists public.session_tags (
  session_id  text not null references public.sessions(id) on delete cascade,
  tag_id      text not null references public.tags(id) on delete cascade,
  primary key (session_id, tag_id)
);

create index if not exists session_tags_tag_idx on public.session_tags (tag_id);

alter table public.session_tags enable row level security;

grant select, insert, update, delete on public.session_tags to authenticated;
grant all privileges on public.session_tags to service_role;

create policy "session_tags_owned_by_authenticated_user"
  on public.session_tags
  for all
  to authenticated
  using (session_id in (
    select id from public.sessions where user_id = auth.uid()::text
  ))
  with check (session_id in (
    select id from public.sessions where user_id = auth.uid()::text
  ));
