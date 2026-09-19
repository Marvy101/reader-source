create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid,
  name text not null check (char_length(name) between 1 and 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (parent_id, user_id)
    references public.folders(id, user_id)
    on delete restrict
);

create unique index folders_unique_sibling_name
  on public.folders (
    user_id,
    coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(name)
  );

create or replace function public.prevent_folder_cycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.parent_id is null then
    return new;
  end if;

  if new.parent_id = new.id then
    raise exception 'A folder cannot contain itself';
  end if;

  if exists (
    with recursive ancestors as (
      select folder.id, folder.parent_id
      from public.folders as folder
      where folder.id = new.parent_id
        and folder.user_id = new.user_id

      union all

      select folder.id, folder.parent_id
      from public.folders as folder
      join ancestors on folder.id = ancestors.parent_id
      where folder.user_id = new.user_id
    )
    select 1 from ancestors where id = new.id
  ) then
    raise exception 'Moving this folder would create a cycle';
  end if;

  return new;
end;
$$;

create trigger folders_prevent_cycle
before insert or update of parent_id on public.folders
for each row execute function public.prevent_folder_cycle();

create table public.library_files (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  folder_id uuid,
  display_name text not null check (char_length(display_name) between 1 and 500),
  original_filename text not null check (char_length(original_filename) between 1 and 500),
  media_type text not null,
  byte_size bigint not null check (byte_size > 0),
  sha256 text check (sha256 is null or sha256 ~ '^[a-f0-9]{64}$'),
  storage_bucket text not null default 'reader-files',
  storage_path text not null,
  status text not null default 'pending'
    check (status in ('pending', 'ready', 'failed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (user_id, storage_bucket, storage_path),
  foreign key (folder_id, user_id)
    references public.folders(id, user_id)
    on delete restrict
);

create index library_files_user_folder
  on public.library_files(user_id, folder_id, created_at desc);

create index library_files_user_hash
  on public.library_files(user_id, sha256)
  where sha256 is not null;

create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'completed', 'failed')),
  last_error text,
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

create table public.billing_customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  provider_customer_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider),
  unique (provider, provider_customer_id)
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  provider_subscription_id text not null,
  product_id text,
  price_id text,
  status text not null,
  current_period_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_subscription_id)
);

create index subscriptions_user_status
  on public.subscriptions(user_id, status);

create table public.entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entitlement_key text not null,
  source text not null,
  active boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, entitlement_key, source)
);

create table public.billing_events (
  provider text not null,
  provider_event_id text not null,
  event_type text not null,
  payload jsonb not null,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (provider, provider_event_id)
);

create trigger user_profiles_set_updated_at
before update on public.user_profiles
for each row execute function public.set_updated_at();

create trigger folders_set_updated_at
before update on public.folders
for each row execute function public.set_updated_at();

create trigger library_files_set_updated_at
before update on public.library_files
for each row execute function public.set_updated_at();

create trigger account_deletion_requests_set_updated_at
before update on public.account_deletion_requests
for each row execute function public.set_updated_at();

create trigger billing_customers_set_updated_at
before update on public.billing_customers
for each row execute function public.set_updated_at();

create trigger subscriptions_set_updated_at
before update on public.subscriptions
for each row execute function public.set_updated_at();

create trigger entitlements_set_updated_at
before update on public.entitlements
for each row execute function public.set_updated_at();

create or replace function public.create_user_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger auth_user_created
after insert on auth.users
for each row execute function public.create_user_profile();

insert into public.user_profiles (id)
select id from auth.users
on conflict (id) do nothing;

alter table public.user_profiles enable row level security;
alter table public.folders enable row level security;
alter table public.library_files enable row level security;
alter table public.account_deletion_requests enable row level security;
alter table public.billing_customers enable row level security;
alter table public.subscriptions enable row level security;
alter table public.entitlements enable row level security;
alter table public.billing_events enable row level security;

create policy user_profiles_select_own
on public.user_profiles for select
using ((select auth.uid()) = id);

create policy folders_manage_own
on public.folders for all
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy library_files_manage_own
on public.library_files for all
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy account_deletion_requests_create_own
on public.account_deletion_requests for insert
with check ((select auth.uid()) = user_id);

create policy account_deletion_requests_read_own
on public.account_deletion_requests for select
using ((select auth.uid()) = user_id);

create policy account_deletion_requests_update_own
on public.account_deletion_requests for update
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy billing_customers_read_own
on public.billing_customers for select
using ((select auth.uid()) = user_id);

create policy subscriptions_read_own
on public.subscriptions for select
using ((select auth.uid()) = user_id);

create policy entitlements_read_own
on public.entitlements for select
using ((select auth.uid()) = user_id);

insert into storage.buckets (id, name, public)
values ('reader-files', 'reader-files', false)
on conflict (id) do update set public = excluded.public;

create policy reader_files_storage_read_own
on storage.objects for select
using (
  bucket_id = 'reader-files'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy reader_files_storage_insert_own
on storage.objects for insert
with check (
  bucket_id = 'reader-files'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy reader_files_storage_update_own
on storage.objects for update
using (
  bucket_id = 'reader-files'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
)
with check (
  bucket_id = 'reader-files'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy reader_files_storage_delete_own
on storage.objects for delete
using (
  bucket_id = 'reader-files'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);
