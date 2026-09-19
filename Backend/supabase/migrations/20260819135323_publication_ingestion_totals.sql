create or replace function public.publication_ingestion_totals(
  target_publication_id uuid
)
returns table (
  chunk_count bigint,
  character_count bigint,
  minimum_ordinal integer,
  maximum_ordinal integer
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    count(*)::bigint,
    coalesce(sum(char_length(chunk.text)), 0)::bigint,
    min(chunk.ordinal),
    max(chunk.ordinal)
  from public.publication_chunks as chunk
  where chunk.publication_id = target_publication_id
    and chunk.user_id = (select auth.uid());
$$;
