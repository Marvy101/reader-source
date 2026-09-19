create table public.reading_states (
  user_id uuid not null references auth.users(id) on delete cascade,
  file_id uuid not null,
  locator jsonb not null,
  progress double precision not null check (progress between 0 and 1),
  last_opened_at timestamptz not null,
  device_id uuid not null,
  client_updated_at timestamptz not null,
  server_updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (user_id, file_id),
  foreign key (file_id, user_id)
    references public.library_files(id, user_id)
    on delete cascade
);

create index reading_states_user_recent
  on public.reading_states(user_id, last_opened_at desc);

create index reading_states_file_owner
  on public.reading_states(file_id, user_id);

create or replace function public.keep_newest_reading_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.client_updated_at <= old.client_updated_at then
    return null;
  end if;

  new.server_updated_at = now();
  return new;
end;
$$;

create trigger reading_states_keep_newest
before update on public.reading_states
for each row execute function public.keep_newest_reading_state();

alter table public.reading_states enable row level security;

create policy reading_states_select_own
on public.reading_states for select
to authenticated
using ((select auth.uid()) = user_id);

create policy reading_states_insert_own
on public.reading_states for insert
to authenticated
with check ((select auth.uid()) = user_id);

create policy reading_states_update_own
on public.reading_states for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy reading_states_delete_own
on public.reading_states for delete
to authenticated
using ((select auth.uid()) = user_id);

grant select, insert, update, delete
on table public.reading_states
to authenticated;
