insert into storage.buckets(
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
) values (
  'reader-catalog-files',
  'reader-catalog-files',
  false,
  52428800,
  array['application/epub+zip', 'application/pdf', 'text/plain']::text[]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.catalog_materialization_candidates(
  p_source_code text,
  p_after_offer_id bigint default 0,
  p_limit integer default 100
)
returns table (
  offer_id bigint,
  edition_id bigint,
  source_code text,
  external_id text,
  download_url text,
  media_type text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    offer.id,
    offer.edition_id,
    source.code,
    source_record.external_id,
    offer.url,
    offer.media_type
  from catalog.acquisition_offers as offer
  join catalog_ingest.source_records as source_record
    on source_record.id = offer.source_record_id
  join catalog_ingest.sources as source
    on source.id = source_record.source_id
  where source.code = p_source_code
    and offer.id > greatest(coalesce(p_after_offer_id, 0), 0)
    and offer.offer_kind = 'open_access'
    and offer.available
    and (
      offer.valid_until is null
      or offer.valid_until > now()
    )
    and not exists (
      select 1
      from catalog.edition_files as edition_file
      join catalog.content_locations as location
        on location.content_file_id = edition_file.content_file_id
        and location.location_kind = 'storage_object'
        and location.status = 'active'
      where edition_file.edition_id = offer.edition_id
        and edition_file.file_role = 'full_book'
        and edition_file.rights_status in (
          'public_domain',
          'open_license',
          'publisher_authorized'
        )
    )
  order by offer.id
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

create or replace function public.catalog_register_materialized_file(
  p_offer_id bigint,
  p_sha256 text,
  p_media_type text,
  p_byte_size bigint,
  p_storage_bucket text,
  p_storage_path text,
  p_rights_status text,
  p_license_code text default null,
  p_territories text[] default '{}'
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  offer_value catalog.acquisition_offers%rowtype;
  content_file_id_value bigint;
  existing_media_type text;
  existing_byte_size bigint;
  existing_location_file_id bigint;
begin
  if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'p_sha256 must be a lowercase hexadecimal SHA-256';
  end if;
  if p_media_type not in ('application/epub+zip', 'application/pdf', 'text/plain') then
    raise exception 'unsupported materialized media type: %', p_media_type;
  end if;
  if p_byte_size is null or p_byte_size <= 0 or p_byte_size > 52428800 then
    raise exception 'p_byte_size must be between 1 byte and 50 MiB';
  end if;
  if p_storage_bucket <> 'reader-catalog-files' then
    raise exception 'unexpected catalog storage bucket';
  end if;
  if p_storage_path is null
    or p_storage_path !~ '^[a-z][a-z0-9_]{1,63}/[a-zA-Z0-9._/-]+$'
    or p_storage_path like '%..%'
  then
    raise exception 'invalid catalog storage path';
  end if;
  if p_rights_status not in (
    'public_domain',
    'open_license',
    'publisher_authorized'
  ) then
    raise exception 'materialized files require affirmative rights';
  end if;

  select offer.*
  into offer_value
  from catalog.acquisition_offers as offer
  where offer.id = p_offer_id
    and offer.offer_kind = 'open_access'
    and offer.available
  for update;

  if not found then
    raise exception 'active open-access offer % was not found', p_offer_id;
  end if;

  insert into catalog.content_files(
    sha256,
    media_type,
    byte_size,
    encryption_scheme
  ) values (
    p_sha256,
    p_media_type,
    p_byte_size,
    'none'
  )
  on conflict (sha256) do nothing;

  select file.id, file.media_type, file.byte_size
  into content_file_id_value, existing_media_type, existing_byte_size
  from catalog.content_files as file
  where file.sha256 = p_sha256;

  if existing_media_type <> p_media_type or existing_byte_size <> p_byte_size then
    raise exception 'content hash metadata does not match the existing file';
  end if;

  insert into catalog.content_locations(
    content_file_id,
    source_record_id,
    location_kind,
    storage_bucket,
    storage_path,
    last_verified_at,
    status
  ) values (
    content_file_id_value,
    offer_value.source_record_id,
    'storage_object',
    p_storage_bucket,
    p_storage_path,
    now(),
    'active'
  )
  on conflict (storage_bucket, storage_path)
    where location_kind = 'storage_object'
  do update set
    last_verified_at = excluded.last_verified_at,
    status = 'active';

  select location.content_file_id
  into existing_location_file_id
  from catalog.content_locations as location
  where location.location_kind = 'storage_object'
    and location.storage_bucket = p_storage_bucket
    and location.storage_path = p_storage_path;

  if existing_location_file_id <> content_file_id_value then
    raise exception 'storage path is already assigned to different content';
  end if;

  insert into catalog.edition_files(
    edition_id,
    content_file_id,
    file_role,
    rights_status,
    license_code,
    territories,
    source_record_id
  ) values (
    offer_value.edition_id,
    content_file_id_value,
    'full_book',
    p_rights_status,
    p_license_code,
    coalesce(p_territories, '{}'),
    offer_value.source_record_id
  )
  on conflict (edition_id, content_file_id, file_role) do update set
    rights_status = excluded.rights_status,
    license_code = excluded.license_code,
    territories = excluded.territories,
    source_record_id = excluded.source_record_id;

  return jsonb_build_object(
    'offerId', offer_value.id,
    'editionId', offer_value.edition_id,
    'contentFileId', content_file_id_value,
    'sha256', p_sha256,
    'storageBucket', p_storage_bucket,
    'storagePath', p_storage_path
  );
end;
$$;

create or replace function public.catalog_resolve_materialized_files(
  p_edition_ids bigint[],
  p_territory text default null
)
returns table (
  edition_id bigint,
  storage_bucket text,
  storage_path text,
  media_type text,
  byte_size bigint,
  sha256 text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select distinct on (edition_file.edition_id)
    edition_file.edition_id,
    location.storage_bucket,
    location.storage_path,
    file.media_type,
    file.byte_size,
    file.sha256
  from catalog.edition_files as edition_file
  join catalog.content_files as file
    on file.id = edition_file.content_file_id
  join catalog.content_locations as location
    on location.content_file_id = file.id
    and location.location_kind = 'storage_object'
    and location.status = 'active'
  where edition_file.edition_id = any(coalesce(p_edition_ids, '{}'))
    and edition_file.file_role = 'full_book'
    and edition_file.rights_status in (
      'public_domain',
      'open_license',
      'publisher_authorized'
    )
    and (
      cardinality(edition_file.territories) = 0
      or upper(nullif(btrim(p_territory), '')) = any(edition_file.territories)
    )
  order by
    edition_file.edition_id,
    case edition_file.rights_status
      when 'publisher_authorized' then 0
      when 'open_license' then 1
      else 2
    end,
    location.last_verified_at desc nulls last,
    file.id;
$$;

revoke execute on function public.catalog_materialization_candidates(text, bigint, integer)
  from public, anon, authenticated;
revoke execute on function public.catalog_register_materialized_file(
  bigint,
  text,
  text,
  bigint,
  text,
  text,
  text,
  text,
  text[]
) from public, anon, authenticated;
revoke execute on function public.catalog_resolve_materialized_files(bigint[], text)
  from public, anon, authenticated;

grant execute on function public.catalog_materialization_candidates(text, bigint, integer)
  to service_role;
grant execute on function public.catalog_register_materialized_file(
  bigint,
  text,
  text,
  bigint,
  text,
  text,
  text,
  text,
  text[]
) to service_role;
grant execute on function public.catalog_resolve_materialized_files(bigint[], text)
  to service_role;

comment on function public.catalog_materialization_candidates(text, bigint, integer) is
  'Lists retry-safe, service-only open-access offers that do not yet have an affirmative stored full-book file.';
comment on function public.catalog_register_materialized_file(
  bigint,
  text,
  text,
  bigint,
  text,
  text,
  text,
  text,
  text[]
) is
  'Registers a validated immutable catalog file and its affirmative edition rights after a service worker uploads it.';
comment on function public.catalog_resolve_materialized_files(bigint[], text) is
  'Resolves private stored catalog files for service-side signed URL generation.';
