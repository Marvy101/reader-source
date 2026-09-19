create or replace function catalog_ingest.resolve_gutenberg_work()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  source_code_value text;
  normalized_title_value text;
  language_value text;
  authors_value text;
  candidate_work_id bigint;
begin
  if new.record_kind <> 'edition' then
    return new;
  end if;

  select source.code
  into source_code_value
  from catalog_ingest.sources as source
  where source.id = new.source_id;
  if source_code_value <> 'project_gutenberg' then
    return new;
  end if;

  if exists (
    select 1
    from catalog_ingest.source_work_matches as match
    where match.source_record_id = new.id
      and match.match_status = 'accepted'
  ) then
    return new;
  end if;

  normalized_title_value := lower(
    regexp_replace(btrim(new.raw_payload->>'title'), '\s+', ' ', 'g')
  );
  language_value := coalesce(
    nullif(new.raw_payload->'languages'->>0, ''),
    'und'
  );
  select string_agg(nullif(btrim(value->>'name'), ''), ', ' order by ordinality)
  into authors_value
  from jsonb_array_elements(
    coalesce(new.raw_payload->'authors', '[]'::jsonb)
  ) with ordinality as author_values(value, ordinality);

  if normalized_title_value is null or coalesce(authors_value, '') = '' then
    return new;
  end if;

  select document.display_work_id
  into candidate_work_id
  from catalog.search_documents as document
  join catalog.works as work on work.id = document.display_work_id
  where document.normalized_title = normalized_title_value
    and document.contributor_names = authors_value
    and work.language_code = language_value
  order by
    document.has_read_now desc,
    document.popularity_score desc,
    document.work_group_id
  limit 1;

  if candidate_work_id is not null then
    insert into catalog_ingest.source_work_matches(
      source_record_id,
      work_id,
      match_status,
      match_method,
      confidence,
      resolver_version
    ) values (
      new.id,
      candidate_work_id,
      'accepted',
      'provider_exact_title_contributors_language',
      0.95,
      2
    ) on conflict do nothing;
  end if;

  return new;
end;
$$;

create trigger source_records_resolve_gutenberg_work
after insert or update of raw_payload, status on catalog_ingest.source_records
for each row execute function catalog_ingest.resolve_gutenberg_work();

create or replace function catalog.preserve_preferred_search_document()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if
    (old.has_read_now and not new.has_read_now)
    or (
      old.has_read_now = new.has_read_now
      and old.popularity_score > new.popularity_score
    )
  then
    new.display_work_id := old.display_work_id;
    new.display_edition_id := old.display_edition_id;
    new.cover_location_id := old.cover_location_id;
    new.display_title := old.display_title;
    new.subtitle := old.subtitle;
    new.normalized_title := old.normalized_title;
    new.alternative_titles := old.alternative_titles;
    new.contributor_names := old.contributor_names;
    new.translator_names := old.translator_names;
    new.series_names := old.series_names;
    new.subject_names := old.subject_names;
    new.identifier_values := old.identifier_values;
    new.description := old.description;
    new.release_date := old.release_date;
    new.popularity_score := old.popularity_score;
    new.has_read_now := old.has_read_now;
    new.has_ebook := old.has_ebook;
    new.has_audiobook := old.has_audiobook;
    new.projection_version := old.projection_version;
  end if;
  return new;
end;
$$;

create trigger search_documents_preserve_preferred
before update on catalog.search_documents
for each row execute function catalog.preserve_preferred_search_document();

create or replace function catalog.sync_work_group_presentation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update catalog.work_group_presentations
  set preferred_work_id = new.display_work_id,
      preferred_edition_id = new.display_edition_id,
      preferred_cover_location_id = new.cover_location_id,
      updated_at = now()
  where work_group_id = new.work_group_id
    and locale = new.locale;
  return new;
end;
$$;

create trigger search_documents_sync_presentation
after insert or update on catalog.search_documents
for each row execute function catalog.sync_work_group_presentation();

comment on function catalog_ingest.resolve_gutenberg_work() is
  'Conservatively shares a work for exact Gutenberg title, credits, and language matches while retaining separate editions.';
comment on function catalog.preserve_preferred_search_document() is
  'Keeps the best read-now edition per work group, preferring availability and then provider popularity.';
