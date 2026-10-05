-- Fail closed for missing, inactive, and not-yet-MFA-verified Admin sessions.
create or replace function public.current_role()
returns public.user_role
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select coalesce(
    (
      select case
        when p.role='admin' and coalesce(auth.jwt()->>'aal','aal1')<>'aal2'
          then 'inactive'::public.user_role
        else p.role
      end
      from public.profiles p
      where p.id=auth.uid() and p.active=true
      limit 1
    ),
    'inactive'::public.user_role
  );
$$;

-- Audit writes are performed by trusted SECURITY DEFINER functions/triggers.
-- Do not expose the generic audit writer as a client RPC.
revoke all on function public.audit(text,text,text,jsonb) from public,anon,authenticated;
drop policy if exists "admin audit insert" on public.audit_logs;
revoke insert,update,delete on table public.audit_logs from anon,authenticated;

-- This legacy RPC relied on seller-only ownership checks and accidentally let
-- other authenticated roles skip them. Require an active staff role first.
create or replace function public.confirm_sale_payment(
  p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_sale public.sales%rowtype;
  r record;
  b public.batches%rowtype;
begin
  if auth.uid() is null or public.current_role() not in ('admin','seller') then
    raise exception 'Active staff authorization required';
  end if;
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if p_amount is null or p_amount<>v_sale.total_amount then raise exception 'Payment amount does not match sale total'; end if;
  if p_method not in ('mpesa','cash','other') then raise exception 'Invalid payment method'; end if;
  if p_method='mpesa' then raise exception 'Use the secure M-Pesa payment flow'; end if;

  for r in select * from public.sale_items where sale_id=p_sale_id for update loop
    if r.batch_id is not null then
      select * into b from public.batches where id=r.batch_id and medicine_id=r.medicine_id for update;
      if not found or b.expiry_date<current_date or b.quantity<r.quantity then raise exception 'Selected batch unavailable or expired'; end if;
    else
      select * into b from public.batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity order by expiry_date,received_at limit 1 for update;
      if not found then raise exception 'No suitable unexpired batch has enough stock'; end if;
      update public.sale_items set batch_id=b.id where id=r.id;
    end if;
    update public.batches set quantity=quantity-r.quantity where id=b.id;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock changed; payment not completed'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,b.id,'sale',-r.quantity,'sale',p_sale_id,auth.uid(),'{}'::jsonb);
    if r.prescription_item_id is not null then
      update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id;
    end if;
  end loop;

  insert into public.payments(sale_id,method,amount,provider_reference,status,confirmed_at)
  values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  update public.sales set status='paid' where id=p_sale_id;
  perform public.audit('PAYMENT_CONFIRMED','sale',p_sale_id::text,jsonb_build_object('method',p_method,'amount',p_amount,'reference',p_reference));
  return p_sale_id;
end;
$$;
revoke all on function public.confirm_sale_payment(uuid,text,numeric,text) from public,anon;
grant execute on function public.confirm_sale_payment(uuid,text,numeric,text) to authenticated;

-- Apply the same explicit active-role and sale-ownership checks to split cash
-- payments. The original function only checked ownership when role='seller'.
create or replace function public.add_manual_sale_payment(
  p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null
)
returns numeric
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  s public.sales%rowtype;
  paid numeric;
  r record;
  b public.batches%rowtype;
  v_sum numeric;
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
  if p_method not in ('cash','other') or p_amount is null or p_amount<=0 then raise exception 'Invalid split payment'; end if;
  select coalesce(sum(amount),0) into paid from public.payments where sale_id=p_sale_id and status='paid';
  if paid+p_amount>s.total_amount then raise exception 'Payment exceeds outstanding balance'; end if;
  insert into public.payments(sale_id,method,amount,provider_reference,status,confirmed_at)
  values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  v_sum:=paid+p_amount;

  if abs(v_sum-s.total_amount)<=0.01 then
    for r in select * from public.sale_items where sale_id=p_sale_id for update loop
      if r.batch_id is not null then
        select * into b from public.batches where id=r.batch_id and medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity for update;
      else
        select * into b from public.batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity order by expiry_date,received_at limit 1 for update;
        if b.id is not null then update public.sale_items set batch_id=b.id where id=r.id; end if;
      end if;
      if b.id is null then raise exception 'Insufficient unexpired batch stock while completing payment'; end if;
      update public.batches set quantity=quantity-r.quantity where id=b.id;
      update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
      if not found then raise exception 'Inventory changed while completing payment'; end if;
      insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
      values(r.medicine_id,b.id,'sale',-r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('split_payment',true));
      if r.prescription_item_id is not null then
        update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id;
      end if;
    end loop;
    update public.sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object('amount',v_sum));
  end if;
  return greatest(s.total_amount-v_sum,0);
end;
$$;
revoke all on function public.add_manual_sale_payment(uuid,text,numeric,text) from public,anon;
grant execute on function public.add_manual_sale_payment(uuid,text,numeric,text) to authenticated;

-- A disabled seller must not be able to continue a shift by calling the RPC
-- directly after being disabled in the UI.
create or replace function public.close_shift(p_shift_id uuid,p_closing_cash numeric)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_shift public.shift_sessions%rowtype;
begin
  if auth.uid() is null or public.current_role()<>'seller' then raise exception 'Active Sales authorization required'; end if;
  select * into v_shift from public.shift_sessions where id=p_shift_id for update;
  if not found or v_shift.seller_id<>auth.uid() or v_shift.status<>'open' then raise exception 'Invalid shift'; end if;
  if p_closing_cash is null or p_closing_cash<0 then raise exception 'Closing cash must be zero or greater'; end if;
  update public.shift_sessions set closing_cash=p_closing_cash,closed_at=now(),status='closed' where id=p_shift_id;
  perform public.audit('SHIFT_CLOSED','shift',p_shift_id::text,jsonb_build_object('closing_cash',p_closing_cash));
end;
$$;
revoke all on function public.close_shift(uuid,numeric) from public,anon;
grant execute on function public.close_shift(uuid,numeric) to authenticated;

-- Session records must belong to the caller, and inactive users cannot keep
-- refreshing a session after Admin disables their profile.
create or replace function public.register_device_session(p_session_key text,p_device_label text default null,p_user_agent text default null)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_id uuid; v_revoked timestamptz;
begin
  if auth.uid() is null or public.current_role() not in ('admin','seller') then raise exception 'Active staff authentication required'; end if;
  if p_session_key is null or length(p_session_key)<32 or length(p_session_key)>180 then raise exception 'Invalid device session key'; end if;
  select revoked_at into v_revoked from public.device_sessions where user_id=auth.uid() and session_key=p_session_key;
  if v_revoked is not null then raise exception 'This device session was revoked. Please sign in again from an approved device.'; end if;
  if not exists(select 1 from public.device_sessions where user_id=auth.uid() and session_key=p_session_key)
     and exists(select 1 from public.device_sessions where user_id=auth.uid() and revoked_at is null and last_seen_at>=now()-interval '30 days') then
    insert into public.security_alerts(user_id,alert_type,severity,title,details)
    values(auth.uid(),'new_device','medium','New device/session detected',jsonb_build_object('device_label',left(p_device_label,120),'user_agent',left(p_user_agent,300)));
  end if;
  insert into public.device_sessions as existing(user_id,session_key,device_label,user_agent)
  values(auth.uid(),p_session_key,left(p_device_label,120),left(p_user_agent,500))
  on conflict(session_key) do update
    set last_seen_at=now(),device_label=excluded.device_label,user_agent=excluded.user_agent
    where existing.user_id=auth.uid() and existing.revoked_at is null
  returning id into v_id;
  if v_id is null then raise exception 'Device session unavailable'; end if;
  return v_id;
end;
$$;
revoke all on function public.register_device_session(text,text,text) from public,anon;
grant execute on function public.register_device_session(text,text,text) to authenticated;

create or replace function public.touch_device_session(p_session_key text)
returns boolean
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or public.current_role() not in ('admin','seller') then return false; end if;
  update public.device_sessions set last_seen_at=now()
  where session_key=left(p_session_key,180) and user_id=auth.uid() and revoked_at is null;
  return found;
end;
$$;
revoke all on function public.touch_device_session(text) from public,anon;
grant execute on function public.touch_device_session(text) to authenticated;

-- Held-sale history and deletion are seller-only even when invoked directly.
create or replace function public.my_held_sales()
returns setof public.held_sales
language sql
security definer
set search_path=public,pg_temp
as $$
  select * from public.held_sales
  where public.current_role()='seller' and seller_id=auth.uid()
  order by created_at desc
$$;
revoke all on function public.my_held_sales() from public,anon;
grant execute on function public.my_held_sales() to authenticated;

create or replace function public.delete_held_sale(p_id uuid)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or public.current_role()<>'seller' then raise exception 'Active Sales authorization required'; end if;
  delete from public.held_sales where id=p_id and seller_id=auth.uid();
end;
$$;
revoke all on function public.delete_held_sale(uuid) from public,anon;
grant execute on function public.delete_held_sale(uuid) to authenticated;
