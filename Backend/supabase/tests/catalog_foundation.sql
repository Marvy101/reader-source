begin;

create or replace function pg_temp.assert_true(condition boolean, message text)
returns void
language plpgsql
as $$
begin
  if condition is not true then
    raise exception 'assertion failed: %', message;
  end if;
end;
$$;

insert into catalog_ingest.sources(code, name, source_kind, retention_policy)
values
  ('google_books', 'Google Books', 'api', 'response_cache'),
  ('isbndb', 'ISBNdb', 'api', 'subscription_lifetime')
on conflict (code) do update set
  name = excluded.name,
  source_kind = excluded.source_kind,
  retention_policy = excluded.retention_policy;

insert into catalog_ingest.ingest_runs(source_id)
select id from catalog_ingest.sources where code = 'google_books';

insert into catalog_ingest.source_records(
  source_id,
  external_id,
  record_kind,
  raw_payload,
  last_ingest_run_id
)
select
  source.id,
  'shared-provider-id',
  'edition',
  '{"title":"Things Fall Apart"}'::jsonb,
  run.id
from catalog_ingest.sources as source
join catalog_ingest.ingest_runs as run on run.source_id = source.id
where source.code = 'google_books';

insert into catalog_ingest.source_records(source_id, external_id, record_kind, raw_payload)
select id, 'shared-provider-id', 'edition', '{"title":"Things Fall Apart"}'::jsonb
from catalog_ingest.sources
where code = 'isbndb';

insert into catalog_ingest.source_records(source_id, external_id, record_kind, raw_payload)
select id, 'shared-provider-id', 'edition', '{"title":"Things Fall Apart updated"}'::jsonb
from catalog_ingest.sources
where code = 'google_books'
on conflict (source_id, external_id) do update
set raw_payload = excluded.raw_payload,
    last_seen_at = now();

select pg_temp.assert_true(
  (select count(*) = 2 from catalog_ingest.source_records where external_id = 'shared-provider-id'),
  'provider IDs must be unique only inside a source'
);

do $$
begin
  begin
    insert into catalog_ingest.source_records(
      source_id,
      external_id,
      record_kind,
      last_ingest_run_id
    )
    select isbndb.id, 'wrong-run-source', 'work', run.id
    from catalog_ingest.sources as isbndb
    cross join catalog_ingest.ingest_runs as run
    where isbndb.code = 'isbndb';
    raise exception 'expected the ingest-run/source foreign key to reject this row';
  exception when foreign_key_violation then
    null;
  end;
end;
$$;

insert into catalog.work_groups(work_group_type) values ('book');

insert into catalog.works(work_group_id, work_kind, language_code, original_release_date)
select id, 'original', 'ig', date '1958-06-17' from catalog.work_groups;

insert into catalog.works(work_group_id, work_kind, language_code)
select id, 'translation', 'en' from catalog.work_groups;

insert into catalog.work_relations(source_work_id, work_group_id, relation, target_work_id)
select translated.id, translated.work_group_id, 'translation_of', original.id
from catalog.works as translated
join catalog.works as original
  on original.work_group_id = translated.work_group_id
where translated.language_code = 'en'
  and original.language_code = 'ig';

insert into catalog.work_titles(
  work_id,
  title,
  normalized_title,
  language_code,
  title_kind,
  is_preferred
)
select id, 'Things Fall Apart', 'things fall apart', language_code, 'primary', true
from catalog.works;

insert into catalog.contributors(contributor_kind) values ('person'), ('person');

insert into catalog.contributor_names(
  contributor_id,
  name,
  normalized_name,
  language_code,
  is_preferred
)
select id,
  case row_number() over (order by id) when 1 then 'Chinua Achebe' else 'Test Translator' end,
  case row_number() over (order by id) when 1 then 'chinua achebe' else 'test translator' end,
  'en',
  true
from catalog.contributors;

insert into catalog.work_contributions(work_id, contributor_id, role, position)
select work.id, contributor.id, 'author', 0
from catalog.works as work
join catalog.contributor_names as name on name.normalized_name = 'chinua achebe'
join catalog.contributors as contributor on contributor.id = name.contributor_id;

insert into catalog.work_contributions(work_id, contributor_id, role, position)
select work.id, contributor.id, 'translator', 1
from catalog.works as work
join catalog.contributor_names as name on name.normalized_name = 'test translator'
join catalog.contributors as contributor on contributor.id = name.contributor_id
where work.language_code = 'en';

insert into catalog.publishers(name, normalized_name)
values ('Anchor Books', 'anchor books');

insert into catalog.editions(
  title,
  normalized_title,
  publisher_id,
  product_form,
  publication_date,
  publication_date_precision,
  language_code,
  page_count,
  drm_policy
)
select
  'Things Fall Apart',
  'things fall apart',
  id,
  'ebook_epub',
  date '1994-09-01',
  'day',
  'en',
  224,
  'none'
from catalog.publishers;

insert into catalog.edition_works(edition_id, work_id, role)
select edition.id, work.id, 'primary'
from catalog.editions as edition
join catalog.works as work on work.language_code = 'en';

insert into catalog.identifiers(scheme_id, normalized_value)
select id, '9780385474542'
from catalog.identifier_schemes
where code = 'isbn_13';

insert into catalog.edition_identifier_claims(
  edition_id,
  identifier_id,
  source_record_id,
  raw_value,
  status,
  confidence
)
select edition.id, identifier.id, source_record.id, '978-0-385-47454-2', 'accepted', 1
from catalog.editions as edition
cross join catalog.identifiers as identifier
join catalog_ingest.source_records as source_record
  on source_record.external_id = 'shared-provider-id'
join catalog_ingest.sources as source
  on source.id = source_record.source_id and source.code = 'google_books';

select pg_temp.assert_true(
  (
    select count(*) = 1
    from catalog.identifier_schemes as scheme
    join catalog.identifiers as identifier on identifier.scheme_id = scheme.id
    join catalog.edition_identifier_claims as claim
      on claim.identifier_id = identifier.id and claim.status = 'accepted'
    where scheme.code = 'isbn_13'
      and identifier.normalized_value = '9780385474542'
  ),
  'an exact ISBN must resolve to the accepted edition claim'
);

insert into catalog.content_files(sha256, media_type, byte_size)
values (repeat('a', 64), 'application/epub+zip', 123456);

insert into catalog.content_locations(
  content_file_id,
  location_kind,
  storage_bucket,
  storage_path,
  status
)
select id, 'storage_object', 'catalog-books', 'public-domain/things-fall-apart.epub', 'active'
from catalog.content_files;

insert into catalog.edition_files(
  edition_id,
  content_file_id,
  file_role,
  rights_status,
  license_code
)
select edition.id, file.id, 'full_book', 'publisher_authorized', 'test-license'
from catalog.editions as edition
cross join catalog.content_files as file;

do $$
begin
  begin
    insert into catalog.content_locations(
      content_file_id,
      location_kind,
      storage_bucket,
      storage_path,
      external_url
    )
    select id, 'external_url', 'forbidden-bucket', 'forbidden-path', 'https://example.com/book.epub'
    from catalog.content_files;
    raise exception 'expected mutually exclusive content location fields';
  exception when check_violation then
    null;
  end;
end;
$$;

insert into catalog.cover_images(
  sha256,
  media_type,
  width,
  height,
  byte_size,
  status
)
values (repeat('b', 64), 'image/jpeg', 1000, 1600, 54321, 'verified');

insert into catalog.cover_locations(
  cover_image_id,
  location_kind,
  external_url,
  rights_status,
  status
)
select id, 'external_url', 'https://example.com/things-fall-apart.jpg', 'provider_display', 'active'
from catalog.cover_images;

insert into catalog.edition_covers(
  edition_id,
  cover_image_id,
  cover_role,
  market_code,
  priority,
  status
)
select edition.id, cover.id, 'front_cover', 'US', 1, 'selected'
from catalog.editions as edition
cross join catalog.cover_images as cover;

insert into catalog.cover_images(perceptual_hash, status)
values ('second-cover', 'candidate');

do $$
begin
  begin
    insert into catalog.edition_covers(
      edition_id,
      cover_image_id,
      cover_role,
      market_code,
      priority,
      status
    )
    select edition.id, cover.id, 'front_cover', 'US', 2, 'selected'
    from catalog.editions as edition
    join catalog.cover_images as cover on cover.perceptual_hash = 'second-cover';
    raise exception 'expected one selected cover per edition, role, and market';
  exception when unique_violation then
    null;
  end;
end;
$$;

insert into catalog.work_group_presentations(
  work_group_id,
  locale,
  preferred_work_id,
  preferred_edition_id,
  preferred_cover_location_id,
  selection_reason
)
select
  work.work_group_id,
  'en-US',
  work.id,
  edition.id,
  cover_location.id,
  'test fixture'
from catalog.works as work
cross join catalog.editions as edition
cross join catalog.cover_locations as cover_location
where work.language_code = 'en';

insert into catalog.search_documents(
  work_group_id,
  locale,
  display_work_id,
  display_edition_id,
  cover_location_id,
  display_title,
  normalized_title,
  contributor_names,
  translator_names,
  identifier_values,
  description,
  release_date,
  popularity_score,
  has_read_now,
  has_ebook
)
select
  work.work_group_id,
  'en-US',
  work.id,
  edition.id,
  cover_location.id,
  'Things Fall Apart',
  'things fall apart',
  'Chinua Achebe',
  'Test Translator',
  '9780385474542',
  'A novel about Okonkwo and a society under colonial pressure.',
  date '1958-06-17',
  100,
  true,
  true
from catalog.works as work
cross join catalog.editions as edition
cross join catalog.cover_locations as cover_location
where work.language_code = 'en';

select pg_temp.assert_true(
  (
    select count(*) = 1
    from catalog.search_documents
    where locale = 'en-US'
      and search_vector @@ websearch_to_tsquery('simple', 'Achebe translator')
  ),
  'the serving projection must search titles and contributors without graph joins'
);

insert into auth.users(id, email)
values
  ('11111111-1111-1111-1111-111111111111', 'owner@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'other@example.com');

insert into public.library_files(
  id,
  user_id,
  display_name,
  original_filename,
  media_type,
  byte_size,
  sha256,
  storage_path,
  status
)
values
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
    '11111111-1111-1111-1111-111111111111',
    'Imported scan',
    'scan.pdf',
    'application/pdf',
    1000,
    repeat('c', 64),
    '11111111-1111-1111-1111-111111111111/scan.pdf',
    'ready'
  ),
  (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',
    '11111111-1111-1111-1111-111111111111',
    'Catalog EPUB',
    'things-fall-apart.epub',
    'application/epub+zip',
    123456,
    repeat('a', 64),
    '11111111-1111-1111-1111-111111111111/catalog.epub',
    'ready'
  ),
  (
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1',
    '22222222-2222-2222-2222-222222222222',
    'Other user file',
    'other.pdf',
    'application/pdf',
    2000,
    repeat('d', 64),
    '22222222-2222-2222-2222-222222222222/other.pdf',
    'ready'
  );

insert into public.library_publication_catalog_matches(
  publication_id,
  user_id,
  work_group_id,
  match_level,
  match_method,
  confidence,
  evidence
)
select
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
  '11111111-1111-1111-1111-111111111111',
  id,
  'work_group',
  'metadata_inference',
  0.72,
  '{"signals":["title","author"]}'::jsonb
from catalog.work_groups;

insert into public.library_publication_catalog_matches(
  publication_id,
  user_id,
  work_group_id,
  work_id,
  edition_id,
  origin_content_file_id,
  match_level,
  match_method,
  confidence
)
select
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',
  '11111111-1111-1111-1111-111111111111',
  work.work_group_id,
  work.id,
  edition.id,
  file.id,
  'catalog_file',
  'catalog_acquisition',
  1
from catalog.works as work
cross join catalog.editions as edition
cross join catalog.content_files as file
where work.language_code = 'en';

insert into public.library_publication_catalog_matches(
  publication_id,
  user_id,
  work_group_id,
  match_level,
  match_method,
  confidence
)
select
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1',
  '22222222-2222-2222-2222-222222222222',
  id,
  'work_group',
  'manual',
  1
from catalog.work_groups;

select pg_temp.assert_true(
  not has_schema_privilege('authenticated', 'catalog', 'usage')
  and not has_schema_privilege('anon', 'catalog_ingest', 'usage')
  and has_schema_privilege('service_role', 'catalog', 'usage'),
  'canonical and ingest schemas must remain backend-private'
);

select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-1111-1111-111111111111',
  true
);
set local role authenticated;

select pg_temp.assert_true(
  (select count(*) = 2 from public.library_publication_catalog_matches),
  'RLS must expose only the signed-in user catalog matches'
);

reset role;

do $$
declare
  missing_indexes text;
begin
  select string_agg(format('%s.%s (%s)', namespace.nspname, relation.relname, constraint_row.conname), ', ')
  into missing_indexes
  from pg_constraint as constraint_row
  join pg_class as relation on relation.oid = constraint_row.conrelid
  join pg_namespace as namespace on namespace.oid = relation.relnamespace
  where constraint_row.contype = 'f'
    and (
      namespace.nspname in ('catalog', 'catalog_ingest')
      or (
        namespace.nspname = 'public'
        and relation.relname in (
          'library_publication_catalog_matches',
          'catalog_provider_interests'
        )
      )
    )
    and not exists (
      select 1
      from pg_index as index_row
      where index_row.indrelid = constraint_row.conrelid
        and index_row.indisvalid
        and (index_row.indkey::smallint[])[0:cardinality(constraint_row.conkey) - 1]
          = constraint_row.conkey
    );

  if missing_indexes is not null then
    raise exception 'foreign keys without a left-prefix index: %', missing_indexes;
  end if;
end;
$$;

rollback;

select 'catalog foundation integrity passed' as result;
