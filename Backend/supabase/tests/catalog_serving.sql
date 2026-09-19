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

insert into auth.users(id, email)
values
  ('22222222-2222-2222-2222-222222222222', 'catalog@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'other@example.com');

set role service_role;

select public.catalog_ingest_gutenberg(
  '[
    {
      "id": 1342,
      "title": "Pride and Prejudice",
      "authors": [{"name": "Austen, Jane", "birth_year": 1775, "death_year": 1817}],
      "languages": ["en"],
      "download_count": 1000,
      "formats": {
        "application/epub+zip": "https://www.gutenberg.org/ebooks/1342.epub3.images",
        "image/jpeg": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg"
      }
    },
    {
      "id": 2701,
      "title": "Moby Dick; Or, The Whale",
      "authors": [{"name": "Melville, Herman", "birth_year": 1819, "death_year": 1891}],
      "languages": ["en"],
      "download_count": 900,
      "formats": {
        "application/epub+zip": "https://www.gutenberg.org/ebooks/2701.epub3.images",
        "image/jpeg": "https://www.gutenberg.org/cache/epub/2701/pg2701.cover.medium.jpg"
      }
    },
    {
      "id": 900001,
      "title": "Catalog Homonym Fixture One",
      "authors": [{"name": "Smith, Alex", "birth_year": 1900, "death_year": 1970}],
      "languages": ["en"],
      "download_count": 1,
      "formats": {}
    },
    {
      "id": 900002,
      "title": "Catalog Homonym Fixture Two",
      "authors": [{"name": "Smith, Alex", "birth_year": 1950}],
      "languages": ["en"],
      "download_count": 1,
      "formats": {}
    }
  ]'::jsonb
);

select public.catalog_ingest_gutenberg(
  '[
    {
      "id": 1342,
      "title": "Pride and Prejudice",
      "authors": [{"name": "Austen, Jane", "birth_year": 1775, "death_year": 1817}],
      "languages": ["en"],
      "download_count": 1001,
      "formats": {
        "application/epub+zip": "https://www.gutenberg.org/ebooks/1342.epub3.images",
        "image/jpeg": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg"
      }
    }
  ]'::jsonb
);

select pg_temp.assert_true(
  (
    select count(*) = 4
    from catalog_ingest.source_records
    where record_kind = 'edition'
  ),
  'retrying a Gutenberg record must not duplicate the provider record'
);
select pg_temp.assert_true(
  (
    select count(*) = 1
    from catalog.contributor_names
    where normalized_name = 'austen, jane'
  ),
  'retrying an author with the same source identity must not duplicate them'
);
select pg_temp.assert_true(
  (
    select count(*) = 2
    from catalog.contributor_names
    where normalized_name = 'smith, alex'
  ),
  'contributors with the same name and different life dates must remain distinct'
);
select pg_temp.assert_true(
  (select count(*) = 4 from catalog.work_groups),
  'four Gutenberg books must create four canonical groups'
);

select public.catalog_ingest_gutenberg(
  '[
    {
      "id": 42671,
      "title": "Pride and Prejudice",
      "authors": [{"name": "Austen, Jane", "birth_year": 1775, "death_year": 1817}],
      "languages": ["en"],
      "download_count": 10,
      "formats": {
        "application/epub+zip": "https://www.gutenberg.org/ebooks/42671.epub3.images",
        "image/jpeg": "https://www.gutenberg.org/cache/epub/42671/pg42671.cover.medium.jpg"
      }
    }
  ]'::jsonb
);

select pg_temp.assert_true(
  (select count(*) = 4 from catalog.work_groups),
  'duplicate provider editions must share the existing canonical work group'
);
select pg_temp.assert_true(
  (select count(*) = 5 from catalog.editions),
  'duplicate provider records remain separately traceable editions'
);
select pg_temp.assert_true(
  (
    select count(distinct match.work_id) = 1
    from catalog_ingest.source_records as record
    join catalog_ingest.source_work_matches as match
      on match.source_record_id = record.id
      and match.match_status = 'accepted'
    where record.external_id in ('gutenberg:1342', 'gutenberg:42671')
  ),
  'exact provider title, credits, and language must resolve to one work'
);
select pg_temp.assert_true(
  (
    select count(*) = 1
    from public.catalog_search(
      'pride',
      'en-US',
      '22222222-2222-2222-2222-222222222222',
      20
    )
    where title = 'Pride and Prejudice'
      and authors = 'Austen, Jane'
      and availability = 'read_now'
      and download_url = 'https://www.gutenberg.org/ebooks/1342.epub3.images'
      and cover_url = 'https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg'
  ),
  'catalog search must return only the best free Gutenberg edition and its assets'
);
select pg_temp.assert_true(
  (
    select count(*) = 1
    from public.catalog_search(
      'pride',
      'en-NG',
      '22222222-2222-2222-2222-222222222222',
      20
    )
    where title = 'Pride and Prejudice'
  ),
  'catalog search must fall back to English results for a regional locale'
);

reset role;

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
) values (
  '44444444-4444-4444-4444-444444444444',
  '22222222-2222-2222-2222-222222222222',
  'Pride and Prejudice',
  'pride-and-prejudice.epub',
  'application/epub+zip',
  100,
  repeat('c', 64),
  '22222222-2222-2222-2222-222222222222/44444444-4444-4444-4444-444444444444/book.epub',
  'ready'
);

set role service_role;

insert into public.library_publication_catalog_matches(
  publication_id,
  user_id,
  work_group_id,
  work_id,
  edition_id,
  match_level,
  match_method,
  confidence,
  evidence
)
select
  '44444444-4444-4444-4444-444444444444',
  '22222222-2222-2222-2222-222222222222',
  document.work_group_id,
  document.display_work_id,
  document.display_edition_id,
  'edition',
  'catalog_offer',
  1,
  '{"source":"test"}'::jsonb
from catalog.search_documents as document
where document.display_title = 'Pride and Prejudice';

select pg_temp.assert_true(
  (
    select count(*) = 1
    from public.catalog_search(
      'pride',
      'en-US',
      '22222222-2222-2222-2222-222222222222',
      20
    )
    where availability = 'in_library'
      and library_publication_id = '44444444-4444-4444-4444-444444444444'
  ),
  'a matched local publication must take precedence over read-now availability'
);

reset role;

set local role service_role;

select public.catalog_register_provider_interest(
  '22222222-2222-2222-2222-222222222222',
  'google_books',
  'google-volume-id',
  'Recent Book',
  'A. Writer',
  'isbn:9781234567890',
  false
);
select public.catalog_register_provider_interest(
  '22222222-2222-2222-2222-222222222222',
  'google_books',
  'google-volume-id',
  'Recent Book, Revised Metadata',
  'A. Writer',
  'isbn:9781234567890',
  true
);

select pg_temp.assert_true(
  (
    select count(*) = 1
      and bool_and(email_opt_in)
      and bool_and(title = 'Recent Book, Revised Metadata')
    from public.catalog_provider_interests
    where user_id = '22222222-2222-2222-2222-222222222222'
  ),
  'provider interest must be idempotent and retain explicit email opt-in'
);

reset role;
select set_config(
  'catalog_test.moby_group',
  (
    select document.work_group_id::text
    from catalog.search_documents as document
    where document.display_title = 'Moby Dick; Or, The Whale'
  ),
  true
);
select set_config(
  'catalog_test.pride_group',
  (
    select document.work_group_id::text
    from catalog.search_documents as document
    where document.display_title = 'Pride and Prejudice'
  ),
  true
);
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
set local role authenticated;

insert into public.catalog_interests(user_id, work_group_id, email_opt_in)
values (
  '22222222-2222-2222-2222-222222222222',
  current_setting('catalog_test.moby_group')::bigint,
  true
);

select pg_temp.assert_true(
  (select count(*) = 1 from public.catalog_interests),
  'a user must be able to register catalog interest for their own account'
);

select pg_temp.assert_true(
  (select count(*) = 1 from public.catalog_provider_interests),
  'RLS must expose the signed-in user provider interest'
);

select pg_temp.assert_true(
  not has_function_privilege(
    'authenticated',
    'public.catalog_register_provider_interest(uuid,text,text,text,text,text,boolean)',
    'execute'
  ),
  'provider interest registration must remain service-only'
);

do $$
begin
  begin
    insert into public.catalog_interests(user_id, work_group_id)
    values (
      '33333333-3333-3333-3333-333333333333',
      current_setting('catalog_test.pride_group')::bigint
    );
    raise exception 'expected interest RLS to reject another user';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

reset role;
rollback;

select 'catalog serving and Gutenberg ingestion passed' as result;
