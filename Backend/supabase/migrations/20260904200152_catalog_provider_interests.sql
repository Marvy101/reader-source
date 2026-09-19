insert into catalog_ingest.sources(
  code,
  name,
  source_kind,
  base_url,
  terms_url,
  retention_policy,
  trust_priority
) values (
  'google_books',
  'Google Books',
  'api',
  'https://www.googleapis.com/books/v1/',
  'https://developers.google.com/books/terms',
  'response_cache',
  50
)
on conflict (code) do update set
  name = excluded.name,
  base_url = excluded.base_url,
  terms_url = excluded.terms_url,
  enabled = true,
  updated_at = now();

create table public.catalog_provider_interests (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id bigint not null
    references catalog_ingest.sources(id) on delete restrict,
  external_id text not null
    check (char_length(btrim(external_id)) between 1 and 1000),
  title text not null
    check (char_length(btrim(title)) between 1 and 1000),
  authors text not null default ''
    check (char_length(authors) <= 2000),
  primary_identifier text
    check (
      primary_identifier is null
      or char_length(btrim(primary_identifier)) between 1 and 1000
    ),
  resolved_work_group_id bigint
    references catalog.work_groups(id) on delete set null,
  email_opt_in boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, source_id, external_id)
);

create index catalog_provider_interests_demand_report
  on public.catalog_provider_interests(
    source_id,
    external_id,
    active,
    created_at desc,
    user_id
  );
create index catalog_provider_interests_user_active
  on public.catalog_provider_interests(user_id, active, updated_at desc);
create index catalog_provider_interests_resolved_work
  on public.catalog_provider_interests(
    resolved_work_group_id,
    active,
    created_at desc
  )
  where resolved_work_group_id is not null;

create trigger catalog_provider_interests_set_updated_at
before update on public.catalog_provider_interests
for each row execute function public.set_updated_at();

alter table public.catalog_provider_interests enable row level security;

create policy catalog_provider_interests_manage_own
on public.catalog_provider_interests for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

grant select, delete on public.catalog_provider_interests to authenticated;
grant select, insert, update, delete on public.catalog_provider_interests
  to service_role;
grant usage, select on sequence public.catalog_provider_interests_id_seq
  to service_role;

create or replace function public.catalog_register_provider_interest(
  p_user_id uuid,
  p_source_code text,
  p_external_id text,
  p_title text,
  p_authors text default '',
  p_primary_identifier text default null,
  p_email_opt_in boolean default false
)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  source_id_value bigint;
begin
  select source.id
  into source_id_value
  from catalog_ingest.sources as source
  where source.code = btrim(p_source_code)
    and source.enabled;

  if source_id_value is null then
    raise exception 'catalog provider is unavailable'
      using errcode = '22023';
  end if;

  insert into public.catalog_provider_interests(
    user_id,
    source_id,
    external_id,
    title,
    authors,
    primary_identifier,
    email_opt_in,
    active
  ) values (
    p_user_id,
    source_id_value,
    btrim(p_external_id),
    btrim(p_title),
    btrim(coalesce(p_authors, '')),
    nullif(btrim(p_primary_identifier), ''),
    coalesce(p_email_opt_in, false),
    true
  )
  on conflict (user_id, source_id, external_id) do update set
    title = excluded.title,
    authors = excluded.authors,
    primary_identifier = excluded.primary_identifier,
    email_opt_in = public.catalog_provider_interests.email_opt_in
      or excluded.email_opt_in,
    active = true,
    updated_at = now();
end;
$$;

revoke execute on function public.catalog_register_provider_interest(
  uuid,
  text,
  text,
  text,
  text,
  text,
  boolean
) from public, anon, authenticated;
grant execute on function public.catalog_register_provider_interest(
  uuid,
  text,
  text,
  text,
  text,
  text,
  boolean
) to service_role;

comment on table public.catalog_provider_interests is
  'User demand for provider-scoped search results that have not yet been reconciled into Reader canonical works.';
comment on column public.catalog_provider_interests.external_id is
  'Opaque provider identifier, unique only within source_id.';
comment on column public.catalog_provider_interests.title is
  'Small user-selected display snapshot; refresh provider metadata by source_id and external_id before fulfillment.';
comment on function public.catalog_register_provider_interest(
  uuid,
  text,
  text,
  text,
  text,
  text,
  boolean
) is
  'Idempotently records service-only demand for an unreconciled provider result.';
