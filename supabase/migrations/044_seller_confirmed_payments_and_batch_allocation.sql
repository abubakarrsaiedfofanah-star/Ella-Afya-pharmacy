-- Let sellers finish M-Pesa sales without waiting for Admin. These entries
-- are explicitly seller reported because this deployment has no Safaricom API.
do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid='public.payments'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%verification_source%'
  loop
    execute format('alter table public.payments drop constraint %I',v_constraint.conname);
  end loop;
  alter table public.payments add constraint payments_verification_source_check
    check(verification_source in ('manual','daraja_stk','daraja_c2b','seller_attested'));
end $$;

create or replace function public.add_manual_sale_payment(
  p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null,p_cash_tendered numeric default null
)
returns numeric
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  s public.sales%rowtype;
  paid numeric(12,2);
  r record;
  b public.batches%rowtype;
  v_sum numeric(12,2);
  v_amount numeric(12,2);
  v_tendered numeric(12,2);
  v_change numeric(12,2);
  v_mpesa_code text;
  v_remaining_qty integer;
  v_available integer;
  v_take integer;
  v_primary_batch_id uuid;
  v_medicine_name text;
begin
  if auth.uid() is null or public.current_role() not in ('admin','seller') then
    raise exception 'Active staff authorization required';
  end if;
  select * into s from public.sales where id=p_sale_id for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if public.current_role()='seller' then
    if s.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
    if not exists(select 1 from public.seller_permissions where user_id=auth.uid() and can_sell=true) then
      raise exception 'Seller is not permitted to process sales';
    end if;
  end if;
  if p_method not in ('cash','other','mpesa') or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then
    raise exception 'Enter a valid payment amount to two decimal places';
  end if;
  v_amount:=p_amount::numeric(12,2);
  if p_method='cash' then
    if p_cash_tendered is null or p_cash_tendered<v_amount or p_cash_tendered<>round(p_cash_tendered,2) then
      raise exception 'Cash received must cover the payment and use two decimal places';
    end if;
    v_tendered:=p_cash_tendered::numeric(12,2);v_change:=v_tendered-v_amount;
  elsif p_cash_tendered is not null then
    raise exception 'Cash received is only valid for cash payments';
  end if;
  if p_method='mpesa' then
    v_mpesa_code:=upper(trim(coalesce(p_reference,'')));
    if length(v_mpesa_code)<6 or length(v_mpesa_code)>64 or v_mpesa_code !~ '^[A-Z0-9]+$' then
      raise exception 'Enter the M-Pesa receipt code from the customer confirmation message';
    end if;
    if exists(select 1 from public.payments where upper(mpesa_receipt)=v_mpesa_code) then
      raise exception 'This M-Pesa code has already been recorded';
    end if;
  end if;
  select coalesce(sum(amount),0)::numeric(12,2) into paid
  from public.payments where sale_id=p_sale_id and status='paid';
  if paid+v_amount>s.total_amount then raise exception 'Payment exceeds outstanding balance'; end if;

  insert into public.payments(
    sale_id,method,amount,provider_reference,mpesa_receipt,status,confirmed_at,
    verification_source,cash_tendered,change_due
  ) values (
    p_sale_id,p_method,v_amount,case when p_method='mpesa' then v_mpesa_code else p_reference end,
    case when p_method='mpesa' then v_mpesa_code else null end,'paid',now(),
    case when p_method='mpesa' then 'seller_attested' else 'manual' end,v_tendered,v_change
  );
  v_sum:=paid+v_amount;

  if abs(v_sum-s.total_amount)<=0.01 then
    for r in select * from public.sale_items where sale_id=p_sale_id for update loop
      v_remaining_qty:=r.quantity;
      v_primary_batch_id:=null;
      select name into v_medicine_name from public.medicines where id=r.medicine_id;
      select coalesce(sum(quantity),0)::integer into v_available
      from public.batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>0;
      if v_available<r.quantity then
        raise exception 'Insufficient unexpired batch stock for % (available %, requested %). Payment was not recorded.',
          coalesce(v_medicine_name,r.medicine_id::text),v_available,r.quantity;
      end if;

      -- Consume the chosen batch first, then continue through later unexpired
      -- batches when the requested quantity is spread across multiple lots.
      for b in
        select * from public.batches
        where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>0
        order by (id=r.batch_id) desc,expiry_date,received_at,id
        for update
      loop
        v_take:=least(b.quantity,v_remaining_qty);
        if v_take>0 then
          update public.batches set quantity=quantity-v_take where id=b.id;
          insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
          values(r.medicine_id,b.id,'sale',-v_take,'sale',s.id,auth.uid(),
            jsonb_build_object('split_payment',true,'payment_method',p_method,'verification_source',case when p_method='mpesa' then 'seller_attested' else 'manual' end));
          if v_primary_batch_id is null then v_primary_batch_id:=b.id;end if;
          v_remaining_qty:=v_remaining_qty-v_take;
          exit when v_remaining_qty=0;
        end if;
      end loop;
      if v_remaining_qty>0 then
        raise exception 'Batch stock changed while completing payment. Payment was not recorded.';
      end if;
      update public.sale_items set batch_id=v_primary_batch_id where id=r.id;
      update public.inventory set quantity=quantity-r.quantity
      where medicine_id=r.medicine_id and quantity>=r.quantity;
      if not found then raise exception 'Inventory changed while completing payment. Payment was not recorded.'; end if;
      if r.prescription_item_id is not null then
        update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id;
      end if;
    end loop;
    update public.sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object(
      'amount',v_sum,'method',p_method,'verification_source',case when p_method='mpesa' then 'seller_attested' else 'manual' end));
  end if;
  return greatest(s.total_amount-v_sum,0);
end;
$$;
revoke all on function public.add_manual_sale_payment(uuid,text,numeric,text,numeric) from public,anon;
grant execute on function public.add_manual_sale_payment(uuid,text,numeric,text,numeric) to authenticated;

notify pgrst,'reload schema';
