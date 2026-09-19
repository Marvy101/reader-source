create table public.publication_knowledge (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 500),
  author text,
  format text not null check (format in ('pdf', 'epub', 'plainText')),
  fingerprint text not null,
  text_access text not null default 'cloud_searchable'
    check (text_access in ('cloud_searchable', 'local_only', 'restricted', 'unavailable')),
  processing_status text not null default 'pending'
    check (processing_status in ('pending', 'processing', 'parsed', 'failed')),
  parser_kind text not null default 'reader_extracted_text',
  parser_version integer not null default 1,
  chunk_count integer not null default 0 check (chunk_count >= 0),
  character_count bigint not null default 0 check (character_count >= 0),
  last_error text,
  parsed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);

create table public.publication_chunks (
  id uuid primary key default gen_random_uuid(),
  publication_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  ordinal integer not null check (ordinal >= 0),
  resource_id text not null,
  resource_title text,
  text text not null check (char_length(text) > 0),
  position_start integer not null default 0 check (position_start >= 0),
  position_end integer not null check (position_end >= position_start),
  progression_start double precision not null
    check (progression_start between 0 and 1),
  progression_end double precision not null
    check (progression_end between 0 and 1),
  search_vector tsvector generated always as (
    to_tsvector('simple', coalesce(resource_title, '') || ' ' || text)
  ) stored,
  created_at timestamptz not null default now(),
  unique (publication_id, ordinal),
  foreign key (publication_id, user_id)
    references public.publication_knowledge(id, user_id)
    on delete cascade
);

create table public.publication_annotations (
  id uuid primary key,
  publication_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  selected_text text not null check (char_length(selected_text) > 0),
  note text,
  resource_id text not null,
  position integer not null default 0 check (position >= 0),
  progression double precision not null check (progression between 0 and 1),
  locator jsonb not null,
  search_vector tsvector generated always as (
    to_tsvector('simple', selected_text || ' ' || coalesce(note, ''))
  ) stored,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  unique (publication_id, id),
  foreign key (publication_id, user_id)
    references public.publication_knowledge(id, user_id)
    on delete cascade
);

create index publication_knowledge_user_status
  on public.publication_knowledge(user_id, processing_status, updated_at desc);

create index publication_chunks_publication_progression
  on public.publication_chunks(publication_id, progression_start, ordinal);

create index publication_chunks_search
  on public.publication_chunks using gin(search_vector);

create index publication_annotations_publication_progression
  on public.publication_annotations(publication_id, progression);

create index publication_annotations_search
  on public.publication_annotations using gin(search_vector);

create trigger publication_knowledge_set_updated_at
before update on public.publication_knowledge
for each row execute function public.set_updated_at();

create trigger publication_annotations_set_updated_at
before update on public.publication_annotations
for each row execute function public.set_updated_at();

alter table public.publication_knowledge enable row level security;
alter table public.publication_chunks enable row level security;
alter table public.publication_annotations enable row level security;

create policy publication_knowledge_manage_own
on public.publication_knowledge for all
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy publication_chunks_manage_own
on public.publication_chunks for all
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy publication_annotations_manage_own
on public.publication_annotations for all
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create or replace function public.search_publication_chunks(
  target_publication_id uuid,
  search_query text,
  maximum_progression double precision default 1,
  result_limit integer default 6
)
returns table (
  ordinal integer,
  resource_id text,
  resource_title text,
  text text,
  position_start integer,
  position_end integer,
  progression_start double precision,
  progression_end double precision,
  rank real
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    chunk.ordinal,
    chunk.resource_id,
    chunk.resource_title,
    chunk.text,
    chunk.position_start,
    chunk.position_end,
    chunk.progression_start,
    chunk.progression_end,
    ts_rank_cd(chunk.search_vector, websearch_to_tsquery('simple', search_query)) as rank
  from public.publication_chunks as chunk
  join public.publication_knowledge as knowledge
    on knowledge.id = chunk.publication_id
  where chunk.publication_id = target_publication_id
    and chunk.user_id = (select auth.uid())
    and knowledge.processing_status = 'parsed'
    and chunk.progression_end <= greatest(0, least(maximum_progression, 1))
    and chunk.search_vector @@ websearch_to_tsquery('simple', search_query)
  order by rank desc, chunk.ordinal asc
  limit greatest(1, least(result_limit, 12));
$$;

create or replace function public.search_publication_annotations(
  target_publication_id uuid,
  search_query text,
  maximum_progression double precision default 1,
  result_limit integer default 6
)
returns table (
  id uuid,
  selected_text text,
  note text,
  resource_id text,
  progression double precision,
  locator jsonb,
  rank real
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    annotation.id,
    annotation.selected_text,
    annotation.note,
    annotation.resource_id,
    annotation.progression,
    annotation.locator,
    ts_rank_cd(annotation.search_vector, websearch_to_tsquery('simple', search_query)) as rank
  from public.publication_annotations as annotation
  where annotation.publication_id = target_publication_id
    and annotation.user_id = (select auth.uid())
    and annotation.progression <= greatest(0, least(maximum_progression, 1))
    and annotation.search_vector @@ websearch_to_tsquery('simple', search_query)
  order by rank desc, annotation.created_at desc
  limit greatest(1, least(result_limit, 12));
$$;
