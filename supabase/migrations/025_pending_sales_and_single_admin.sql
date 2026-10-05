-- New accounts created through Supabase Auth default to pending Sales accounts.
-- The trusted admin-create-user Edge Function activates them only when an
-- active Admin creates the account. Public registration remains inactive.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  insert into public.profiles(id,full_name,role,active)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'),''),'Seller'),
    'seller',
    false
  )
  on conflict(id) do nothing;
  return new;
end;
$$;

-- The pharmacy has one Admin account. Resolve any existing duplicates before
-- applying this migration; disabled Admin profiles also count toward the limit.
do $$
begin
  if (select count(*) from public.profiles where role='admin') > 1 then
    raise exception 'More than one Admin profile exists. Keep one Admin profile, then rerun this migration.';
  end if;
end;
$$;

create unique index if not exists uq_profiles_single_admin
  on public.profiles(role)
  where role='admin';
