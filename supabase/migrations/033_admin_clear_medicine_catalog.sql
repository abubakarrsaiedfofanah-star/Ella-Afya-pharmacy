-- Clear the active catalogue without deleting medicines tied to business history.
create or replace function public.admin_clear_medicine_catalog()
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_archived integer;
  v_units bigint;
begin
  if auth.uid() is null or public.current_role()<>'admin' then
    raise exception 'Admin authorization required';
  end if;

  select count(*)::integer into v_archived
  from public.medicines where active;

  select coalesce(sum(quantity),0)::bigint into v_units
  from public.inventory;

  update public.batches set quantity=0 where quantity<>0;
  update public.inventory set quantity=0 where quantity<>0;
  update public.medicines set active=false where active;

  perform public.audit('MEDICINE_CATALOG_CLEARED','medicine','all',
    jsonb_build_object('archived_medicines',v_archived,'cleared_units',v_units));

  return jsonb_build_object('archived_medicines',v_archived,'cleared_units',v_units);
end;
$$;

revoke all on function public.admin_clear_medicine_catalog() from public,anon;
grant execute on function public.admin_clear_medicine_catalog() to authenticated;
