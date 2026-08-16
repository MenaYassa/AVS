-- Cloud-side search fallback (architecture §5.4, roadmap §4.1).
--
-- When the app's local FTS index misses (e.g. fresh install whose cloud
-- sessions have not finished pulling), the client calls `search_sessions`
-- which searches a denormalized `session_search` table maintained by triggers
-- — the Postgres analogue of the local schema v6 `search_content` table.
--
-- The function is SECURITY INVOKER with a pinned search_path, so RLS on the
-- underlying tables scopes results to the caller's own sessions.

-- ---------------------------------------------------------------------------
-- session_search: aggregated, searchable content per session
-- ---------------------------------------------------------------------------

create table if not exists public.session_search (
  session_id     text primary key,
  content        text not null,
  search_vector  tsvector not null
);

create index if not exists session_search_vector_idx
  on public.session_search using gin (search_vector);

alter table public.session_search enable row level security;

grant select, insert, update, delete on public.session_search to authenticated;
grant all privileges on public.session_search to service_role;

create policy "session_search_owned_by_authenticated_user"
  on public.session_search
  for all
  to authenticated
  using (session_id in (select id from public.sessions where user_id = auth.uid()::text))
  with check (session_id in (select id from public.sessions where user_id = auth.uid()::text));

-- ---------------------------------------------------------------------------
-- Recompute helper (mirrors the app's `_searchContentSelect`)
-- ---------------------------------------------------------------------------

create or replace function public.session_search_recompute(p_session_id text)
returns void
language plpgsql
security invoker
set search_path = public
as $func$
begin
  insert into public.session_search (session_id, content, search_vector)
  select session_id, content, to_tsvector('english', content)
  from (
    select s.id as session_id,
      coalesce(s.title, '') || ' ' || coalesce(s.alt_titles_json, '') || ' ' ||
      coalesce(s.summary, '') || ' ' || coalesce(s.original_transcript, '') || ' ' ||
      coalesce(s.cleaned_transcript, '') || ' ' || coalesce((
        select string_agg(t.title || ' ' || coalesce((
          select string_agg(i.title || ' ' || coalesce(i.description, ''), ' ')
          from public.items i where i.topic_id = t.id), ''), ' ')
        from public.topics t where t.session_id = s.id), '') as content
    from public.sessions s
    where s.id = p_session_id
  ) r
  on conflict (session_id) do update
    set content = excluded.content,
        search_vector = excluded.search_vector;

  -- A session that no longer exists (hard delete) leaves a stale row behind.
  if not exists (select 1 from public.sessions where id = p_session_id) then
    delete from public.session_search where session_id = p_session_id;
  end if;
end;
$func$;

grant execute on function public.session_search_recompute(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Triggers: recompute the whole session row on any sessions/topics/items change
-- ---------------------------------------------------------------------------

create or replace function public.session_search_refresh()
returns trigger
language plpgsql
security invoker
set search_path = public
as $func$
declare
  v_session_id text;
begin
  if tg_table_name = 'sessions' then
    v_session_id := coalesce(new.id, old.id);
  elsif tg_table_name = 'topics' then
    v_session_id := coalesce(new.session_id, old.session_id);
  else
    select session_id into v_session_id
    from public.topics where id = coalesce(new.topic_id, old.topic_id);
  end if;

  if v_session_id is not null then
    perform public.session_search_recompute(v_session_id);
  end if;
  return null;
end;
$func$;

grant execute on function public.session_search_refresh() to authenticated;

drop trigger if exists session_search_sessions_trg on public.sessions;
create trigger session_search_sessions_trg
  after insert or update or delete on public.sessions
  for each row execute function public.session_search_refresh();

drop trigger if exists session_search_topics_trg on public.topics;
create trigger session_search_topics_trg
  after insert or update or delete on public.topics
  for each row execute function public.session_search_refresh();

drop trigger if exists session_search_items_trg on public.items;
create trigger session_search_items_trg
  after insert or update or delete on public.items
  for each row execute function public.session_search_refresh();

-- Backfill existing sessions.
insert into public.session_search (session_id, content, search_vector)
select
  s.id,
  coalesce(s.title, '') || ' ' || coalesce(s.alt_titles_json, '') || ' ' ||
  coalesce(s.summary, '') || ' ' || coalesce(s.original_transcript, '') || ' ' ||
  coalesce(s.cleaned_transcript, '') || ' ' || coalesce((
    select string_agg(t.title || ' ' || coalesce((
      select string_agg(i.title || ' ' || coalesce(i.description, ''), ' ')
      from public.items i where i.topic_id = t.id), ''), ' ')
    from public.topics t where t.session_id = s.id), ''),
  to_tsvector('english',
    coalesce(s.title, '') || ' ' || coalesce(s.alt_titles_json, '') || ' ' ||
    coalesce(s.summary, '') || ' ' || coalesce(s.original_transcript, '') || ' ' ||
    coalesce(s.cleaned_transcript, '') || ' ' || coalesce((
      select string_agg(t.title || ' ' || coalesce((
        select string_agg(i.title || ' ' || coalesce(i.description, ''), ' ')
        from public.items i where i.topic_id = t.id), ''), ' ')
      from public.topics t where t.session_id = s.id), '')
  )
from public.sessions s
on conflict (session_id) do nothing;

-- ---------------------------------------------------------------------------
-- search_sessions: the RPC the app calls as its cloud fallback
-- ---------------------------------------------------------------------------

create or replace function public.search_sessions(p_query text, p_limit int default 20)
returns table (
  session_id text,
  title      text,
  summary    text,
  status     text,
  snippet    text
)
language sql
security invoker
set search_path = public
as $func$
  select
    s.id,
    s.title,
    s.summary,
    s.status,
    ts_headline('english', ss.content, plainto_tsquery('english', p_query),
      'StartSel=<mark>, StopSel=</mark>, MaxWords=30, MinWords=15, ShortWord=3, HighlightAll=false') as snippet
  from public.session_search ss
  join public.sessions s on s.id = ss.session_id
  where s.deleted = false
    and ss.search_vector @@ plainto_tsquery('english', p_query)
  order by ts_rank(ss.search_vector, plainto_tsquery('english', p_query)) desc
  limit p_limit;
$func$;

grant execute on function public.search_sessions(text, int) to authenticated;
