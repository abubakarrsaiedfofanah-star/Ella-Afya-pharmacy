-- Calculate current active inventory value without exposing purchase prices
-- through the medicines table or to Seller sessions.
create or replace function public.admin_inventory_valuation()
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or public.current_role()<>'admin' then
    raise exception 'Admin authorization required';
  end if;

  select jsonb_build_object(
    'medicine_count',count(*) filter(where i.quantity>0),
    'stock_units',coalesce(sum(i.quantity),0)::bigint,
    'buying_value',round(coalesce(sum(i.quantity*m.purchase_price),0),2),
    'selling_value',round(coalesce(sum(i.quantity*m.selling_price),0),2),
    'potential_margin',round(coalesce(sum(i.quantity*(m.selling_price-m.purchase_price)),0),2)
  )
  into v_result
  from public.medicines m
  join public.inventory i on i.medicine_id=m.id
  where m.active=true;

  return v_result;
end;
$$;

revoke all on function public.admin_inventory_valuation() from public,anon;
grant execute on function public.admin_inventory_valuation() to authenticated;

notify pgrst,'reload schema';
