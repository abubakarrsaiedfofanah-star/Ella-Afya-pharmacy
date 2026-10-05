-- Sales must use the exact catalogue price. When a client submits a different
-- price (including a stale page after an Admin price change), reject the sale
-- and persist an Admin-visible audit/notification event.
create or replace function public.create_sale(p_items jsonb,p_prescription_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_sale_id uuid:=gen_random_uuid();
  v_number text;
  v_total numeric(12,2):=0;
  item jsonb;
  v_price numeric;
  v_submitted_price numeric;
  v_submitted_text text;
  v_qty int;
  v_med uuid;
  v_stock int;
  v_required boolean;
  v_rem int;
  v_pi uuid;
  v_batch_id uuid;
  v_can_sell boolean:=true;
  v_max numeric;
  v_medicine_name text;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' then
    select can_sell,max_transaction_amount into v_can_sell,v_max
    from public.seller_permissions where user_id=auth.uid();
    if coalesce(v_can_sell,false)=false then raise exception 'Your seller account is not permitted to process sales'; end if;
  end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then
    raise exception 'Sale requires items';
  end if;
  if p_prescription_id is not null and not exists(
    select 1 from public.prescriptions
    where id=p_prescription_id and status in ('verified','dispensing','dispensed')
  ) then raise exception 'Prescription is not verified'; end if;

  -- Preflight all submitted prices before writing a sale. A null return is an
  -- intentional blocked sale: returning normally preserves the audit record.
  for item in select value from jsonb_array_elements(p_items) loop
    v_med:=nullif(item->>'medicine_id','')::uuid;
    v_submitted_text:=item->>'unit_price';
    select selling_price,name into v_price,v_medicine_name
    from public.medicines where id=v_med and active=true for share;
    if v_price is null then raise exception 'Medicine unavailable'; end if;
    -- Older clients may omit unit_price. They remain safe because the sale
    -- line is always priced from the database below.
    if v_submitted_text is null then continue; end if;
    if v_submitted_text !~ '^\d+(\.\d{1,2})?$' then
      perform public.audit('SALE_PRICE_MISMATCH_REJECTED','medicine',v_med::text,
        jsonb_build_object('medicine_name',v_medicine_name,'catalogue_price',v_price,
          'submitted_price',left(coalesce(v_submitted_text,'<missing>'),40),
          'seller_id',auth.uid(),'reason','invalid_submitted_price'));
      return null;
    end if;
    v_submitted_price:=v_submitted_text::numeric;
    if v_submitted_price is distinct from v_price then
      perform public.audit('SALE_PRICE_MISMATCH_REJECTED','medicine',v_med::text,
        jsonb_build_object('medicine_name',v_medicine_name,'catalogue_price',v_price,
          'submitted_price',v_submitted_price,'difference',v_submitted_price-v_price,
          'submitted_quantity',left(coalesce(item->>'quantity','<missing>'),20),'seller_id',auth.uid(),
          'reason','submitted_price_differs_from_catalogue'));
      return null;
    end if;
  end loop;

  v_number:='SALE-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_sale_id::text,'-',''),1,6);
  insert into public.sales(id,sale_number,seller_id,prescription_id,total_amount,status)
  values(v_sale_id,v_number,auth.uid(),p_prescription_id,0,'pending_payment');
  for item in select value from jsonb_array_elements(p_items) loop
    v_med:=(item->>'medicine_id')::uuid;
    v_qty:=(item->>'quantity')::integer;
    v_batch_id:=nullif(item->>'batch_id','')::uuid;
    if v_qty<=0 then raise exception 'Invalid quantity'; end if;
    select selling_price,prescription_required into v_price,v_required
    from public.medicines where id=v_med and active=true for share;
    if v_price is null then raise exception 'Medicine unavailable'; end if;
    if v_required and p_prescription_id is null then raise exception 'Prescription required for this medicine'; end if;
    if p_prescription_id is not null then
      select id,quantity_prescribed-quantity_dispensed into v_pi,v_rem
      from public.prescription_items
      where prescription_id=p_prescription_id and medicine_id=v_med for update;
      if v_pi is null or v_rem<v_qty then raise exception 'Sale quantity exceeds prescription balance'; end if;
    end if;
    select quantity into v_stock from public.inventory where medicine_id=v_med for update;
    if coalesce(v_stock,0)<v_qty then raise exception 'Insufficient stock for medicine %',v_med; end if;
    if v_batch_id is not null and not exists(
      select 1 from public.batches where id=v_batch_id and medicine_id=v_med
        and expiry_date>=current_date and quantity>=v_qty
    ) then raise exception 'Selected batch is invalid, expired or has insufficient stock'; end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price,prescription_item_id,batch_id)
    values(v_sale_id,v_med,v_qty,v_price,v_pi,v_batch_id);
    v_total:=v_total+v_qty*v_price;
  end loop;
  if public.current_role()='seller' and v_max is not null and v_total>v_max then
    raise exception 'Transaction exceeds your authorized seller limit';
  end if;
  update public.sales set total_amount=v_total where id=v_sale_id;
  perform public.audit('SALE_CREATED','sale',v_sale_id::text,
    jsonb_build_object('total',v_total,'prescription_id',p_prescription_id));
  return v_sale_id;
exception when others then
  delete from public.sale_items where sale_id=v_sale_id;
  delete from public.sales where id=v_sale_id;
  raise;
end;
$$;

revoke all on function public.create_sale(jsonb,uuid) from public,anon;
grant execute on function public.create_sale(jsonb,uuid) to authenticated;
