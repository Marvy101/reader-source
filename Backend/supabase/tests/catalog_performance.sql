begin;

select set_config('catalog_test.rows', :'catalog_benchmark_rows', true);

create temporary table perf_work_groups(work_group_id bigint primary key);

with inserted as (
  insert into catalog.work_groups(work_group_type)
  select 'book'
  from generate_series(1, current_setting('catalog_test.rows')::integer)
  returning id
)
insert into perf_work_groups select id from inserted;

insert into catalog.works(work_group_id, work_kind, language_code)
select work_group_id, 'original', 'en' from perf_work_groups;

insert into catalog.editions(
  title,
  normalized_title,
  product_form,
  language_code,
  publication_date,
  publication_date_precision
)
select
  'Performance Book ' || work_group_id,
  'performance book ' || work_group_id,
  'ebook_epub',
  'en',
  date '2000-01-01' + ((work_group_id % 9000)::integer),
  'day'
from perf_work_groups;

insert into catalog.edition_works(edition_id, work_id, role)
select edition.id, work.id, 'primary'
from catalog.works as work
join catalog.editions as edition
  on edition.normalized_title = 'performance book ' || work.work_group_id
where work.work_group_id in (select work_group_id from perf_work_groups);

insert into catalog.search_documents(
  work_group_id,
  locale,
  display_work_id,
  display_edition_id,
  display_title,
  normalized_title,
  contributor_names,
  subject_names,
  popularity_score,
  has_ebook
)
select
  work.work_group_id,
  'en-US',
  work.id,
  edition.id,
  edition.title,
  edition.normalized_title,
  'Performance Author ' || work.work_group_id,
  case when work.work_group_id % 10 = 0 then 'history africa' else 'fiction' end,
  work.work_group_id,
  true
from catalog.works as work
join catalog.editions as edition
  on edition.normalized_title = 'performance book ' || work.work_group_id
where work.work_group_id in (select work_group_id from perf_work_groups);

insert into catalog.identifiers(scheme_id, normalized_value)
select scheme.id, lpad(work_group_id::text, 13, '0')
from perf_work_groups
cross join catalog.identifier_schemes as scheme
where scheme.code = 'isbn_13';

insert into catalog.edition_identifier_claims(
  edition_id,
  identifier_id,
  status,
  confidence
)
select edition.id, identifier.id, 'accepted', 1
from catalog.editions as edition
join catalog.identifiers as identifier
  on identifier.normalized_value = lpad(
    replace(edition.normalized_title, 'performance book ', '')::bigint::text,
    13,
    '0'
  )
where edition.normalized_title like 'performance book %';

analyze catalog.work_groups;
analyze catalog.works;
analyze catalog.editions;
analyze catalog.edition_works;
analyze catalog.identifiers;
analyze catalog.edition_identifier_claims;
analyze catalog.search_documents;

do $$
declare
  plan json;
  plan_text text;
begin
  execute $query$
    explain (format json)
    select document.work_group_id
    from catalog.search_documents as document
    where document.locale = 'en-US'
      and document.normalized_title like 'performance book 49999%'
    order by extensions.similarity(document.normalized_title, 'performance book 49999') desc
    limit 20
  $query$ into plan;
  plan_text := plan::text;
  if plan_text not like '%search_documents_locale_title_prefix%' then
    raise exception 'prefix typeahead missed its index: %', plan_text;
  end if;

  execute $query$
    explain (format json)
    select document.work_group_id
    from catalog.search_documents as document
    where document.locale = 'en-US'
      and document.normalized_title ilike '%49999%'
    limit 20
  $query$ into plan;
  plan_text := plan::text;
  if plan_text not like '%search_documents_title_trgm%' then
    raise exception 'trigram fallback missed its index: %', plan_text;
  end if;

  execute $query$
    explain (format json)
    select claim.edition_id
    from catalog.identifier_schemes as scheme
    join catalog.identifiers as identifier on identifier.scheme_id = scheme.id
    join catalog.edition_identifier_claims as claim
      on claim.identifier_id = identifier.id and claim.status = 'accepted'
    where scheme.code = 'isbn_13'
      and identifier.normalized_value = '0000000049999'
  $query$ into plan;
  plan_text := plan::text;
  if plan_text not like '%identifiers_scheme_id_normalized_value_key%'
    or plan_text not like '%edition_identifier_claims_lookup%'
  then
    raise exception 'exact identifier resolution missed a hot index: %', plan_text;
  end if;

  execute $query$
    explain (format json)
    select document.work_group_id
    from catalog.search_documents as document
    where document.locale = 'en-US'
      and document.search_vector @@ websearch_to_tsquery('simple', 'history africa')
    order by ts_rank_cd(
      document.search_vector,
      websearch_to_tsquery('simple', 'history africa')
    ) desc
    limit 20
  $query$ into plan;
  plan_text := plan::text;
  if plan_text not like '%search_documents_full_text%' then
    raise exception 'full-text search missed its GIN index: %', plan_text;
  end if;
end;
$$;

create temporary table perf_timings(
  path text not null,
  elapsed_milliseconds double precision not null
);

do $$
declare
  started_at timestamptz;
  lookup_value text;
begin
  for sample in 1..250 loop
    lookup_value := lpad(
      (
        1 + (
          (sample * 197)
          % current_setting('catalog_test.rows')::integer
        )
      )::text,
      13,
      '0'
    );
    started_at := clock_timestamp();
    perform claim.edition_id
    from catalog.identifier_schemes as scheme
    join catalog.identifiers as identifier on identifier.scheme_id = scheme.id
    join catalog.edition_identifier_claims as claim
      on claim.identifier_id = identifier.id and claim.status = 'accepted'
    where scheme.code = 'isbn_13'
      and identifier.normalized_value = lookup_value;
    insert into perf_timings values (
      'exact_isbn',
      extract(epoch from (clock_timestamp() - started_at)) * 1000
    );
  end loop;

  for sample in 1..100 loop
    lookup_value := 'performance book ' || (
      1 + (
        (sample * 499)
        % current_setting('catalog_test.rows')::integer
      )
    );
    started_at := clock_timestamp();
    perform document.work_group_id
    from catalog.search_documents as document
    where document.locale = 'en-US'
      and document.normalized_title like lookup_value || '%'
    order by extensions.similarity(document.normalized_title, lookup_value) desc
    limit 20;
    insert into perf_timings values (
      'title_prefix',
      extract(epoch from (clock_timestamp() - started_at)) * 1000
    );
  end loop;
end;
$$;

select
  path,
  count(*) as samples,
  round(percentile_cont(0.50) within group (order by elapsed_milliseconds)::numeric, 3) as p50_ms,
  round(percentile_cont(0.95) within group (order by elapsed_milliseconds)::numeric, 3) as p95_ms,
  round(max(elapsed_milliseconds)::numeric, 3) as max_ms
from perf_timings
group by path
order by path;

rollback;

select format(
  'catalog %s-row query-plan benchmark passed',
  :'catalog_benchmark_rows'::integer
) as result;
