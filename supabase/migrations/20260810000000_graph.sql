-- P4-D knowledge graph cloud support (architecture §4.8, §5.3; roadmap §4.4).
--
-- First-class, per-user graph tables mirroring the drift `entities`,
-- `session_entities`, and `relationships` tables exactly (the columns the app
-- actually syncs). Entities are global per user; membership in a session is a
-- `session_entities` row so the same person can appear across many sessions.
-- Relationships are per-session edges (drift keeps a soft `deleted` flag).
--
-- The `graph_traverse` RPC is the Postgres analogue of the local drift
-- traversal: a recursive CTE BFS over a session's subgraph (architecture §4.8:
-- "cloud traversal via Postgres recursive CTEs"). SECURITY INVOKER with a
-- pinned search_path, so RLS scopes results to the caller's own sessions.

-- ---------------------------------------------------------------------------
-- entities (global, user-owned nodes)
-- ---------------------------------------------------------------------------

create table if not exists public.entities (
  id             text primary key,
  user_id        text not null,
  type           text not null,
  name           text not null,
  canonical_name text,
  aliases_json   text
);

create index if not exists entities_user_name_idx on public.entities (user_id, name);
create index if not exists entities_user_type_idx on public.entities (user_id, type);

alter table public.entities enable row level security;

grant select, insert, update, delete on public.entities to authenticated;
grant all privileges on public.entities to service_role;

create policy "entities_owned_by_authenticated_user"
  on public.entities
  for all
  to authenticated
  using (user_id = auth.uid()::text)
  with check (user_id = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- session_entities (membership + per-session confidence)
-- ---------------------------------------------------------------------------

create table if not exists public.session_entities (
  session_id  text not null references public.sessions(id) on delete cascade,
  entity_id   text not null references public.entities(id) on delete cascade,
  confidence  double precision,
  primary key (session_id, entity_id)
);

create index if not exists session_entities_entity_idx on public.session_entities (entity_id);

alter table public.session_entities enable row level security;

grant select, insert, update, delete on public.session_entities to authenticated;
grant all privileges on public.session_entities to service_role;

create policy "session_entities_owned_by_authenticated_user"
  on public.session_entities
  for all
  to authenticated
  using (session_id in (
    select id from public.sessions where user_id = auth.uid()::text
  ))
  with check (session_id in (
    select id from public.sessions where user_id = auth.uid()::text
  ));

-- ---------------------------------------------------------------------------
-- relationships (per-session edges)
-- ---------------------------------------------------------------------------

create table if not exists public.relationships (
  id          text primary key,
  user_id     text not null,
  source_id   text not null references public.entities(id) on delete cascade,
  target_id   text not null references public.entities(id) on delete cascade,
  type        text not null,
  weight      double precision not null default 1.0,
  confidence  double precision,
  session_id  text,
  deleted     boolean not null default false
);

create index if not exists relationships_session_idx on public.relationships (session_id);
create index if not exists relationships_source_idx on public.relationships (source_id);
create index if not exists relationships_target_idx on public.relationships (target_id);

alter table public.relationships enable row level security;

grant select, insert, update, delete on public.relationships to authenticated;
grant all privileges on public.relationships to service_role;

create policy "relationships_owned_by_authenticated_user"
  on public.relationships
  for all
  to authenticated
  using (
    (session_id is not null and session_id in (
      select id from public.sessions where user_id = auth.uid()::text
    ))
    or (session_id is null and user_id = auth.uid()::text)
  )
  with check (
    (session_id is not null and session_id in (
      select id from public.sessions where user_id = auth.uid()::text
    ))
    or (session_id is null and user_id = auth.uid()::text)
  );

-- ---------------------------------------------------------------------------
-- graph_traverse: cloud-side BFS over a session's subgraph
-- ---------------------------------------------------------------------------

create or replace function public.graph_traverse(
  p_session_id text,
  p_start_entity_id text,
  p_max_depth int default 3
)
returns jsonb
language sql
security invoker
set search_path = public
as $func$
  with recursive reachable(entity_id, depth) as (
    select se.entity_id, 0
    from public.session_entities se
    where se.session_id = p_session_id and se.entity_id = p_start_entity_id
    union
    select case when r.source_id = rv.entity_id then r.target_id else r.source_id end,
           rv.depth + 1
    from reachable rv
    join public.relationships r
      on r.session_id = p_session_id
     and r.deleted = false
     and (r.source_id = rv.entity_id or r.target_id = rv.entity_id)
    where rv.depth < p_max_depth
  ),
  node_ids as (
    select distinct entity_id from reachable
  )
  select jsonb_build_object(
    'nodes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'type', e.type,
        'name', e.name,
        'canonical_name', e.canonical_name,
        'aliases', coalesce(e.aliases_json::jsonb, '[]'::jsonb),
        'confidence', se.confidence
      ))
      from public.entities e
      join node_ids n on n.entity_id = e.id
      left join public.session_entities se
        on se.entity_id = e.id and se.session_id = p_session_id
    ), '[]'::jsonb),
    'edges', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'source_id', r.source_id,
        'target_id', r.target_id,
        'type', r.type,
        'weight', r.weight,
        'confidence', r.confidence
      ))
      from public.relationships r
      where r.session_id = p_session_id
        and r.deleted = false
        and r.source_id in (select entity_id from node_ids)
        and r.target_id in (select entity_id from node_ids)
    ), '[]'::jsonb)
  );
$func$;

grant execute on function public.graph_traverse(text, text, int) to authenticated;
