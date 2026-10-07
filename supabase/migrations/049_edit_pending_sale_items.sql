-- Allow a seller to change the items on their own unpaid sale. The sale row
-- lock serializes edits with payment recording so amount and items stay aligned.
create or replace function public.update_pending_sale_items(p_sale_id uuid,p_items jsonb)
returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_sale public.sales%rowtype;
  v_user_role text;
  v_can_sell boolean;
  v_max numeric;
  v_paid numeric(12,2):=0;
  v_existing_prices jsonb:='{}'::jsonb;
  v_total numeric(12,2):=0;
  v_item jsonb;
  v_medicine_id uuid;
  v_quantity integer;
  v_price numeric(12,2);
  v_current_price numeric(12,2);
  v_existing_price numeric(12,2);
  v_required boolean;
  v_inventory integer;
  v_prescription_item_id uuid;
  v_prescription_remaining integer;
begin
  v_user_role:=public.current_role();
  if auth.uid() is null or v_user_role not in ('admin','seller') then raise exception 'Active staff authorization required'; end if;
  if p_sale_id is null or jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' then raise exception 'Invalid pending sale items'; end if;
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found or v_sale.status<>'pending_payment' then raise exception 'Sale is no longer pending payment'; end if;
  if v_user_role='seller' then
    if v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
    select can_sell,max_transaction_amount into v_can_sell,v_max from public.seller_permissions where user_id=auth.uid();
    if not coalesce(v_can_sell,false) then raise exception 'Seller is not permitted to process sales'; end if;
  end if;
  select coalesce(sum(amount),0)::numeric(12,2) into v_paid from public.payments where sale_id=p_sale_id and status='paid';
  select coalesce(jsonb_object_agg(medicine_id::text,unit_price),'{}'::jsonb) into v_existing_prices
    from public.sale_items where sale_id=p_sale_id;

  if exists(select value->>'medicine_id' from jsonb_array_elements(p_items) as x(value) group by value->>'medicine_id' having count(*)>1) then
    raise exception 'Each medicine can appear only once in the sale';
  end if;
  delete from public.sale_items where sale_id=p_sale_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    if coalesce(v_item->>'medicine_id','') !~* '^[0-9a-f-]{36}$' or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$' then
      raise exception 'Enter a valid medicine and quantity';
    end if;
    v_medicine_id:=(v_item->>'medicine_id')::uuid;
    v_quantity:=(v_item->>'quantity')::integer;
    select selling_price,prescription_required into v_current_price,v_required
      from public.medicines where id=v_medicine_id and active=true for share;
    if not found then raise exception 'A selected medicine is unavailable'; end if;
    v_existing_price:=nullif(v_existing_prices->>v_medicine_id::text,'')::numeric(12,2);
    v_price:=coalesce(v_existing_price,v_current_price);
    if v_required and v_sale.prescription_id is null then raise exception 'A verified prescription is required for this medicine'; end if;
    v_prescription_item_id:=null;
    if v_sale.prescription_id is not null then
      select id,quantity_prescribed-quantity_dispensed into v_prescription_item_id,v_prescription_remaining from public.prescription_items
        where prescription_id=v_sale.prescription_id and medicine_id=v_medicine_id;
      if v_prescription_item_id is null or v_prescription_remaining<v_quantity then raise exception 'Sale quantity exceeds prescription balance'; end if;
    end if;
    select quantity into v_inventory from public.inventory where medicine_id=v_medicine_id for update;
    if coalesce(v_inventory,0)<v_quantity then raise exception 'Insufficient stock for %',v_item->>'medicine_id'; end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price,prescription_item_id,batch_id)
      values(p_sale_id,v_medicine_id,v_quantity,v_price,v_prescription_item_id,null);
    v_total:=v_total+(v_quantity*v_price);
  end loop;
  if v_total<v_paid then raise exception 'Updated sale total cannot be less than the amount already paid'; end if;
  if v_user_role='seller' and v_max is not null and v_total>v_max then raise exception 'Transaction exceeds your authorized seller limit'; end if;
  update public.sales set total_amount=v_total where id=p_sale_id;
  perform public.audit('PENDING_SALE_ITEMS_UPDATED','sale',p_sale_id::text,jsonb_build_object('old_total',v_sale.total_amount,'new_total',v_total,'paid',v_paid,'item_count',jsonb_array_length(p_items)));
  return jsonb_build_object(
    'sale_id',p_sale_id,'sale_number',v_sale.sale_number,'total_amount',v_total,'paid',v_paid,'balance',v_total-v_paid,
    'items',(select coalesce(jsonb_agg(jsonb_build_object('medicine_id',si.medicine_id,'name',m.name,'unit_price',si.unit_price,'quantity',si.quantity) order by m.name),'[]'::jsonb)
      from public.sale_items si join public.medicines m on m.id=si.medicine_id where si.sale_id=p_sale_id)
  );
end $$;
revoke all on function public.update_pending_sale_items(uuid,jsonb) from public,anon;
grant execute on function public.update_pending_sale_items(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
