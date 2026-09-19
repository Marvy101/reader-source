alter table public.library_files
  add column sort_order bigint;

with ordered_files as (
  select
    id,
    row_number() over (
      partition by user_id
      order by created_at asc, id asc
    ) - 1 as sort_order
  from public.library_files
)
update public.library_files as file
set sort_order = ordered_files.sort_order
from ordered_files
where file.id = ordered_files.id;

create or replace function public.set_library_file_sort_order()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.sort_order is not null then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  select coalesce(max(file.sort_order), -1) + 1
  into new.sort_order
  from public.library_files as file
  where file.user_id = new.user_id;
  return new;
end;
$$;

create trigger library_files_set_sort_order
before insert on public.library_files
for each row execute function public.set_library_file_sort_order();

alter table public.library_files
  alter column sort_order set not null;

create index library_files_user_sort_order
  on public.library_files(user_id, sort_order, created_at, id);

create or replace function public.reorder_library_files(p_file_ids uuid[])
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  requested_count integer := coalesce(cardinality(p_file_ids), 0);
begin
  if requested_count > 2000 then
    raise exception 'A library reorder may contain at most 2000 files';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended((select auth.uid())::text, 0)
  );

  if requested_count <> (
    select count(distinct file_id)
    from unnest(p_file_ids) as item(file_id)
  ) then
    raise exception 'A library reorder cannot contain duplicate files';
  end if;

  if exists (
    select 1
    from unnest(p_file_ids) as requested(file_id)
    left join public.library_files as file
      on file.id = requested.file_id
      and file.user_id = (select auth.uid())
    where file.id is null
  ) then
    raise exception 'A library reorder may only contain the signed-in user files';
  end if;

  update public.library_files as file
  set sort_order = requested.sort_order
  from (
    select file_id, ordinality - 1 as sort_order
    from unnest(p_file_ids) with ordinality as item(file_id, ordinality)
  ) as requested
  where file.id = requested.file_id
    and file.user_id = (select auth.uid());
end;
$$;

revoke execute on function public.reorder_library_files(uuid[]) from public;
grant execute on function public.reorder_library_files(uuid[]) to authenticated;
