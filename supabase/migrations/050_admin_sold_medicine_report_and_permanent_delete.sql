-- Admin can review every completed medicine sale over any chosen date range.
create or replace function public.admin_sold_medicines(p_from date,p_to date)
returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_result jsonb;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Choose a valid date range'; end if;
  with sold as (
    select si.medicine_id,m.name,m.strength,si.quantity,si.total,s.id sale_id
    from public.sale_items si join public.sales s on s.id=si.sale_id join public.medicines m on m.id=si.medicine_id
    where s.status='paid'
      and s.created_at >= (p_from::timestamp at time zone 'Africa/Nairobi')
      and s.created_at < ((p_to+1)::timestamp at time zone 'Africa/Nairobi')
  ), grouped as (
    select medicine_id,name,strength,sum(quantity)::bigint units_sold,count(distinct sale_id)::bigint sales_count,
      sum(total)::numeric(14,2) revenue
    from sold group by medicine_id,name,strength
  )
  select jsonb_build_object(
    'rows',(select coalesce(jsonb_agg(to_jsonb(g) order by g.units_sold desc,g.name),'[]'::jsonb) from grouped g),
    'medicine_count',(select count(*) from grouped),
    'units_sold',(select coalesce(sum(units_sold),0) from grouped),
    'sales_count',(select count(distinct sale_id) from sold),
    'revenue',(select coalesce(sum(revenue),0)::numeric(14,2) from grouped)
  ) into v_result;
  return v_result;
end $$;
revoke all on function public.admin_sold_medicines(date,date) from public,anon;
grant execute on function public.admin_sold_medicines(date,date) to authenticated;

-- Hard-delete is limited to inactive medicines without stock or any history.
-- Historical sold medicines remain in the catalogue as inactive records so
-- receipts, stock movements, and period reports keep their medicine names.
create or replace function public.admin_permanently_delete_inactive_medicine(p_medicine_id uuid)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_medicine public.medicines%rowtype;
  v_stock integer;
  v_fk record;
  v_referenced boolean;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into v_medicine from public.medicines where id=p_medicine_id for update;
  if not found then raise exception 'Medicine not found'; end if;
  if v_medicine.active then raise exception 'Deactivate this medicine before permanently deleting it'; end if;
  select quantity into v_stock from public.inventory where medicine_id=p_medicine_id for update;
  if coalesce(v_stock,0)>0 or exists(select 1 from public.batches where medicine_id=p_medicine_id and quantity>0) then
    raise exception 'Medicine still has stock. Adjust or transfer the stock before deleting it';
  end if;

  -- The only reference removable without losing history is an empty inventory row.
  delete from public.inventory where medicine_id=p_medicine_id and quantity=0;
  for v_fk in
    select c.conrelid::regclass as child_table,child.attname as child_column
    from pg_constraint c
    cross join lateral unnest(c.conkey) with ordinality as child_key(attnum,position)
    join pg_attribute child on child.attrelid=c.conrelid and child.attnum=child_key.attnum
    cross join lateral unnest(c.confkey) with ordinality as parent_key(attnum,position)
    join pg_attribute parent on parent.attrelid=c.confrelid and parent.attnum=parent_key.attnum and parent_key.position=child_key.position
    where c.contype='f' and c.confrelid='public.medicines'::regclass and parent.attname='id' and array_length(c.conkey,1)=1
  loop
    execute format('select exists(select 1 from %s where %I=$1)',v_fk.child_table,v_fk.child_column)
      into v_referenced using p_medicine_id;
    if v_referenced then raise exception 'This medicine has sales or stock history and cannot be permanently deleted. It is inactive and hidden from selling.'; end if;
  end loop;
  perform public.audit('INACTIVE_MEDICINE_PERMANENTLY_DELETED','medicine',p_medicine_id::text,
    jsonb_build_object('name',v_medicine.name,'barcode',v_medicine.barcode));
  delete from public.medicines where id=p_medicine_id;
  return jsonb_build_object('deleted',true,'medicine_id',p_medicine_id,'name',v_medicine.name);
end $$;
revoke all on function public.admin_permanently_delete_inactive_medicine(uuid) from public,anon;
grant execute on function public.admin_permanently_delete_inactive_medicine(uuid) to authenticated;

notify pgrst,'reload schema';
