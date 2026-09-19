alter table public.library_publication_catalog_matches
  drop constraint library_publication_catalog_matches_match_method_check;

alter table public.library_publication_catalog_matches
  add constraint library_publication_catalog_matches_match_method_check
  check (
    match_method in (
      'catalog_acquisition',
      'catalog_offer',
      'embedded_identifier',
      'metadata_inference',
      'manual'
    )
  );

create table public.catalog_interests (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  work_group_id bigint not null references catalog.work_groups(id) on delete cascade,
  email_opt_in boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, work_group_id)
);

create index catalog_interests_demand_report
  on public.catalog_interests(work_group_id, active, created_at desc, user_id);
create index catalog_interests_user_active
  on public.catalog_interests(user_id, active, updated_at desc);

create trigger catalog_interests_set_updated_at
before update on public.catalog_interests
for each row execute function public.set_updated_at();

alter table public.catalog_interests enable row level security;

create policy catalog_interests_manage_own
on public.catalog_interests for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.catalog_interests
  to authenticated, service_role;
grant usage, select on sequence public.catalog_interests_id_seq
  to authenticated, service_role;
grant usage on schema extensions to service_role;

create or replace function public.catalog_search(
  p_query text,
  p_locale text default 'en-US',
  p_user_id uuid default null,
  p_limit integer default 20
)
returns table (
  work_group_id bigint,
  work_id bigint,
  edition_id bigint,
  title text,
  subtitle text,
  authors text,
  translators text,
  publisher text,
  release_year integer,
  page_count integer,
  description text,
  cover_url text,
  primary_identifier text,
  availability text,
  library_publication_id uuid,
  download_url text,
  download_media_type text,
  relevance double precision
)
language sql
stable
security invoker
set search_path = ''
as $$
  with input as (
    select
      lower(regexp_replace(btrim(p_query), '\s+', ' ', 'g')) as normalized_query,
      replace(coalesce(nullif(btrim(p_locale), ''), 'en-US'), '_', '-') as requested_locale,
      split_part(
        replace(coalesce(nullif(btrim(p_locale), ''), 'en-US'), '_', '-'),
        '-',
        1
      ) as requested_language,
      greatest(1, least(coalesce(p_limit, 20), 50)) as result_limit
  ),
  candidates as (
    select document.work_group_id,
      1000::double precision + extensions.similarity(
        document.normalized_title,
        input.normalized_query
      ) + case
        when document.locale = input.requested_locale then 20
        when document.locale = input.requested_language then 10
        else 0
      end as score
    from catalog.search_documents as document
    cross join input
    where document.locale in (
        input.requested_locale,
        input.requested_language,
        'en-US'
      )
      and input.normalized_query <> ''
      and document.normalized_title like input.normalized_query || '%'

    union all

    select document.work_group_id,
      700::double precision + ts_rank_cd(
        document.search_vector,
        websearch_to_tsquery('simple', input.normalized_query)
      )::double precision + case
        when document.locale = input.requested_locale then 20
        when document.locale = input.requested_language then 10
        else 0
      end as score
    from catalog.search_documents as document
    cross join input
    where document.locale in (
        input.requested_locale,
        input.requested_language,
        'en-US'
      )
      and input.normalized_query <> ''
      and document.search_vector @@ websearch_to_tsquery(
        'simple',
        input.normalized_query
      )

    union all

    select document.work_group_id,
      400::double precision + extensions.similarity(
        document.normalized_title,
        input.normalized_query
      ) + case
        when document.locale = input.requested_locale then 20
        when document.locale = input.requested_language then 10
        else 0
      end as score
    from catalog.search_documents as document
    cross join input
    where document.locale in (
        input.requested_locale,
        input.requested_language,
        'en-US'
      )
      and char_length(input.normalized_query) >= 3
      and document.normalized_title OPERATOR(extensions.%) input.normalized_query

    union all

    select document.work_group_id, 2000::double precision as score
    from catalog.identifier_schemes as scheme
    join catalog.identifiers as identifier on identifier.scheme_id = scheme.id
    join catalog.edition_identifier_claims as claim
      on claim.identifier_id = identifier.id
      and claim.status = 'accepted'
    join catalog.edition_works as edition_work
      on edition_work.edition_id = claim.edition_id
      and edition_work.role = 'primary'
    join catalog.works as work on work.id = edition_work.work_id
    join catalog.search_documents as document
      on document.work_group_id = work.work_group_id
    cross join input
    where document.locale in (
        input.requested_locale,
        input.requested_language,
        'en-US'
      )
      and identifier.normalized_value = regexp_replace(
      input.normalized_query,
      '[^a-z0-9]',
      '',
      'g'
    )
  ),
  ranked as (
    select candidate.work_group_id, max(candidate.score) as score
    from candidates as candidate
    group by candidate.work_group_id
    order by max(candidate.score) desc, candidate.work_group_id
    limit (select result_limit from input)
  )
  select
    document.work_group_id,
    document.display_work_id,
    document.display_edition_id,
    document.display_title,
    document.subtitle,
    document.contributor_names,
    document.translator_names,
    publisher.name,
    extract(year from document.release_date)::integer,
    edition.page_count,
    document.description,
    cover.external_url,
    identifier.value,
    case
      when library_match.publication_id is not null then 'in_library'
      when offer.url is not null then 'read_now'
      when document.has_ebook then 'add_own_file'
      else 'notify_me'
    end,
    library_match.publication_id,
    offer.url,
    offer.media_type,
    ranked.score
  from ranked
  cross join input
  join lateral (
    select candidate_document.*
    from catalog.search_documents as candidate_document
    where candidate_document.work_group_id = ranked.work_group_id
      and candidate_document.locale in (
        input.requested_locale,
        input.requested_language,
        'en-US'
      )
    order by
      case
        when candidate_document.locale = input.requested_locale then 0
        when candidate_document.locale = input.requested_language then 1
        else 2
      end,
      candidate_document.work_group_id
    limit 1
  ) as document on true
  left join catalog.editions as edition on edition.id = document.display_edition_id
  left join catalog.publishers as publisher on publisher.id = edition.publisher_id
  left join catalog.cover_locations as cover
    on cover.id = document.cover_location_id
    and cover.status = 'active'
  left join lateral (
    select
      coalesce(scheme.code || ':' || identifier.normalized_value, '') as value
    from catalog.edition_identifier_claims as claim
    join catalog.identifiers as identifier on identifier.id = claim.identifier_id
    join catalog.identifier_schemes as scheme on scheme.id = identifier.scheme_id
    where claim.edition_id = document.display_edition_id
      and claim.status = 'accepted'
    order by
      case scheme.code when 'isbn_13' then 0 when 'isbn_10' then 1 else 2 end,
      claim.confidence desc,
      identifier.id
    limit 1
  ) as identifier on true
  left join lateral (
    select match.publication_id
    from public.library_publication_catalog_matches as match
    where match.user_id = p_user_id
      and match.work_group_id = document.work_group_id
    order by match.matched_at desc
    limit 1
  ) as library_match on true
  left join lateral (
    select acquisition.url, acquisition.media_type
    from catalog.acquisition_offers as acquisition
    where acquisition.edition_id = document.display_edition_id
      and acquisition.offer_kind = 'open_access'
      and acquisition.available
      and (
        acquisition.valid_until is null
        or acquisition.valid_until > now()
      )
    order by acquisition.checked_at desc, acquisition.id
    limit 1
  ) as offer on true
  order by ranked.score desc, document.popularity_score desc, document.work_group_id;
$$;

revoke execute on function public.catalog_search(text, text, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.catalog_search(text, text, uuid, integer)
  to service_role;

create or replace function public.catalog_ingest_gutenberg(p_books jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  source_id_value bigint;
  run_id_value bigint;
  record_id_value bigint;
  group_id_value bigint;
  work_id_value bigint;
  edition_id_value bigint;
  contributor_record_id_value bigint;
  contributor_id_value bigint;
  cover_image_id_value bigint;
  cover_location_id_value bigint;
  book jsonb;
  author jsonb;
  external_id_value text;
  title_value text;
  normalized_title_value text;
  language_value text;
  authors_value text;
  author_name_value text;
  normalized_author_value text;
  contributor_external_id_value text;
  epub_url_value text;
  cover_url_value text;
  processed integer := 0;
begin
  if jsonb_typeof(p_books) <> 'array' then
    raise exception 'p_books must be a JSON array';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('reader.catalog_ingest_gutenberg')
  );

  insert into catalog_ingest.sources(
    code,
    name,
    source_kind,
    base_url,
    terms_url,
    retention_policy,
    trust_priority
  ) values (
    'project_gutenberg',
    'Project Gutenberg',
    'api',
    'https://www.gutenberg.org/',
    'https://www.gutenberg.org/policy/permission.html',
    'persistent',
    20
  )
  on conflict (code) do update set
    enabled = true,
    updated_at = now()
  returning id into source_id_value;

  insert into catalog_ingest.ingest_runs(source_id)
  values (source_id_value)
  returning id into run_id_value;

  for book in select value from jsonb_array_elements(p_books)
  loop
    external_id_value := 'gutenberg:' || nullif(book->>'id', '');
    title_value := nullif(btrim(book->>'title'), '');
    if external_id_value is null or title_value is null then
      continue;
    end if;

    normalized_title_value := lower(
      regexp_replace(title_value, '\s+', ' ', 'g')
    );
    language_value := coalesce(
      nullif(book->'languages'->>0, ''),
      'und'
    );
    epub_url_value := coalesce(
      nullif(book->'formats'->>'application/epub+zip', ''),
      nullif(book->'formats'->>'application/epub+zip; charset=utf-8', '')
    );
    cover_url_value := nullif(book->'formats'->>'image/jpeg', '');
    select string_agg(nullif(btrim(value->>'name'), ''), ', ' order by ordinality)
    into authors_value
    from jsonb_array_elements(coalesce(book->'authors', '[]'::jsonb))
      with ordinality as author_values(value, ordinality);

    insert into catalog_ingest.source_records(
      source_id,
      external_id,
      record_kind,
      raw_payload,
      last_ingest_run_id,
      last_seen_at,
      status
    ) values (
      source_id_value,
      external_id_value,
      'edition',
      book,
      run_id_value,
      now(),
      'active'
    )
    on conflict (source_id, external_id) do update set
      raw_payload = excluded.raw_payload,
      last_ingest_run_id = excluded.last_ingest_run_id,
      last_seen_at = excluded.last_seen_at,
      status = 'active'
    returning id into record_id_value;

    select match.work_id, work.work_group_id
    into work_id_value, group_id_value
    from catalog_ingest.source_work_matches as match
    join catalog.works as work on work.id = match.work_id
    where match.source_record_id = record_id_value
      and match.match_status = 'accepted';

    if work_id_value is null then
      insert into catalog.work_groups(work_group_type)
      values ('book')
      returning id into group_id_value;

      insert into catalog.works(work_group_id, work_kind, language_code)
      values (group_id_value, 'original', language_value)
      returning id into work_id_value;

      insert into catalog_ingest.source_work_matches(
        source_record_id,
        work_id,
        match_status,
        match_method,
        confidence,
        resolver_version
      ) values (
        record_id_value,
        work_id_value,
        'accepted',
        'provider_stable_id',
        1,
        1
      );
    end if;

    update catalog.work_titles
    set title = title_value,
        normalized_title = normalized_title_value,
        language_code = language_value
    where work_id = work_id_value and is_preferred;
    if not found then
      insert into catalog.work_titles(
        work_id,
        title,
        normalized_title,
        language_code,
        title_kind,
        is_preferred,
        source_record_id
      ) values (
        work_id_value,
        title_value,
        normalized_title_value,
        language_value,
        'primary',
        true,
        record_id_value
      );
    end if;

    for author in select value from jsonb_array_elements(
      coalesce(book->'authors', '[]'::jsonb)
    )
    loop
      author_name_value := nullif(btrim(author->>'name'), '');
      if author_name_value is null then
        continue;
      end if;
      normalized_author_value := lower(
        regexp_replace(author_name_value, '\s+', ' ', 'g')
      );
      contributor_external_id_value := 'gutenberg:contributor:' || md5(
        normalized_author_value || '|' ||
        coalesce(author->>'birth_year', '') || '|' ||
        coalesce(author->>'death_year', '')
      );
      insert into catalog_ingest.source_records(
        source_id,
        external_id,
        record_kind,
        raw_payload,
        last_ingest_run_id,
        last_seen_at,
        status
      ) values (
        source_id_value,
        contributor_external_id_value,
        'contributor',
        author,
        run_id_value,
        now(),
        'active'
      ) on conflict (source_id, external_id) do update set
        raw_payload = excluded.raw_payload,
        last_ingest_run_id = excluded.last_ingest_run_id,
        last_seen_at = excluded.last_seen_at,
        status = 'active'
      returning id into contributor_record_id_value;

      select match.contributor_id
      into contributor_id_value
      from catalog_ingest.source_contributor_matches as match
      where match.source_record_id = contributor_record_id_value
        and match.match_status = 'accepted';
      if contributor_id_value is null then
        insert into catalog.contributors(contributor_kind)
        values ('person')
        returning id into contributor_id_value;
        insert into catalog.contributor_names(
          contributor_id,
          name,
          normalized_name,
          language_code,
          is_preferred,
          source_record_id
        ) values (
          contributor_id_value,
          author_name_value,
          normalized_author_value,
          language_value,
          true,
          contributor_record_id_value
        );
        insert into catalog_ingest.source_contributor_matches(
          source_record_id,
          contributor_id,
          match_status,
          match_method,
          confidence,
          resolver_version
        ) values (
          contributor_record_id_value,
          contributor_id_value,
          'accepted',
          'provider_stable_id',
          1,
          1
        );
      end if;
      insert into catalog.work_contributions(
        work_id,
        contributor_id,
        role,
        position,
        source_record_id
      ) values (
        work_id_value,
        contributor_id_value,
        'author',
        0,
        record_id_value
      ) on conflict do nothing;
    end loop;

    select match.edition_id
    into edition_id_value
    from catalog_ingest.source_edition_matches as match
    where match.source_record_id = record_id_value
      and match.match_status = 'accepted';

    if edition_id_value is null then
      insert into catalog.editions(
        title,
        normalized_title,
        product_form,
        language_code,
        drm_policy
      ) values (
        title_value,
        normalized_title_value,
        'ebook_epub',
        language_value,
        'none'
      ) returning id into edition_id_value;

      insert into catalog.edition_works(edition_id, work_id, role)
      values (edition_id_value, work_id_value, 'primary');

      insert into catalog_ingest.source_edition_matches(
        source_record_id,
        edition_id,
        match_status,
        match_method,
        confidence,
        resolver_version
      ) values (
        record_id_value,
        edition_id_value,
        'accepted',
        'provider_stable_id',
        1,
        1
      );
    else
      update catalog.editions
      set title = title_value,
          normalized_title = normalized_title_value,
          language_code = language_value,
          drm_policy = 'none'
      where id = edition_id_value;
    end if;

    cover_location_id_value := null;
    if cover_url_value is not null then
      select location.id
      into cover_location_id_value
      from catalog.cover_locations as location
      where location.external_url = cover_url_value;
      if cover_location_id_value is null then
        insert into catalog.cover_images(media_type, status)
        values ('image/jpeg', 'verified')
        returning id into cover_image_id_value;
        insert into catalog.cover_locations(
          cover_image_id,
          source_record_id,
          location_kind,
          external_url,
          rights_status,
          status,
          last_verified_at
        ) values (
          cover_image_id_value,
          record_id_value,
          'external_url',
          cover_url_value,
          'public_domain',
          'active',
          now()
        ) returning id into cover_location_id_value;
      else
        select location.cover_image_id
        into cover_image_id_value
        from catalog.cover_locations as location
        where location.id = cover_location_id_value;
      end if;
      insert into catalog.edition_covers(
        edition_id,
        cover_image_id,
        source_record_id,
        cover_role,
        priority,
        status
      ) values (
        edition_id_value,
        cover_image_id_value,
        record_id_value,
        'front_cover',
        10,
        'selected'
      ) on conflict do nothing;
    end if;

    if epub_url_value is not null then
      insert into catalog.acquisition_offers(
        edition_id,
        source_record_id,
        offer_kind,
        url,
        media_type,
        available,
        checked_at
      ) values (
        edition_id_value,
        record_id_value,
        'open_access',
        epub_url_value,
        'application/epub+zip',
        true,
        now()
      ) on conflict (source_record_id, offer_kind, url) do update set
        available = true,
        checked_at = excluded.checked_at,
        media_type = excluded.media_type;
    end if;

    insert into catalog.work_group_presentations(
      work_group_id,
      locale,
      preferred_work_id,
      preferred_edition_id,
      preferred_cover_location_id,
      selection_reason
    ) values (
      group_id_value,
      'en-US',
      work_id_value,
      edition_id_value,
      cover_location_id_value,
      'Project Gutenberg public-domain edition'
    ) on conflict (work_group_id, locale) do update set
      preferred_work_id = excluded.preferred_work_id,
      preferred_edition_id = excluded.preferred_edition_id,
      preferred_cover_location_id = excluded.preferred_cover_location_id,
      selection_reason = excluded.selection_reason,
      updated_at = now();

    insert into catalog.search_documents(
      work_group_id,
      locale,
      display_work_id,
      display_edition_id,
      cover_location_id,
      display_title,
      normalized_title,
      contributor_names,
      identifier_values,
      popularity_score,
      has_read_now,
      has_ebook
    ) values (
      group_id_value,
      'en-US',
      work_id_value,
      edition_id_value,
      cover_location_id_value,
      title_value,
      normalized_title_value,
      coalesce(authors_value, ''),
      external_id_value,
      greatest(coalesce((book->>'download_count')::bigint, 0), 0),
      epub_url_value is not null,
      epub_url_value is not null
    ) on conflict (work_group_id, locale) do update set
      display_work_id = excluded.display_work_id,
      display_edition_id = excluded.display_edition_id,
      cover_location_id = excluded.cover_location_id,
      display_title = excluded.display_title,
      normalized_title = excluded.normalized_title,
      contributor_names = excluded.contributor_names,
      identifier_values = excluded.identifier_values,
      popularity_score = excluded.popularity_score,
      has_read_now = excluded.has_read_now,
      has_ebook = excluded.has_ebook,
      updated_at = now();

    processed := processed + 1;
  end loop;

  update catalog_ingest.ingest_runs
  set status = 'completed',
      records_seen = jsonb_array_length(p_books),
      records_changed = processed,
      completed_at = now()
  where id = run_id_value;

  return jsonb_build_object(
    'runId', run_id_value,
    'seen', jsonb_array_length(p_books),
    'processed', processed
  );
exception when others then
  if run_id_value is not null then
    update catalog_ingest.ingest_runs
    set status = 'failed',
        records_seen = jsonb_array_length(p_books),
        records_changed = processed,
        records_failed = greatest(jsonb_array_length(p_books) - processed, 1),
        error_summary = left(sqlerrm, 2000),
        completed_at = now()
    where id = run_id_value;
  end if;
  raise;
end;
$$;

revoke execute on function public.catalog_ingest_gutenberg(jsonb)
  from public, anon, authenticated;
grant execute on function public.catalog_ingest_gutenberg(jsonb)
  to service_role;

comment on function public.catalog_search(text, text, uuid, integer) is
  'Service-only catalog search over the denormalized serving projection.';
comment on function public.catalog_ingest_gutenberg(jsonb) is
  'Retry-safe Project Gutenberg batch normalization for service-role ingestion.';
comment on table public.catalog_interests is
  'User demand for unavailable catalog works, exportable by work and publisher.';
