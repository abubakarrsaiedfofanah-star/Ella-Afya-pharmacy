-- Transactional business logic. Run after 001_initial_schema.sql.

-- Replace invalid generated low_stock design with a normal column maintained by triggers.
alter table public.inventory drop column if exists low_stock;
alter table public.inventory add column low_stock boolean not null default false;

create or replace function public.refresh_inventory_flag()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  new.low_stock := new.quantity <= coalesce((select min_stock from public.medicines where id=new.medicine_id),0);
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists trg_inventory_flag on public.inventory;
create trigger trg_inventory_flag before insert or update of quantity,medicine_id on public.inventory
for each row execute function public.refresh_inventory_flag();

create or replace function public.audit(p_action text,p_entity_type text,p_entity_id text,p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),p_action,p_entity_type,p_entity_id,coalesce(p_details,'{}'::jsonb));
end $$;

create or replace function public.create_sale(p_items jsonb, p_prescription_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare
  v_sale_id uuid := gen_random_uuid(); v_number text; v_total numeric(12,2):=0; item jsonb; v_price numeric; v_qty int; v_med uuid; v_stock int;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Sale requires items'; end if;
  v_number := 'SALE-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_sale_id::text,'-',''),1,6);
  insert into public.sales(id,sale_number,seller_id,prescription_id,total_amount,status) values(v_sale_id,v_number,auth.uid(),p_prescription_id,0,'pending_payment');
  for item in select * from jsonb_array_elements(p_items) loop
    v_med := (item->>'medicine_id')::uuid; v_qty := (item->>'quantity')::int;
    if v_qty <= 0 then raise exception 'Invalid quantity'; end if;
    select selling_price into v_price from public.medicines where id=v_med and active=true;
    if v_price is null then raise exception 'Medicine unavailable'; end if;
    select quantity into v_stock from public.inventory where medicine_id=v_med for update;
    if coalesce(v_stock,0) < v_qty then raise exception 'Insufficient stock for medicine %',v_med; end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price) values(v_sale_id,v_med,v_qty,v_price);
    v_total := v_total + v_qty*v_price;
  end loop;
  update public.sales set total_amount=v_total where id=v_sale_id;
  perform public.audit('SALE_CREATED','sale',v_sale_id::text,jsonb_build_object('total',v_total));
  return v_sale_id;
end $$;

create or replace function public.confirm_sale_payment(p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype; r record;
begin
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if p_amount<>v_sale.total_amount then raise exception 'Payment amount does not match sale total'; end if;
  if p_method not in ('mpesa','cash','other') then raise exception 'Invalid payment method'; end if;
  insert into public.payments(sale_id,method,amount,provider_reference,status,confirmed_at)
  values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  for r in select medicine_id,quantity from public.sale_items where sale_id=p_sale_id loop
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock changed; payment not completed'; end if;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'STOCK_DEDUCTED','medicine',r.medicine_id::text,jsonb_build_object('quantity',r.quantity,'sale_id',p_sale_id));
  end loop;
  update public.sales set status='paid' where id=p_sale_id;
  perform public.audit('PAYMENT_CONFIRMED','sale',p_sale_id::text,jsonb_build_object('method',p_method,'amount',p_amount,'reference',p_reference));
  return p_sale_id;
end $$;

create or replace function public.request_action(p_action_type text,p_target_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role()<>'seller' then raise exception 'Only seller requests use this workflow'; end if;
  insert into public.approvals(action_type,target_id,requested_by,reason) values(p_action_type,p_target_id,p_reason) returning id into v_id;
  perform public.audit('APPROVAL_REQUESTED',p_action_type,v_id::text,jsonb_build_object('target_id',p_target_id,'reason',p_reason));
  return v_id;
end $$;

create or replace function public.decide_approval(p_approval_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare a public.approvals%rowtype; s public.sales%rowtype;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into a from public.approvals where id=p_approval_id for update;
  if not found or a.status<>'pending' then raise exception 'Approval unavailable'; end if;
  update public.approvals set approved_by=auth.uid(),status=case when p_approve then 'approved' else 'rejected' end,decided_at=now() where id=p_approval_id;
  if p_approve and a.action_type='refund' then
    select * into s from public.sales where id=a.target_id for update;
    if s.status<>'paid' then raise exception 'Sale is not refundable'; end if;
    update public.sales set status='refunded' where id=s.id;
    update public.payments set status='refunded' where sale_id=s.id and status='paid';
  elsif p_approve and a.action_type='cancel_sale' then
    update public.sales set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid() where id=a.target_id and status='pending_payment';
  end if;
  perform public.audit(case when p_approve then 'APPROVAL_APPROVED' else 'APPROVAL_REJECTED' end,a.action_type,a.target_id::text,jsonb_build_object('approval_id',p_approval_id));
end $$;

create or replace function public.open_shift(p_opening_cash numeric default 0)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role()<>'seller' then raise exception 'Seller only'; end if;
  if exists(select 1 from public.shift_sessions where seller_id=auth.uid() and status='open') then raise exception 'Shift already open'; end if;
  insert into public.shift_sessions(seller_id,opening_cash) values(auth.uid(),p_opening_cash) returning id into v_id;
  perform public.audit('SHIFT_OPENED','shift',v_id::text,jsonb_build_object('opening_cash',p_opening_cash)); return v_id;
end $$;

create or replace function public.close_shift(p_shift_id uuid,p_closing_cash numeric)
returns void language plpgsql security definer set search_path=public as $$
declare v_s public.shift_sessions%rowtype;
begin
  select * into v_s from public.shift_sessions where id=p_shift_id for update;
  if not found or v_s.seller_id<>auth.uid() or v_s.status<>'open' then raise exception 'Invalid shift'; end if;
  update public.shift_sessions set closing_cash=p_closing_cash,closed_at=now(),status='closed' where id=p_shift_id;
  perform public.audit('SHIFT_CLOSED','shift',p_shift_id::text,jsonb_build_object('closing_cash',p_closing_cash));
end $$;

revoke all on function public.create_sale(jsonb,uuid) from public;
revoke all on function public.confirm_sale_payment(uuid,text,numeric,text) from public;
revoke all on function public.decide_approval(uuid,boolean) from public;
revoke all on function public.open_shift(numeric) from public;
revoke all on function public.close_shift(uuid,numeric) from public;
grant execute on function public.create_sale(jsonb,uuid) to authenticated;
grant execute on function public.confirm_sale_payment(uuid,text,numeric,text) to authenticated;
grant execute on function public.decide_approval(uuid,boolean) to authenticated;
grant execute on function public.open_shift(numeric) to authenticated;
grant execute on function public.close_shift(uuid,numeric) to authenticated;
