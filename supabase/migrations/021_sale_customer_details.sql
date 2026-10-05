-- Store optional buyer details on the sale while keeping payment verification server-side.
alter table public.pharmacy_settings alter column pharmacy_name set default 'Ella Afya Pharmacy';
update public.pharmacy_settings set pharmacy_name='Ella Afya Pharmacy' where pharmacy_name='PharmaCare Pharmacy';

alter table public.sales
  add column if not exists customer_name text,
  add column if not exists customer_phone text;

create or replace function public.set_sale_customer_details(
  p_sale_id uuid,
  p_customer_name text default null,
  p_customer_phone text default null
)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_sale public.sales%rowtype;
begin
  if public.current_role()<>'seller' then raise exception 'Seller access required'; end if;
  select * into v_sale from public.sales where id=p_sale_id and seller_id=auth.uid() for update;
  if not found then raise exception 'Sale not found'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is no longer editable'; end if;
  if length(trim(coalesce(p_customer_name,'')))>120 then raise exception 'Customer name is too long'; end if;
  if length(trim(coalesce(p_customer_phone,'')))>32 then raise exception 'Customer phone is too long'; end if;

  update public.sales
  set customer_name=nullif(trim(coalesce(p_customer_name,'')),''),
      customer_phone=nullif(trim(coalesce(p_customer_phone,'')),'')
  where id=p_sale_id;

  perform public.audit('SALE_CUSTOMER_DETAILS_UPDATED','sale',p_sale_id::text,
    jsonb_build_object('has_name',nullif(trim(coalesce(p_customer_name,'')),'') is not null,
                       'has_phone',nullif(trim(coalesce(p_customer_phone,'')),'') is not null));
end;
$$;

revoke all on function public.set_sale_customer_details(uuid,text,text) from public,anon;
grant execute on function public.set_sale_customer_details(uuid,text,text) to authenticated;

-- Copy verified C2B payer identity onto the same sale as its items.
create or replace function public.apply_mpesa_c2b_callback(
  p_receipt text,p_sale_number text,p_amount numeric,p_phone text,
  p_transaction_time timestamptz,p_payload jsonb
)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare s public.sales%rowtype; r record; v_batch_id uuid; v_payer_name text;
begin
  if p_receipt is null then raise exception 'M-Pesa receipt is required'; end if;
  if exists(select 1 from public.payments where mpesa_receipt=p_receipt and status='paid') then return; end if;
  select * into s from public.sales where sale_number=trim(p_sale_number) for update;
  if not found then raise exception 'Sale reference not found'; end if;
  if s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if abs(p_amount-s.total_amount)>0.01 then raise exception 'M-Pesa amount does not match sale'; end if;
  for r in select * from public.sale_items where sale_id=s.id for update loop
    v_batch_id:=r.batch_id;
    if v_batch_id is not null then
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id and expiry_date>=current_date and quantity>=r.quantity;
      if not found then raise exception 'Selected batch unavailable'; end if;
    else
      select b.id into v_batch_id from public.batches b where b.medicine_id=r.medicine_id and b.expiry_date>=current_date and b.quantity>=r.quantity order by b.expiry_date,b.received_at limit 1 for update;
      if v_batch_id is null then raise exception 'No suitable batch available'; end if;
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id;
      update public.sale_items set batch_id=v_batch_id where id=r.id;
    end if;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock unavailable'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,v_batch_id,'sale',-r.quantity,'sale',s.id,null,jsonb_build_object('mpesa_receipt',p_receipt,'source','C2B'));
  end loop;
  insert into public.payments(sale_id,method,amount,provider_reference,mpesa_receipt,phone_number,transaction_time,status,confirmed_at,callback_payload)
  values(s.id,'mpesa',p_amount,p_receipt,p_receipt,p_phone,p_transaction_time,'paid',now(),p_payload);
  v_payer_name:=nullif(trim(concat_ws(' ',p_payload->>'FirstName',p_payload->>'MiddleName',p_payload->>'LastName')),'');
  update public.sales
  set status='paid',customer_name=coalesce(v_payer_name,customer_name),customer_phone=coalesce(p_phone,customer_phone)
  where id=s.id;
end;
$$;

revoke all on function public.apply_mpesa_c2b_callback(text,text,numeric,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.apply_mpesa_c2b_callback(text,text,numeric,text,timestamptz,jsonb) to service_role;
