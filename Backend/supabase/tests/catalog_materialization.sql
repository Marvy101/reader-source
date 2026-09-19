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

select pg_temp.assert_true(
  (
    select not public
      and file_size_limit = 52428800
      and allowed_mime_types = array[
        'application/epub+zip',
        'application/pdf',
        'text/plain'
      ]::text[]
    from storage.buckets
    where id = 'reader-catalog-files'
  ),
  'catalog files must use a private, format-restricted bucket'
);

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
        "application/epub+zip": "https://www.gutenberg.org/ebooks/1342.epub3.images"
      }
    }
  ]'::jsonb
);

select pg_temp.assert_true(
  (
    select count(*) = 1
    from public.catalog_materialization_candidates('project_gutenberg', 0, 10)
    where external_id = 'gutenberg:1342'
      and media_type = 'application/epub+zip'
  ),
  'a Gutenberg EPUB offer must become a materialization candidate'
);

select public.catalog_register_materialized_file(
  (
    select offer_id
    from public.catalog_materialization_candidates('project_gutenberg', 0, 10)
    limit 1
  ),
  repeat('a', 64),
  'application/epub+zip',
  1024,
  'reader-catalog-files',
  'project_gutenberg/gutenberg-1342/' || repeat('a', 64) || '.epub',
  'public_domain',
  'US-PD',
  array['US']
);

select pg_temp.assert_true(
  (
    select count(*) = 0
    from public.catalog_materialization_candidates('project_gutenberg', 0, 10)
  ),
  'a stored full-book file must not be offered for materialization again'
);

select pg_temp.assert_true(
  (
    select count(*) = 1
    from public.catalog_resolve_materialized_files(
      array[(select id from catalog.editions where title = 'Pride and Prejudice')],
      'US'
    )
    where storage_bucket = 'reader-catalog-files'
      and media_type = 'application/epub+zip'
      and byte_size = 1024
  ),
  'a US request must resolve a US public-domain stored file'
);

select pg_temp.assert_true(
  (
    select count(*) = 0
    from public.catalog_resolve_materialized_files(
      array[(select id from catalog.editions where title = 'Pride and Prejudice')],
      'NG'
    )
  ),
  'a territory-restricted file must not resolve outside its allowed territory'
);

select public.catalog_register_materialized_file(
  (
    select offer.id
    from catalog.acquisition_offers as offer
    limit 1
  ),
  repeat('a', 64),
  'application/epub+zip',
  1024,
  'reader-catalog-files',
  'project_gutenberg/gutenberg-1342/' || repeat('a', 64) || '.epub',
  'public_domain',
  'US-PD',
  array['US']
);

select pg_temp.assert_true(
  (select count(*) = 1 from catalog.content_files),
  'retrying materialized registration must not duplicate immutable content'
);
select pg_temp.assert_true(
  (select count(*) = 1 from catalog.content_locations),
  'retrying materialized registration must not duplicate storage locations'
);
select pg_temp.assert_true(
  (select count(*) = 1 from catalog.edition_files),
  'retrying materialized registration must not duplicate edition assignments'
);

reset role;
set local role authenticated;

do $$
begin
  begin
    perform public.catalog_materialization_candidates('project_gutenberg', 0, 10);
    raise exception 'expected materialization RPC to reject authenticated users';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

reset role;
rollback;

select 'catalog file materialization passed' as result;
