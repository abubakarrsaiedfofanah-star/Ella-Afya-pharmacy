-- ============================================================================
-- 001_initial_schema.sql
-- ============================================================================
create extension if not exists pgcrypto;

create type public.user_role as enum ('admin','seller');
create type public.sale_status as enum ('draft','pending_payment','paid','cancelled','refund_requested','refunded');
create type public.payment_status as enum ('pending','paid','failed','refunded');
create type public.prescription_status as enum ('received','under_review','verified','dispensing','dispensed','completed','held','rejected');
create type public.approval_status as enum ('pending','approved','rejected');

create table public.profiles(
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 role public.user_role not null default 'seller',
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table public.medicine_categories(
 id uuid primary key default gen_random_uuid(),
 name text unique not null,
 description text,
 created_at timestamptz not null default now()
);

create table public.medicines(
 id uuid primary key default gen_random_uuid(),
 category_id uuid references public.medicine_categories(id),
 name text not null,
 generic_name text,
 brand text,
 strength text,
 dosage_form text,
 unit text not null default 'unit',
 selling_price numeric(12,2) not null check(selling_price>=0),
 purchase_price numeric(12,2) not null default 0 check(purchase_price>=0),
 prescription_required boolean not null default false,
 min_stock integer not null default 0 check(min_stock>=0),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table public.inventory(
 medicine_id uuid primary key references public.medicines(id) on delete restrict,
 quantity integer not null default 0 check(quantity>=0),
 location text,
 updated_at timestamptz not null default now(),
 low_stock boolean not null default false
);

create table public.batches(
 id uuid primary key default gen_random_uuid(),
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 batch_number text not null,
 expiry_date date not null,
 quantity integer not null default 0 check(quantity>=0),
 received_at timestamptz not null default now(),
 supplier_name text,
 unique(medicine_id,batch_number)
);

create table public.prescriptions(
 id uuid primary key default gen_random_uuid(),
 prescription_number text unique not null,
 patient_name text not null,
 prescriber_name text,
 prescription_date date not null default current_date,
 status public.prescription_status not null default 'received',
 document_path text,
 created_by uuid not null references public.profiles(id),
 verified_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table public.prescription_items(
 id uuid primary key default gen_random_uuid(),
 prescription_id uuid not null references public.prescriptions(id) on delete restrict,
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 dosage_instructions text,
 quantity_prescribed integer not null check(quantity_prescribed>0),
 quantity_dispensed integer not null default 0 check(quantity_dispensed>=0)
);

create table public.sales(
 id uuid primary key default gen_random_uuid(),
 sale_number text unique not null,
 seller_id uuid not null references public.profiles(id),
 prescription_id uuid references public.prescriptions(id),
 total_amount numeric(12,2) not null check(total_amount>=0),
 status public.sale_status not null default 'draft',
 created_at timestamptz not null default now(),
 cancelled_at timestamptz,
 cancelled_by uuid references public.profiles(id)
);

create table public.sale_items(
 id uuid primary key default gen_random_uuid(),
 sale_id uuid not null references public.sales(id) on delete restrict,
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 quantity integer not null check(quantity>0),
 unit_price numeric(12,2) not null check(unit_price>=0),
 total numeric(12,2) generated always as (quantity*unit_price) stored
);

create table public.payments(
 id uuid primary key default gen_random_uuid(),
 sale_id uuid not null references public.sales(id) on delete restrict,
 method text not null check(method in ('mpesa','cash','other')),
 amount numeric(12,2) not null check(amount>0),
 provider_reference text,
 status public.payment_status not null default 'pending',
 created_at timestamptz not null default now(),
 confirmed_at timestamptz
);

create table public.approvals(
 id uuid primary key default gen_random_uuid(),
 action_type text not null,
 target_id uuid not null,
 requested_by uuid not null references public.profiles(id),
 approved_by uuid references public.profiles(id),
 status public.approval_status not null default 'pending',
 reason text not null,
 created_at timestamptz not null default now(),
 decided_at timestamptz
);

create table public.audit_logs(
 id bigint generated always as identity primary key,
 actor_id uuid references public.profiles(id),
 action text not null,
 entity_type text not null,
 entity_id text,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create table public.shift_sessions(
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null references public.profiles(id),
 opening_cash numeric(12,2) not null default 0,
 closing_cash numeric(12,2),
 opened_at timestamptz not null default now(),
 closed_at timestamptz,
 status text not null default 'open' check(status in ('open','closed'))
);

create index idx_sales_seller_created on public.sales(seller_id,created_at);
create index idx_payments_created on public.payments(created_at);
create index idx_audit_actor_created on public.audit_logs(actor_id,created_at);
create index idx_batches_expiry on public.batches(expiry_date);

alter table public.profiles enable row level security;
alter table public.medicine_categories enable row level security;
alter table public.medicines enable row level security;
alter table public.inventory enable row level security;
alter table public.batches enable row level security;
alter table public.prescriptions enable row level security;
alter table public.prescription_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
alter table public.approvals enable row level security;
alter table public.audit_logs enable row level security;
alter table public.shift_sessions enable row level security;

create or replace function public.current_role() returns public.user_role
language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() and active=true limit 1 $$;

create policy "profiles own read" on public.profiles for select using (id=auth.uid() or public.current_role()='admin');
create policy "admin manage profiles" on public.profiles for all using (public.current_role()='admin') with check (public.current_role()='admin');

create policy "staff read medicines" on public.medicines for select using (public.current_role() in ('admin','seller'));
create policy "admin write medicines" on public.medicines for all using (public.current_role()='admin') with check (public.current_role()='admin');
create policy "staff read inventory" on public.inventory for select using (public.current_role() in ('admin','seller'));
create policy "admin write inventory" on public.inventory for all using (public.current_role()='admin') with check (public.current_role()='admin');

create policy "staff read categories" on public.medicine_categories for select using (public.current_role() in ('admin','seller'));
create policy "admin write categories" on public.medicine_categories for all using (public.current_role()='admin') with check (public.current_role()='admin');

create policy "staff read batches" on public.batches for select using (public.current_role() in ('admin','seller'));
create policy "admin write batches" on public.batches for all using (public.current_role()='admin') with check (public.current_role()='admin');

create policy "staff prescriptions" on public.prescriptions for select using (public.current_role() in ('admin','seller'));
create policy "staff create prescriptions" on public.prescriptions for insert with check (public.current_role() in ('admin','seller') and created_by=auth.uid());
create policy "admin update prescriptions" on public.prescriptions for update using (public.current_role()='admin') with check (public.current_role()='admin');

create policy "staff prescription items read" on public.prescription_items for select using (public.current_role() in ('admin','seller'));
create policy "staff prescription items insert" on public.prescription_items for insert with check (public.current_role() in ('admin','seller'));
create policy "admin prescription items update" on public.prescription_items for update using (public.current_role()='admin') with check (public.current_role()='admin');

create policy "admin all sales" on public.sales for all using (public.current_role()='admin') with check (public.current_role()='admin');
create policy "seller own sales" on public.sales for select using (public.current_role()='seller' and seller_id=auth.uid());
create policy "seller create own sales" on public.sales for insert with check (public.current_role()='seller' and seller_id=auth.uid());

create policy "admin all sale items" on public.sale_items for all using (public.current_role()='admin') with check (public.current_role()='admin');
create policy "seller sale items" on public.sale_items for select using (public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid()));
create policy "seller add sale items" on public.sale_items for insert with check (public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid()));

create policy "admin all payments" on public.payments for all using (public.current_role()='admin') with check (public.current_role()='admin');
create policy "seller own payment read" on public.payments for select using (public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid()));

create policy "admin approvals" on public.approvals for all using (public.current_role()='admin') with check (public.current_role()='admin');
create policy "seller request approvals" on public.approvals for insert with check (public.current_role()='seller' and requested_by=auth.uid());
create policy "admin audit read" on public.audit_logs for select using (public.current_role()='admin');
create policy "admin audit insert" on public.audit_logs for insert with check (public.current_role()='admin');
create policy "seller own shifts" on public.shift_sessions for select using (public.current_role()='seller' and seller_id=auth.uid());
create policy "seller open shift" on public.shift_sessions for insert with check (public.current_role()='seller' and seller_id=auth.uid());
create policy "admin shifts" on public.shift_sessions for all using (public.current_role()='admin') with check (public.current_role()='admin');

create or replace function public.prevent_sensitive_mutation()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()='seller' then
    raise exception 'Sensitive changes require admin authorization';
  end if;
  return coalesce(new,old);
end $$;

create trigger protect_payment_update before update or delete on public.payments
for each row execute function public.prevent_sensitive_mutation();

create trigger protect_audit_update before update or delete on public.audit_logs
for each row execute function public.prevent_sensitive_mutation();

-- ============================================================================
-- 002_business_logic.sql
-- ============================================================================
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

-- ============================================================================
-- 003_suppliers.sql
-- ============================================================================
create table if not exists public.suppliers(id uuid primary key default gen_random_uuid(),name text not null,phone text,email text,address text,active boolean not null default true,created_at timestamptz not null default now());
alter table public.suppliers enable row level security;
drop policy if exists "staff read suppliers" on public.suppliers; create policy "staff read suppliers" on public.suppliers for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage suppliers" on public.suppliers; create policy "admin manage suppliers" on public.suppliers for all using(public.current_role()='admin') with check(public.current_role()='admin');
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ begin insert into public.profiles(id,full_name,role,active) values(new.id,coalesce(new.raw_user_meta_data->>'full_name','Seller'),'seller',true) on conflict(id) do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ============================================================================
-- 004_receipts_and_security.sql
-- ============================================================================
-- Public receipt verification contains only minimal non-sensitive transaction data.
create or replace view public.receipt_verification as
select s.sale_number, s.total_amount, s.status, s.created_at
from public.sales s
where s.status in ('paid','refunded','cancelled');

-- Sellers can read only their own shift history; admins can read all.
drop policy if exists "seller own shifts" on public.shift_sessions;
create policy "seller own shifts" on public.shift_sessions for select using(public.current_role()='admin' or (public.current_role()='seller' and seller_id=auth.uid()));

-- Sellers can never mutate audit logs. Audit records are written only by trusted functions/admin operations.
drop policy if exists "seller audit insert" on public.audit_logs;
drop policy if exists "admin audit insert" on public.audit_logs;
create policy "admin audit insert" on public.audit_logs for insert with check(public.current_role()='admin');

-- Prevent clients from directly changing payment status or historical sale state.
drop policy if exists "admin all payments" on public.payments;
create policy "admin read payments" on public.payments for select using(public.current_role()='admin' or (public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid())));

-- ============================================================================
-- 005_pharmacy_transactions.sql
-- ============================================================================
-- Advanced pharmacy transaction layer. Run after 004_receipts_and_security.sql.

alter table public.sale_items add column if not exists batch_id uuid references public.batches(id);
alter table public.sale_items add column if not exists prescription_item_id uuid references public.prescription_items(id);

alter table public.payments add column if not exists merchant_request_id text;
alter table public.payments add column if not exists checkout_request_id text;
alter table public.payments add column if not exists mpesa_receipt text;
alter table public.payments add column if not exists phone_number text;
alter table public.payments add column if not exists transaction_time timestamptz;
alter table public.payments add column if not exists callback_payload jsonb;
create unique index if not exists uq_payments_checkout on public.payments(checkout_request_id) where checkout_request_id is not null;
create unique index if not exists uq_payments_mpesa_receipt on public.payments(mpesa_receipt) where mpesa_receipt is not null;

create table if not exists public.stock_receipts(
 id uuid primary key default gen_random_uuid(),
 receipt_number text unique not null,
 supplier_name text,
 invoice_number text,
 received_by uuid not null references public.profiles(id),
 total_cost numeric(12,2) not null default 0 check(total_cost>=0),
 status text not null default 'received' check(status in ('received','voided')),
 received_at timestamptz not null default now()
);
create table if not exists public.stock_receipt_items(
 id uuid primary key default gen_random_uuid(),
 receipt_id uuid not null references public.stock_receipts(id) on delete restrict,
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 batch_id uuid not null references public.batches(id) on delete restrict,
 quantity integer not null check(quantity>0),
 unit_cost numeric(12,2) not null check(unit_cost>=0),
 total_cost numeric(12,2) generated always as (quantity*unit_cost) stored
);
create table if not exists public.stock_movements(
 id bigint generated always as identity primary key,
 medicine_id uuid not null references public.medicines(id),
 batch_id uuid references public.batches(id),
 movement_type text not null check(movement_type in ('receive','sale','refund','adjustment','expiry','void_receive')),
 quantity integer not null,
 reference_type text,
 reference_id uuid,
 actor_id uuid references public.profiles(id),
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists idx_stock_movements_created on public.stock_movements(created_at);
create index if not exists idx_stock_movements_medicine on public.stock_movements(medicine_id,created_at);

create table if not exists public.mpesa_callbacks(
 id bigint generated always as identity primary key,
 checkout_request_id text,
 merchant_request_id text,
 result_code integer,
 result_description text,
 raw_payload jsonb not null,
 received_at timestamptz not null default now()
);
create unique index if not exists uq_mpesa_callback_checkout on public.mpesa_callbacks(checkout_request_id);

alter table public.stock_receipts enable row level security;
alter table public.stock_receipt_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.mpesa_callbacks enable row level security;

create policy "admin stock receipts" on public.stock_receipts for select using(public.current_role()='admin');
create policy "admin stock receipt items" on public.stock_receipt_items for select using(public.current_role()='admin');
create policy "admin stock movements" on public.stock_movements for select using(public.current_role()='admin');
create policy "admin mpesa callbacks" on public.mpesa_callbacks for select using(public.current_role()='admin');

create or replace function public.create_prescription(p_patient_name text,p_prescriber_name text,p_prescription_date date,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_number text; i jsonb; v_med uuid; v_qty int;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if nullif(trim(p_patient_name),'') is null then raise exception 'Patient name is required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Prescription requires at least one medicine'; end if;
  v_number:='RX-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_id::text,'-',''),1,6);
  insert into public.prescriptions(id,prescription_number,patient_name,prescriber_name,prescription_date,status,created_by)
  values(v_id,v_number,trim(p_patient_name),nullif(trim(p_prescriber_name),''),coalesce(p_prescription_date,current_date),'received',auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity_prescribed')::int;
    if v_qty is null or v_qty<=0 then raise exception 'Invalid prescribed quantity'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.prescription_items(prescription_id,medicine_id,dosage_instructions,quantity_prescribed)
    values(v_id,v_med,nullif(i->>'dosage_instructions',''),v_qty);
  end loop;
  perform public.audit('PRESCRIPTION_CREATED','prescription',v_id::text,jsonb_build_object('prescription_number',v_number));
  return v_id;
end $$;

create or replace function public.review_prescription(p_prescription_id uuid,p_approve boolean,p_reason text default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_status public.prescription_status;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select status into v_status from public.prescriptions where id=p_prescription_id for update;
  if not found then raise exception 'Prescription not found'; end if;
  update public.prescriptions set status=case when p_approve then 'verified' else 'rejected' end,verified_by=auth.uid(),updated_at=now() where id=p_prescription_id;
  perform public.audit(case when p_approve then 'PRESCRIPTION_VERIFIED' else 'PRESCRIPTION_REJECTED' end,'prescription',p_prescription_id::text,jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.dispense_prescription(p_prescription_id uuid,p_items jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare i jsonb; v_item public.prescription_items%rowtype; v_batch public.batches%rowtype; v_med uuid; v_qty int; v_batch_id uuid; v_remaining int; v_status public.prescription_status;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required for standalone dispensing'; end if;
  select status into v_status from public.prescriptions where id=p_prescription_id for update;
  if v_status not in ('verified','dispensing') then raise exception 'Prescription must be verified before dispensing'; end if;
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity')::int; v_batch_id:=nullif(i->>'batch_id','')::uuid;
    if v_qty is null or v_qty<=0 then raise exception 'Invalid dispensing quantity'; end if;
    select * into v_item from public.prescription_items where prescription_id=p_prescription_id and medicine_id=v_med for update;
    if not found then raise exception 'Medicine is not on this prescription'; end if;
    v_remaining:=v_item.quantity_prescribed-v_item.quantity_dispensed;
    if v_qty>v_remaining then raise exception 'Dispensing quantity exceeds prescribed quantity'; end if;
    if v_batch_id is not null then
      select * into v_batch from public.batches where id=v_batch_id and medicine_id=v_med for update;
      if not found then raise exception 'Selected batch is invalid'; end if;
      if v_batch.expiry_date<current_date then raise exception 'Selected batch has expired'; end if;
      if v_batch.quantity<v_qty then raise exception 'Selected batch has insufficient stock'; end if;
      update public.batches set quantity=quantity-v_qty where id=v_batch.id;
    else
      select * into v_batch from public.batches where medicine_id=v_med and expiry_date>=current_date and quantity>0 order by expiry_date,received_at limit 1 for update;
      if not found or v_batch.quantity<v_qty then raise exception 'No suitable unexpired batch has enough stock'; end if;
      update public.batches set quantity=quantity-v_qty where id=v_batch.id;
    end if;
    update public.inventory set quantity=quantity-v_qty where medicine_id=v_med and quantity>=v_qty;
    if not found then raise exception 'Inventory mismatch'; end if;
    update public.prescription_items set quantity_dispensed=quantity_dispensed+v_qty where id=v_item.id;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(v_med,v_batch.id,'sale',-v_qty,'prescription',p_prescription_id,auth.uid(),jsonb_build_object('dispensed',true));
  end loop;
  update public.prescriptions set status=case when not exists(select 1 from public.prescription_items where prescription_id=p_prescription_id and quantity_dispensed<quantity_prescribed) then 'completed' else 'dispensed' end,updated_at=now() where id=p_prescription_id;
  perform public.audit('PRESCRIPTION_DISPENSED','prescription',p_prescription_id::text,jsonb_build_object('items',p_items));
end $$;

create or replace function public.receive_stock(p_supplier_name text,p_invoice_number text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_receipt uuid:=gen_random_uuid(); v_number text; i jsonb; v_med uuid; v_qty int; v_cost numeric; v_batch uuid; v_total numeric(12,2):=0;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Receiving requires items'; end if;
  v_number:='GRN-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_receipt::text,'-',''),1,6);
  insert into public.stock_receipts(id,receipt_number,supplier_name,invoice_number,received_by) values(v_receipt,v_number,nullif(trim(p_supplier_name),''),nullif(trim(p_invoice_number),''),auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity')::int; v_cost:=(i->>'unit_cost')::numeric;
    if v_qty is null or v_qty<=0 or v_cost is null or v_cost<0 then raise exception 'Invalid receiving item'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.batches(medicine_id,batch_number,expiry_date,quantity,supplier_name)
    values(v_med,trim(i->>'batch_number'),(i->>'expiry_date')::date,v_qty,nullif(trim(p_supplier_name),''))
    on conflict(medicine_id,batch_number) do update set quantity=public.batches.quantity+excluded.quantity,expiry_date=excluded.expiry_date,supplier_name=excluded.supplier_name
    returning id into v_batch;
    insert into public.stock_receipt_items(receipt_id,medicine_id,batch_id,quantity,unit_cost) values(v_receipt,v_med,v_batch,v_qty,v_cost);
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(v_med,v_batch,'receive',v_qty,'stock_receipt',v_receipt,auth.uid(),jsonb_build_object('batch_number',i->>'batch_number','expiry_date',i->>'expiry_date'));
    insert into public.inventory(medicine_id,quantity) values(v_med,v_qty) on conflict(medicine_id) do update set quantity=public.inventory.quantity+excluded.quantity;
    v_total:=v_total+(v_qty*v_cost);
  end loop;
  update public.stock_receipts set total_cost=v_total where id=v_receipt;
  perform public.audit('STOCK_RECEIVED','stock_receipt',v_receipt::text,jsonb_build_object('total_cost',v_total,'receipt_number',v_number));
  return v_receipt;
end $$;

create or replace function public.prepare_mpesa_payment(p_sale_id uuid,p_phone text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype; v_id uuid;
begin
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Phone number is required'; end if;
  insert into public.payments(sale_id,method,amount,phone_number,status) values(p_sale_id,'mpesa',v_sale.total_amount,trim(p_phone),'pending') returning id into v_id;
  perform public.audit('MPESA_PAYMENT_PREPARED','payment',v_id::text,jsonb_build_object('sale_id',p_sale_id,'amount',v_sale.total_amount));
  return v_id;
end $$;

create or replace function public.apply_mpesa_callback(p_checkout_request_id text,p_merchant_request_id text,p_result_code integer,p_result_description text,p_receipt text,p_amount numeric,p_phone text,p_transaction_time timestamptz,p_payload jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare p public.payments%rowtype; s public.sales%rowtype; r record; v_batch_id uuid;
begin
  if p_checkout_request_id is null then raise exception 'CheckoutRequestID required'; end if;
  insert into public.mpesa_callbacks(checkout_request_id,merchant_request_id,result_code,result_description,raw_payload)
  values(p_checkout_request_id,p_merchant_request_id,p_result_code,p_result_description,p_payload)
  on conflict(checkout_request_id) do nothing;
  select * into p from public.payments where checkout_request_id=p_checkout_request_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if p.status='paid' then return; end if;
  select * into s from public.sales where id=p.sale_id for update;
  if p_result_code<>0 then update public.payments set status='failed',callback_payload=p_payload where id=p.id; return; end if;
  if abs(p_amount-p.amount)>0.01 then raise exception 'M-Pesa amount does not match sale'; end if;
  if p.phone_number is not null and p_phone is not null and regexp_replace(p.phone_number,'[^0-9]','','g')<>regexp_replace(p_phone,'[^0-9]','','g') then raise exception 'M-Pesa phone does not match payment request'; end if;
  if s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  for r in select * from public.sale_items where sale_id=s.id for update loop
    v_batch_id:=r.batch_id;
    if v_batch_id is not null then
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id and expiry_date>=current_date and quantity>=r.quantity;
      if not found then raise exception 'Selected batch unavailable while completing M-Pesa payment'; end if;
    else
      select b.id into v_batch_id from public.batches b where b.medicine_id=r.medicine_id and b.expiry_date>=current_date and b.quantity>=r.quantity order by b.expiry_date,b.received_at limit 1 for update;
      if v_batch_id is null then raise exception 'No suitable batch available while completing M-Pesa payment'; end if;
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id;
      update public.sale_items set batch_id=v_batch_id where id=r.id;
    end if;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock unavailable while completing M-Pesa payment'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,v_batch_id,'sale',-r.quantity,'sale',s.id,null,jsonb_build_object('mpesa_receipt',p_receipt));
  end loop;
  update public.payments set status='paid',confirmed_at=now(),mpesa_receipt=p_receipt,merchant_request_id=p_merchant_request_id,phone_number=coalesce(p_phone,phone_number),transaction_time=p_transaction_time,callback_payload=p_payload where id=p.id;
  update public.sales set status='paid' where id=s.id;
end $$;

create or replace function public.financial_report(p_from date,p_to date)
returns table(report_date date, sales_count bigint,gross_sales numeric,total_paid numeric,cash_paid numeric,mpesa_paid numeric,other_paid numeric,refunded numeric)
language sql stable security definer set search_path=public as $$
  with days as (select d::date report_date from generate_series(p_from::timestamptz,p_to::timestamptz,interval '1 day') d),
  s as (select created_at::date report_date,count(*) filter(where status='paid') sales_count,coalesce(sum(total_amount) filter(where status='paid'),0) gross_sales from public.sales group by created_at::date),
  p as (select created_at::date report_date,coalesce(sum(amount) filter(where status='paid'),0) total_paid,coalesce(sum(amount) filter(where status='paid' and method='cash'),0) cash_paid,coalesce(sum(amount) filter(where status='paid' and method='mpesa'),0) mpesa_paid,coalesce(sum(amount) filter(where status='paid' and method='other'),0) other_paid,coalesce(sum(amount) filter(where status='refunded'),0) refunded from public.payments group by created_at::date)
  select d.report_date,coalesce(s.sales_count,0),coalesce(s.gross_sales,0),coalesce(p.total_paid,0),coalesce(p.cash_paid,0),coalesce(p.mpesa_paid,0),coalesce(p.other_paid,0),coalesce(p.refunded,0)
  from days d left join s using(report_date) left join p using(report_date)
  where public.current_role()='admin' order by d.report_date;
$$;

-- Replace the original sale creation/payment confirmation with batch-aware, prescription-aware logic.
create or replace function public.create_sale(p_items jsonb,p_prescription_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid:=gen_random_uuid(); v_number text; v_total numeric(12,2):=0; item jsonb; v_price numeric; v_qty int; v_med uuid; v_stock int; v_required boolean; v_rem int; v_pi uuid; v_batch_id uuid;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Sale requires items'; end if;
  if p_prescription_id is not null and not exists(select 1 from public.prescriptions where id=p_prescription_id and status in ('verified','dispensing','dispensed')) then raise exception 'Prescription is not verified'; end if;
  v_number:='SALE-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_sale_id::text,'-',''),1,6);
  insert into public.sales(id,sale_number,seller_id,prescription_id,total_amount,status) values(v_sale_id,v_number,auth.uid(),p_prescription_id,0,'pending_payment');
  for item in select * from jsonb_array_elements(p_items) loop
    v_med:=(item->>'medicine_id')::uuid; v_qty:=(item->>'quantity')::int; v_batch_id:=nullif(item->>'batch_id','')::uuid;
    if v_qty<=0 then raise exception 'Invalid quantity'; end if;
    select selling_price,prescription_required into v_price,v_required from public.medicines where id=v_med and active=true;
    if v_price is null then raise exception 'Medicine unavailable'; end if;
    if v_required and p_prescription_id is null then raise exception 'Prescription required for this medicine'; end if;
    if p_prescription_id is not null then
      select id,quantity_prescribed-quantity_dispensed into v_pi,v_rem from public.prescription_items where prescription_id=p_prescription_id and medicine_id=v_med for update;
      if v_pi is null or v_rem<v_qty then raise exception 'Sale quantity exceeds prescription balance'; end if;
    end if;
    select quantity into v_stock from public.inventory where medicine_id=v_med for update;
    if coalesce(v_stock,0)<v_qty then raise exception 'Insufficient stock for medicine %',v_med; end if;
    if v_batch_id is not null then
      if not exists(select 1 from public.batches where id=v_batch_id and medicine_id=v_med and expiry_date>=current_date) then raise exception 'Selected batch is invalid or expired'; end if;
    end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price,prescription_item_id,batch_id) values(v_sale_id,v_med,v_qty,v_price,v_pi,v_batch_id);
    v_total:=v_total+v_qty*v_price;
  end loop;
  update public.sales set total_amount=v_total where id=v_sale_id;
  perform public.audit('SALE_CREATED','sale',v_sale_id::text,jsonb_build_object('total',v_total,'prescription_id',p_prescription_id));
  return v_sale_id;
end $$;

create or replace function public.confirm_sale_payment(p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype; r record; b public.batches%rowtype; v_remaining int;
begin
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if p_amount<>v_sale.total_amount then raise exception 'Payment amount does not match sale total'; end if;
  if p_method not in ('mpesa','cash','other') then raise exception 'Invalid payment method'; end if;
  if p_method='mpesa' then raise exception 'Use the secure M-Pesa payment flow'; end if;
  for r in select * from public.sale_items where sale_id=p_sale_id for update loop
    if r.batch_id is not null then
      select * into b from public.batches where id=r.batch_id and medicine_id=r.medicine_id for update;
      if not found or b.expiry_date<current_date or b.quantity<r.quantity then raise exception 'Selected batch unavailable or expired'; end if;
      update public.batches set quantity=quantity-r.quantity where id=b.id;
    else
      select * into b from public.batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>0 order by expiry_date,received_at limit 1 for update;
      if not found or b.quantity<r.quantity then raise exception 'No suitable unexpired batch has enough stock'; end if;
      update public.batches set quantity=quantity-r.quantity where id=b.id;
      update public.sale_items set batch_id=b.id where id=r.id;
    end if;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock changed; payment not completed'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(r.medicine_id,b.id,'sale',-r.quantity,'sale',p_sale_id,auth.uid(),'{}');
    if r.prescription_item_id is not null then update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id; end if;
  end loop;
  insert into public.payments(sale_id,method,amount,provider_reference,status,confirmed_at) values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  update public.sales set status='paid' where id=p_sale_id;
  perform public.audit('PAYMENT_CONFIRMED','sale',p_sale_id::text,jsonb_build_object('method',p_method,'amount',p_amount,'reference',p_reference));
  return p_sale_id;
end $$;

-- Rebuild refund approval so approved refunds restore the exact sold batches.
create or replace function public.decide_approval(p_approval_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare a public.approvals%rowtype; s public.sales%rowtype; r record;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into a from public.approvals where id=p_approval_id for update;
  if not found or a.status<>'pending' then raise exception 'Approval unavailable'; end if;
  if p_approve and a.action_type='refund' then
    select * into s from public.sales where id=a.target_id for update;
    if s.status<>'paid' then raise exception 'Sale is not refundable'; end if;
    for r in select * from public.sale_items where sale_id=s.id loop
      if r.batch_id is not null then update public.batches set quantity=quantity+r.quantity where id=r.batch_id;
      else update public.inventory set quantity=quantity+r.quantity where medicine_id=r.medicine_id; end if;
      update public.inventory set quantity=quantity+r.quantity where medicine_id=r.medicine_id and r.batch_id is not null;
      insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(r.medicine_id,r.batch_id,'refund',r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('approval_id',a.id));
    end loop;
    update public.sales set status='refunded' where id=s.id;
    update public.payments set status='refunded' where sale_id=s.id and status='paid';
  elsif p_approve and a.action_type='cancel_sale' then
    update public.sales set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid() where id=a.target_id and status='pending_payment';
  end if;
  update public.approvals set approved_by=auth.uid(),status=case when p_approve then 'approved' else 'rejected' end,decided_at=now() where id=p_approval_id;
  perform public.audit(case when p_approve then 'APPROVAL_APPROVED' else 'APPROVAL_REJECTED' end,a.action_type,a.target_id::text,jsonb_build_object('approval_id',p_approval_id));
end $$;

revoke all on function public.create_prescription(text,text,date,jsonb) from public;
revoke all on function public.review_prescription(uuid,boolean,text) from public;
revoke all on function public.dispense_prescription(uuid,jsonb) from public;
revoke all on function public.receive_stock(text,text,jsonb) from public;
revoke all on function public.prepare_mpesa_payment(uuid,text) from public;
revoke all on function public.apply_mpesa_callback(text,text,integer,text,text,numeric,text,timestamptz,jsonb) from public;
revoke all on function public.financial_report(date,date) from public;
revoke all on function public.create_sale(jsonb,uuid) from public;
revoke all on function public.confirm_sale_payment(uuid,text,numeric,text) from public;
revoke all on function public.decide_approval(uuid,boolean) from public;
grant execute on function public.create_prescription(text,text,date,jsonb) to authenticated;
grant execute on function public.review_prescription(uuid,boolean,text) to authenticated;
grant execute on function public.dispense_prescription(uuid,jsonb) to authenticated;
grant execute on function public.receive_stock(text,text,jsonb) to authenticated;
grant execute on function public.prepare_mpesa_payment(uuid,text) to authenticated;
grant execute on function public.apply_mpesa_callback(text,text,integer,text,text,numeric,text,timestamptz,jsonb) to service_role;
grant execute on function public.financial_report(date,date) to authenticated;
grant execute on function public.create_sale(jsonb,uuid) to authenticated;
grant execute on function public.confirm_sale_payment(uuid,text,numeric,text) to authenticated;
grant execute on function public.decide_approval(uuid,boolean) to authenticated;

create or replace function public.apply_mpesa_c2b_callback(p_receipt text,p_sale_number text,p_amount numeric,p_phone text,p_transaction_time timestamptz,p_payload jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare s public.sales%rowtype; r record; v_batch_id uuid;
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
  update public.sales set status='paid' where id=s.id;
end $$;
revoke all on function public.apply_mpesa_c2b_callback(text,text,numeric,text,timestamptz,jsonb) from public;
grant execute on function public.apply_mpesa_c2b_callback(text,text,numeric,text,timestamptz,jsonb) to service_role;

-- ============================================================================
-- 006_security_hardening.sql
-- ============================================================================
-- Remove direct seller mutation paths that could bypass transactional validation.
drop policy if exists "seller create own sales" on public.sales;
drop policy if exists "seller add sale items" on public.sale_items;
drop policy if exists "staff create prescriptions" on public.prescriptions;
drop policy if exists "staff prescription items insert" on public.prescription_items;
drop policy if exists "seller open shift" on public.shift_sessions;
drop policy if exists "seller request approvals" on public.approvals;

-- Sellers should not be able to mutate payment records directly.
drop policy if exists "seller own payment read" on public.payments;
create policy "seller own payment read" on public.payments for select using(public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid()));

-- Transactional tables have no seller UPDATE/DELETE policies; sensitive state transitions are performed by SECURITY DEFINER functions.

revoke all on function public.request_action(text,uuid,text) from public;
grant execute on function public.request_action(text,uuid,text) to authenticated;

-- ============================================================================
-- 007_operations_upgrade.sql
-- ============================================================================
-- Operations upgrade: alerts, barcode support, expenses, stock-adjustment approvals,
-- price history, daily performance and dashboard summaries.

alter table public.medicines add column if not exists barcode text;
alter table public.medicines add column if not exists manufacturer text;
alter table public.medicines add column if not exists reorder_level integer not null default 0 check(reorder_level>=0);
alter table public.medicines add column if not exists controlled_medicine boolean not null default false;
create unique index if not exists uq_medicines_barcode on public.medicines(barcode) where barcode is not null and trim(barcode)<>'';

create table if not exists public.medicine_price_history(
 id bigint generated always as identity primary key,
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 old_selling_price numeric(12,2),
 new_selling_price numeric(12,2),
 old_purchase_price numeric(12,2),
 new_purchase_price numeric(12,2),
 changed_by uuid references public.profiles(id),
 changed_at timestamptz not null default now()
);

create or replace function public.log_medicine_price_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if coalesce(old.selling_price,-1)<>coalesce(new.selling_price,-1)
     or coalesce(old.purchase_price,-1)<>coalesce(new.purchase_price,-1) then
    insert into public.medicine_price_history(medicine_id,old_selling_price,new_selling_price,old_purchase_price,new_purchase_price,changed_by)
    values(new.id,old.selling_price,new.selling_price,old.purchase_price,new.purchase_price,auth.uid());
    perform public.audit('MEDICINE_PRICE_CHANGED','medicine',new.id::text,jsonb_build_object('old_selling',old.selling_price,'new_selling',new.selling_price,'old_purchase',old.purchase_price,'new_purchase',new.purchase_price));
  end if;
  return new;
end $$;
drop trigger if exists trg_medicine_price_history on public.medicines;
create trigger trg_medicine_price_history after update on public.medicines for each row execute function public.log_medicine_price_change();

create table if not exists public.expenses(
 id uuid primary key default gen_random_uuid(),
 expense_number text unique not null,
 category text not null,
 description text not null,
 amount numeric(12,2) not null check(amount>0),
 payment_method text not null default 'cash' check(payment_method in ('cash','mpesa','bank','other')),
 reference text,
 expense_date date not null default current_date,
 recorded_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);

create table if not exists public.stock_adjustment_requests(
 id uuid primary key default gen_random_uuid(),
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 batch_id uuid references public.batches(id) on delete restrict,
 quantity_change integer not null check(quantity_change<>0),
 reason text not null,
 requested_by uuid not null references public.profiles(id),
 status public.approval_status not null default 'pending',
 approved_by uuid references public.profiles(id),
 decided_at timestamptz,
 created_at timestamptz not null default now()
);

create index if not exists idx_stock_adjustments_status on public.stock_adjustment_requests(status,created_at);
create index if not exists idx_expenses_date on public.expenses(expense_date);

alter table public.medicine_price_history enable row level security;
alter table public.expenses enable row level security;
alter table public.stock_adjustment_requests enable row level security;
create policy "admin price history" on public.medicine_price_history for select using(public.current_role()='admin');
create policy "admin expenses" on public.expenses for select using(public.current_role()='admin');
create policy "admin adjustment requests" on public.stock_adjustment_requests for select using(public.current_role()='admin');
create policy "seller own adjustment requests" on public.stock_adjustment_requests for select using(public.current_role()='seller' and requested_by=auth.uid());

create or replace function public.record_expense(p_category text,p_description text,p_amount numeric,p_method text default 'cash',p_reference text default null,p_date date default current_date)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_no text;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Expense amount must be greater than zero'; end if;
  if p_method not in ('cash','mpesa','bank','other') then raise exception 'Invalid expense payment method'; end if;
  v_no:='EXP-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_id::text,'-',''),1,5);
  insert into public.expenses(id,expense_number,category,description,amount,payment_method,reference,expense_date,recorded_by)
  values(v_id,v_no,trim(p_category),trim(p_description),p_amount,p_method,nullif(trim(p_reference),''),coalesce(p_date,current_date),auth.uid());
  perform public.audit('EXPENSE_RECORDED','expense',v_id::text,jsonb_build_object('amount',p_amount,'category',p_category));
  return v_id;
end $$;

create or replace function public.request_stock_adjustment(p_medicine_id uuid,p_batch_id uuid,p_quantity_change integer,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role() not in ('seller','admin') then raise exception 'Unauthorized'; end if;
  if p_quantity_change is null or p_quantity_change=0 then raise exception 'Adjustment quantity cannot be zero'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Reason is required'; end if;
  if not exists(select 1 from public.medicines where id=p_medicine_id and active=true) then raise exception 'Medicine unavailable'; end if;
  if p_batch_id is not null and not exists(select 1 from public.batches where id=p_batch_id and medicine_id=p_medicine_id) then raise exception 'Invalid batch'; end if;
  insert into public.stock_adjustment_requests(medicine_id,batch_id,quantity_change,reason,requested_by)
  values(p_medicine_id,p_batch_id,p_quantity_change,trim(p_reason),auth.uid()) returning id into v_id;
  perform public.audit('STOCK_ADJUSTMENT_REQUESTED','stock_adjustment',v_id::text,jsonb_build_object('medicine_id',p_medicine_id,'quantity_change',p_quantity_change,'reason',p_reason));
  return v_id;
end $$;

create or replace function public.decide_stock_adjustment(p_request_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare r public.stock_adjustment_requests%rowtype;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into r from public.stock_adjustment_requests where id=p_request_id for update;
  if not found or r.status<>'pending' then raise exception 'Adjustment request unavailable'; end if;
  if p_approve then
    if r.batch_id is not null then
      update public.batches set quantity=quantity+r.quantity_change where id=r.batch_id and quantity+r.quantity_change>=0;
      if not found then raise exception 'Batch cannot accept this adjustment'; end if;
    end if;
    update public.inventory set quantity=quantity+r.quantity_change where medicine_id=r.medicine_id and quantity+r.quantity_change>=0;
    if not found then raise exception 'Inventory cannot accept this adjustment'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,r.batch_id,'adjustment',r.quantity_change,'stock_adjustment',r.id,auth.uid(),jsonb_build_object('reason',r.reason));
  end if;
  update public.stock_adjustment_requests set status=case when p_approve then 'approved' else 'rejected' end,approved_by=auth.uid(),decided_at=now() where id=r.id;
  perform public.audit(case when p_approve then 'STOCK_ADJUSTMENT_APPROVED' else 'STOCK_ADJUSTMENT_REJECTED' end,'stock_adjustment',r.id::text,jsonb_build_object('quantity_change',r.quantity_change));
end $$;

create or replace function public.dashboard_summary()
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'medicines',(select count(*) from public.medicines where active),
    'stock_units',(select coalesce(sum(quantity),0) from public.inventory),
    'low_stock',(select count(*) from public.inventory where low_stock),
    'out_of_stock',(select count(*) from public.inventory where quantity=0),
    'expiring_30_days',(select count(*) from public.batches where expiry_date between current_date and current_date+30 and quantity>0),
    'expired_stock',(select count(*) from public.batches where expiry_date<current_date and quantity>0),
    'pending_approvals',(select count(*) from public.approvals where status='pending')+(select count(*) from public.stock_adjustment_requests where status='pending'),
    'pending_prescriptions',(select count(*) from public.prescriptions where status in ('received','under_review')),
    'today_sales',(select coalesce(sum(total_amount),0) from public.sales where status='paid' and created_at::date=current_date),
    'today_mpesa',(select coalesce(sum(amount),0) from public.payments where status='paid' and method='mpesa' and created_at::date=current_date),
    'today_cash',(select coalesce(sum(amount),0) from public.payments where status='paid' and method='cash' and created_at::date=current_date),
    'today_expenses',(select coalesce(sum(amount),0) from public.expenses where expense_date=current_date)
  ) where public.current_role()='admin';
$$;

create or replace function public.seller_daily_summary(p_seller_id uuid default auth.uid())
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'sales_count',(select count(*) from public.sales where seller_id=p_seller_id and status='paid' and created_at::date=current_date),
    'sales_total',(select coalesce(sum(total_amount),0) from public.sales where seller_id=p_seller_id and status='paid' and created_at::date=current_date),
    'mpesa_total',(select coalesce(sum(p.amount),0) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=p_seller_id and p.status='paid' and p.method='mpesa' and p.created_at::date=current_date),
    'cash_total',(select coalesce(sum(p.amount),0) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=p_seller_id and p.status='paid' and p.method='cash' and p.created_at::date=current_date),
    'open_shift',(select count(*) from public.shift_sessions where seller_id=p_seller_id and status='open')
  ) where public.current_role() in ('seller','admin') and (public.current_role()='admin' or p_seller_id=auth.uid());
$$;

drop function if exists public.financial_report(date,date);
create function public.financial_report(p_from date,p_to date)
returns table(report_date date,sales_count bigint,gross_sales numeric,total_paid numeric,cash_paid numeric,mpesa_paid numeric,other_paid numeric,refunded numeric,expenses numeric,net_cashflow numeric)
language sql stable security definer set search_path=public as $$
  with days as (select d::date report_date from generate_series(p_from::timestamptz,p_to::timestamptz,interval '1 day') d),
  s as (select created_at::date report_date,count(*) filter(where status='paid') sales_count,coalesce(sum(total_amount) filter(where status='paid'),0) gross_sales from public.sales group by created_at::date),
  p as (select created_at::date report_date,coalesce(sum(amount) filter(where status='paid'),0) total_paid,coalesce(sum(amount) filter(where status='paid' and method='cash'),0) cash_paid,coalesce(sum(amount) filter(where status='paid' and method='mpesa'),0) mpesa_paid,coalesce(sum(amount) filter(where status='paid' and method='other'),0) other_paid,coalesce(sum(amount) filter(where status='refunded'),0) refunded from public.payments group by created_at::date),
  e as (select expense_date report_date,coalesce(sum(amount),0) expenses from public.expenses group by expense_date)
  select d.report_date,coalesce(s.sales_count,0),coalesce(s.gross_sales,0),coalesce(p.total_paid,0),coalesce(p.cash_paid,0),coalesce(p.mpesa_paid,0),coalesce(p.other_paid,0),coalesce(p.refunded,0),coalesce(e.expenses,0),coalesce(p.total_paid,0)-coalesce(p.refunded,0)-coalesce(e.expenses,0)
  from days d left join s using(report_date) left join p using(report_date) left join e using(report_date) order by d.report_date;
$$;

revoke all on function public.record_expense(text,text,numeric,text,text,date) from public;
revoke all on function public.request_stock_adjustment(uuid,uuid,integer,text) from public;
revoke all on function public.decide_stock_adjustment(uuid,boolean) from public;
revoke all on function public.dashboard_summary() from public;
revoke all on function public.seller_daily_summary(uuid) from public;
grant execute on function public.record_expense(text,text,numeric,text,text,date) to authenticated;
grant execute on function public.request_stock_adjustment(uuid,uuid,integer,text) to authenticated;
grant execute on function public.decide_stock_adjustment(uuid,boolean) to authenticated;
grant execute on function public.dashboard_summary() to authenticated;
grant execute on function public.seller_daily_summary(uuid) to authenticated;
grant execute on function public.financial_report(date,date) to authenticated;

-- ============================================================================
-- 008_admin_financial_dashboard.sql
-- ============================================================================
-- Advanced admin financial dashboard and management metrics
create or replace function public.admin_financial_overview()
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  with today_sales as (
    select count(*)::bigint count, coalesce(sum(total_amount),0)::numeric total
    from public.sales where status='paid' and created_at::date=current_date
  ),
  today_payments as (
    select
      coalesce(sum(amount) filter(where status='paid'),0)::numeric paid,
      coalesce(sum(amount) filter(where status='paid' and method='cash'),0)::numeric cash,
      coalesce(sum(amount) filter(where status='paid' and method='mpesa'),0)::numeric mpesa,
      coalesce(sum(amount) filter(where status='paid' and method='other'),0)::numeric other,
      coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunded
    from public.payments where created_at::date=current_date
  ),
  today_expenses as (
    select coalesce(sum(amount),0)::numeric total from public.expenses where expense_date=current_date
  ),
  week as (
    select d::date report_date,
      coalesce((select sum(s.total_amount) from public.sales s where s.status='paid' and s.created_at::date=d::date),0)::numeric sales,
      coalesce((select sum(p.amount) from public.payments p where p.status='paid' and p.created_at::date=d::date),0)::numeric payments,
      coalesce((select sum(e.amount) from public.expenses e where e.expense_date=d::date),0)::numeric expenses
    from generate_series(current_date-6,current_date,interval '1 day') d
  ),
  sellers as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'seller_id',x.seller_id,'seller_name',x.seller_name,'sales_count',x.sales_count,'sales_total',x.sales_total
    ) order by x.sales_total desc),'[]'::jsonb) data
    from (
      select s.seller_id, coalesce(p.full_name,'Seller') seller_name, count(*)::bigint sales_count, coalesce(sum(s.total_amount),0)::numeric sales_total
      from public.sales s left join public.profiles p on p.id=s.seller_id
      where s.status='paid' and s.created_at::date=current_date
      group by s.seller_id,p.full_name
    ) x
  )
  select jsonb_build_object(
    'today',jsonb_build_object(
      'sales_count',(select count from today_sales),
      'sales_total',(select total from today_sales),
      'paid',(select paid from today_payments),
      'cash',(select cash from today_payments),
      'mpesa',(select mpesa from today_payments),
      'other',(select other from today_payments),
      'refunded',(select refunded from today_payments),
      'expenses',(select total from today_expenses),
      'net',(select paid from today_payments)-(select refunded from today_payments)-(select total from today_expenses)
    ),
    'week',(select coalesce(jsonb_agg(jsonb_build_object('date',report_date,'sales',sales,'payments',payments,'expenses',expenses) order by report_date),'[]'::jsonb) from week),
    'sellers',(select data from sellers)
  ) where public.current_role()='admin';
$$;

revoke all on function public.admin_financial_overview() from public;
grant execute on function public.admin_financial_overview() to authenticated;

-- ============================================================================
-- 009_csv_reporting_and_advanced_ops.sql
-- ============================================================================
-- Advanced reporting/export layer for Admin and Seller portals.
-- All exports are generated from server-side, role-filtered queries.

create or replace function public.admin_csv_export(p_from date default current_date, p_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_from date := coalesce(p_from,current_date);
  v_to date := coalesce(p_to,current_date);
  v_result jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if v_from>v_to then raise exception 'Start date cannot be after end date'; end if;
  if v_to-v_from>366 then raise exception 'Export range cannot exceed 366 days'; end if;

  select jsonb_build_object(
    'sales', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number, p.full_name seller, s.total_amount, s.status, s.created_at,
             coalesce(sum(pay.amount) filter(where pay.status='paid'),0)::numeric paid_amount
      from public.sales s
      left join public.profiles p on p.id=s.seller_id
      left join public.payments pay on pay.sale_id=s.id
      where s.created_at::date between v_from and v_to
      group by s.id,s.sale_number,p.full_name,s.total_amount,s.status,s.created_at
    ) x),'[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number,pay.method,pay.amount,pay.status,pay.provider_reference,pay.created_at,p.full_name seller
      from public.payments pay join public.sales s on s.id=pay.sale_id left join public.profiles p on p.id=s.seller_id
      where pay.created_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'inventory', coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from (
      select m.name,m.generic_name,m.brand,m.barcode,m.strength,m.dosage_form,i.quantity,m.selling_price,m.purchase_price,m.active
      from public.medicines m join public.inventory i on i.medicine_id=m.id
    ) x),'[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(x) order by x.expense_date desc,x.created_at desc) from (
      select expense_number,category,description,amount,payment_method,reference,expense_date,created_at
      from public.expenses where expense_date between v_from and v_to
    ) x),'[]'::jsonb),
    'from',v_from,'to',v_to
  ) into v_result;
  return v_result;
end $$;

create or replace function public.seller_csv_export(p_from date default current_date, p_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_from date := coalesce(p_from,current_date);
  v_to date := coalesce(p_to,current_date);
  v_result jsonb;
begin
  if public.current_role()<>'seller' then raise exception 'Seller authorization required'; end if;
  if v_from>v_to then raise exception 'Start date cannot be after end date'; end if;
  if v_to-v_from>366 then raise exception 'Export range cannot exceed 366 days'; end if;

  select jsonb_build_object(
    'sales', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number,s.total_amount,s.status,s.created_at,
             coalesce(sum(pay.amount) filter(where pay.status='paid'),0)::numeric paid_amount
      from public.sales s left join public.payments pay on pay.sale_id=s.id
      where s.seller_id=auth.uid() and s.created_at::date between v_from and v_to
      group by s.id,s.sale_number,s.total_amount,s.status,s.created_at
    ) x),'[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number,pay.method,pay.amount,pay.status,pay.provider_reference,pay.created_at
      from public.payments pay join public.sales s on s.id=pay.sale_id
      where s.seller_id=auth.uid() and pay.created_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(x) order by x.opened_at desc) from (
      select opening_cash,closing_cash,status,opened_at,closed_at
      from public.shift_sessions where seller_id=auth.uid() and opened_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select m.name,a.quantity_change,a.reason,a.status,a.created_at,a.decided_at
      from public.stock_adjustment_requests a join public.medicines m on m.id=a.medicine_id
      where a.requested_by=auth.uid() and a.created_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'from',v_from,'to',v_to
  ) into v_result;
  return v_result;
end $$;

create or replace function public.seller_reconciliation(p_shift_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_id uuid:=p_shift_id; v_result jsonb;
begin
  if public.current_role()<>'seller' then raise exception 'Seller authorization required'; end if;
  if v_id is null then select id into v_id from public.shift_sessions where seller_id=auth.uid() and status='open' order by opened_at desc limit 1; end if;
  if v_id is null then return jsonb_build_object('shift',null,'sales_total',0,'cash',0,'mpesa',0,'other',0,'expected_cash',0); end if;
  select jsonb_build_object(
    'shift',to_jsonb(sh),
    'sales_total',coalesce((select sum(s.total_amount) from public.sales s where s.seller_id=auth.uid() and s.status='paid' and s.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'cash',coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='cash' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'mpesa',coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='mpesa' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'other',coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='other' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'expected_cash',sh.opening_cash+coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='cash' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0)
  ) into v_result from public.shift_sessions sh where sh.id=v_id and sh.seller_id=auth.uid();
  return coalesce(v_result,jsonb_build_object('shift',null,'sales_total',0,'cash',0,'mpesa',0,'other',0,'expected_cash',0));
end $$;

revoke all on function public.admin_csv_export(date,date) from public;
revoke all on function public.seller_csv_export(date,date) from public;
revoke all on function public.seller_reconciliation(uuid) from public;
grant execute on function public.admin_csv_export(date,date) to authenticated;
grant execute on function public.seller_csv_export(date,date) to authenticated;
grant execute on function public.seller_reconciliation(uuid) to authenticated;

-- ============================================================================
-- 010_security_and_staff_management.sql
-- ============================================================================
-- Security and staff management hardening
create or replace function public.set_seller_active(p_user_id uuid,p_active boolean)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if public.current_role() <> 'admin' then raise exception 'Admin access required'; end if;
 if not exists(select 1 from public.profiles where id=p_user_id and role='seller') then raise exception 'Seller account not found'; end if;
 update public.profiles set active=p_active where id=p_user_id;
 insert into public.audit_logs(actor_id,action,entity,entity_id,details) values(auth.uid(),case when p_active then 'seller_activated' else 'seller_disabled' end,'profiles',p_user_id,jsonb_build_object('active',p_active));
 return true;
end $$;
revoke all on function public.set_seller_active(uuid,boolean) from public;
grant execute on function public.set_seller_active(uuid,boolean) to authenticated;

-- Prevent sellers from changing their own role or activation state through direct profile updates.
drop policy if exists "profiles own update" on public.profiles;
create policy "profiles own limited update" on public.profiles for update using(id=auth.uid() and public.current_role()='seller') with check(id=auth.uid() and role='seller' and active=true);

-- ============================================================================
-- 011_advanced_security_operations.sql
-- ============================================================================
-- Advanced security + management analytics

create or replace function public.admin_operations_snapshot()
returns jsonb
language sql stable security definer set search_path=public
as $$
  with paid_sales as (
    select s.id,s.seller_id,s.total_amount,s.created_at
    from public.sales s where s.status='paid'
  ),
  cogs as (
    select coalesce(sum(si.quantity * m.purchase_price),0)::numeric value
    from public.sale_items si join public.medicines m on m.id=si.medicine_id
    join public.sales s on s.id=si.sale_id where s.status='paid' and s.created_at::date=current_date
  ),
  paid as (
    select coalesce(sum(amount) filter(where status='paid'),0)::numeric value,
           coalesce(sum(amount) filter(where status='pending'),0)::numeric pending,
           coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunded
    from public.payments where created_at::date=current_date
  ),
  sales as (
    select count(*)::bigint count,coalesce(sum(total_amount),0)::numeric total
    from paid_sales where created_at::date=current_date
  ),
  expiry as (
    select count(*)::bigint batches,coalesce(sum(b.quantity*m.selling_price),0)::numeric retail_value
    from public.batches b join public.medicines m on m.id=b.medicine_id
    where b.quantity>0 and b.expiry_date between current_date and current_date+30
  ),
  top_meds as (
    select coalesce(jsonb_agg(jsonb_build_object('name',x.name,'qty',x.qty,'revenue',x.revenue) order by x.revenue desc),'[]'::jsonb) data
    from (select m.name,sum(si.quantity)::bigint qty,coalesce(sum(si.total),0)::numeric revenue
          from public.sale_items si join public.sales s on s.id=si.sale_id join public.medicines m on m.id=si.medicine_id
          where s.status='paid' and s.created_at::date=current_date group by m.name order by revenue desc limit 5) x
  ),
  security as (
    select
      (select count(*) from public.profiles where role='seller' and not active)::bigint inactive_sellers,
      (select count(*) from public.audit_logs where created_at >= now()-interval '24 hours')::bigint audit_24h,
      (select count(*) from public.approvals where status='pending')::bigint pending_approvals,
      (select count(*) from public.stock_adjustment_requests where status='pending')::bigint pending_adjustments
  )
  select jsonb_build_object(
    'today',jsonb_build_object(
      'sales_count',(select count from sales),'sales_total',(select total from sales),
      'paid',(select value from paid),'pending_payments',(select pending from paid),'refunded',(select refunded from paid),
      'cogs',(select value from cogs),'gross_profit',(select total from sales)-(select value from cogs),
      'avg_sale',case when (select count from sales)>0 then (select total from sales)/(select count from sales) else 0 end
    ),
    'expiry',jsonb_build_object('batches',(select batches from expiry),'retail_value',(select retail_value from expiry)),
    'top_medicines',(select data from top_meds),
    'security',(select to_jsonb(security) from security)
  ) where public.current_role()='admin';
$$;

create or replace function public.seller_operations_snapshot()
returns jsonb
language sql stable security definer set search_path=public
as $$
  with me as (select auth.uid() uid),
  sales as (
    select count(*)::bigint count,coalesce(sum(total_amount),0)::numeric total
    from public.sales where seller_id=(select uid from me) and status='paid' and created_at::date=current_date
  ),
  payments as (
    select coalesce(sum(p.amount) filter(where p.status='paid' and p.method='cash'),0)::numeric cash,
           coalesce(sum(p.amount) filter(where p.status='paid' and p.method='mpesa'),0)::numeric mpesa,
           coalesce(sum(p.amount) filter(where p.status='paid' and p.method='other'),0)::numeric other
    from public.payments p join public.sales s on s.id=p.sale_id
    where s.seller_id=(select uid from me) and p.created_at::date=current_date
  ),
  shift as (
    select opening_cash,closing_cash,status,opened_at,closed_at from public.shift_sessions
    where seller_id=(select uid from me) order by opened_at desc limit 1
  )
  select jsonb_build_object(
    'sales_count',(select count from sales),'sales_total',(select total from sales),
    'cash',(select cash from payments),'mpesa',(select mpesa from payments),'other',(select other from payments),
    'shift',(select coalesce(row_to_json(shift),'{}'::json) from shift),
    'pending_own_approvals',(select count(*) from public.approvals where requested_by=(select uid from me) and status='pending'),
    'pending_own_adjustments',(select count(*) from public.stock_adjustment_requests where requested_by=(select uid from me) and status='pending')
  ) where public.current_role()='seller';
$$;

revoke all on function public.admin_operations_snapshot() from public;
revoke all on function public.seller_operations_snapshot() from public;
grant execute on function public.admin_operations_snapshot() to authenticated;
grant execute on function public.seller_operations_snapshot() to authenticated;

-- Prevent anonymous or client-side exposure of operational analytics.

-- ============================================================================
-- 012_production_security_operations.sql
-- ============================================================================
-- Production security, pharmacy settings, session tracking and end-of-day reconciliation.
create extension if not exists pgcrypto;

create table if not exists public.pharmacy_settings(
  id boolean primary key default true check(id=true),
  pharmacy_name text not null default 'PharmaCare Pharmacy',
  tagline text default 'Safe medicines. Trusted care.',
  phone text,
  email text,
  address text,
  till_number text,
  paybill_number text,
  currency text not null default 'KES',
  receipt_footer text default 'Thank you for choosing our pharmacy.',
  low_stock_threshold integer not null default 10 check(low_stock_threshold>=0),
  expiry_alert_days integer not null default 30 check(expiry_alert_days between 1 and 365),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
insert into public.pharmacy_settings(id) values(true) on conflict do nothing;

create table if not exists public.device_sessions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  session_key text unique not null,
  device_label text,
  user_agent text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index if not exists idx_device_sessions_user on public.device_sessions(user_id,last_seen_at desc);

create table if not exists public.security_alerts(
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete set null,
  alert_type text not null,
  severity text not null default 'medium' check(severity in ('low','medium','high','critical')),
  title text not null,
  details jsonb not null default '{}'::jsonb,
  resolved boolean not null default false,
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_security_alerts_open on public.security_alerts(resolved,created_at desc);

create table if not exists public.daily_reconciliations(
  id uuid primary key default gen_random_uuid(),
  business_date date unique not null,
  opening_cash numeric(12,2) not null default 0,
  cash_sales numeric(12,2) not null default 0,
  mpesa_sales numeric(12,2) not null default 0,
  other_sales numeric(12,2) not null default 0,
  refunds numeric(12,2) not null default 0,
  expenses numeric(12,2) not null default 0,
  expected_cash numeric(12,2) not null default 0,
  counted_cash numeric(12,2),
  variance numeric(12,2),
  notes text,
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.pharmacy_settings enable row level security;
alter table public.device_sessions enable row level security;
alter table public.security_alerts enable row level security;
alter table public.daily_reconciliations enable row level security;

drop policy if exists "staff read pharmacy settings" on public.pharmacy_settings;
create policy "staff read pharmacy settings" on public.pharmacy_settings for select using (public.current_role() in ('admin','seller'));
drop policy if exists "admin update pharmacy settings" on public.pharmacy_settings;
create policy "admin update pharmacy settings" on public.pharmacy_settings for update using (public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "own device sessions" on public.device_sessions;
create policy "own device sessions" on public.device_sessions for select using (user_id=auth.uid() or public.current_role()='admin');
drop policy if exists "admin manage device sessions" on public.device_sessions;
create policy "admin manage device sessions" on public.device_sessions for all using(public.current_role()='admin') with check(public.current_role()='admin');

create policy "admin security alerts" on public.security_alerts for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "own security alerts read" on public.security_alerts for select using(user_id=auth.uid());
create policy "admin reconciliation" on public.daily_reconciliations for all using(public.current_role()='admin') with check(public.current_role()='admin');

create or replace function public.register_device_session(p_session_key text,p_device_label text default null,p_user_agent text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_revoked timestamptz;
begin
  if auth.uid() is null or public.current_role() is null then raise exception 'Authentication required'; end if;
  select revoked_at into v_revoked from public.device_sessions where session_key=left(p_session_key,180);
  if v_revoked is not null then raise exception 'This device session was revoked. Please sign in again from an approved device.'; end if;
  if not exists(select 1 from public.device_sessions where session_key=left(p_session_key,180)) and exists(select 1 from public.device_sessions where user_id=auth.uid() and revoked_at is null and last_seen_at>=now()-interval '30 days') then
    insert into public.security_alerts(user_id,alert_type,severity,title,details) values(auth.uid(),'new_device','medium','New device/session detected',jsonb_build_object('device_label',p_device_label,'user_agent',left(p_user_agent,300)));
  end if;
  insert into public.device_sessions(user_id,session_key,device_label,user_agent)
  values(auth.uid(),left(p_session_key,180),left(p_device_label,120),left(p_user_agent,500))
  on conflict(session_key) do update set last_seen_at=now(),device_label=excluded.device_label,user_agent=excluded.user_agent
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.touch_device_session(p_session_key text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update public.device_sessions set last_seen_at=now() where session_key=left(p_session_key,180) and user_id=auth.uid() and revoked_at is null;
  return found;
end $$;

create or replace function public.revoke_device_session(p_session_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  update public.device_sessions set revoked_at=now() where id=p_session_id and revoked_at is null;
  if found then insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'revoke_device_session','device_session',p_session_id::text); end if;
  return found;
end $$;

create or replace function public.admin_end_of_day_snapshot(p_business_date date default current_date)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb; v_opening numeric:=0;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  select coalesce(sum(opening_cash),0) into v_opening from public.shift_sessions where opened_at::date=p_business_date;
  with paid as (
    select coalesce(sum(p.amount) filter(where p.method='cash' and p.status='paid'),0) cash,
           coalesce(sum(p.amount) filter(where p.method='mpesa' and p.status='paid'),0) mpesa,
           coalesce(sum(p.amount) filter(where p.method='other' and p.status='paid'),0) other,
           coalesce(sum(p.amount) filter(where p.method='cash' and p.status='refunded'),0) refunds_cash,
           coalesce(sum(p.amount) filter(where p.status='refunded'),0) refunds_total
    from public.payments p where p.created_at::date=p_business_date
  ), exp as (select coalesce(sum(amount) filter(where payment_method='cash'),0) cash,coalesce(sum(amount),0) total from public.expenses where expense_date=p_business_date), sales as (select count(*) count,coalesce(sum(total_amount) filter(where status='paid'),0) total from public.sales where created_at::date=p_business_date)
  select jsonb_build_object('business_date',p_business_date,'opening_cash',v_opening,'cash_sales',paid.cash,'mpesa_sales',paid.mpesa,'other_sales',paid.other,'refunds',paid.refunds_total,'cash_refunds',paid.refunds_cash,'expenses',exp.total,'cash_expenses',exp.cash,'sales_count',sales.count,'sales_total',sales.total,'expected_cash',v_opening+paid.cash-paid.refunds_cash-exp.cash,'net_cash_flow',paid.cash+paid.mpesa+paid.other-paid.refunds_total-exp.total) into v from paid,exp,sales;
  return v;
end $$;

create or replace function public.close_daily_reconciliation(p_business_date date,p_counted_cash numeric,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  v:=public.admin_end_of_day_snapshot(p_business_date);
  insert into public.daily_reconciliations(business_date,opening_cash,cash_sales,mpesa_sales,other_sales,refunds,expenses,expected_cash,counted_cash,variance,notes,closed_by,closed_at)
  values(p_business_date,(v->>'opening_cash')::numeric,(v->>'cash_sales')::numeric,(v->>'mpesa_sales')::numeric,(v->>'other_sales')::numeric,(v->>'refunds')::numeric,(v->>'expenses')::numeric,(v->>'expected_cash')::numeric,p_counted_cash,p_counted_cash-(v->>'expected_cash')::numeric,p_notes,auth.uid(),now())
  on conflict(business_date) do update set counted_cash=excluded.counted_cash,variance=excluded.variance,notes=excluded.notes,closed_by=excluded.closed_by,closed_at=excluded.closed_at;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'close_daily_reconciliation','daily_reconciliation',p_business_date::text,v);
  return v || jsonb_build_object('counted_cash',p_counted_cash,'variance',p_counted_cash-(v->>'expected_cash')::numeric);
end $$;

create or replace function public.admin_security_snapshot()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  select jsonb_build_object(
    'open_alerts',(select count(*) from public.security_alerts where resolved=false),
    'active_sessions',(select count(*) from public.device_sessions where revoked_at is null),
    'sessions_last_24h',(select count(*) from public.device_sessions where created_at>=now()-interval '24 hours'),
    'inactive_sellers',(select count(*) from public.profiles where role='seller' and active=false),
    'recent_audit',(select count(*) from public.audit_logs where created_at>=now()-interval '24 hours')
  ) into v; return v;
end $$;

revoke all on function public.register_device_session(text,text,text) from public;
revoke all on function public.touch_device_session(text) from public;
revoke all on function public.revoke_device_session(uuid) from public;
revoke all on function public.admin_end_of_day_snapshot(date) from public;
revoke all on function public.close_daily_reconciliation(date,numeric,text) from public;
revoke all on function public.admin_security_snapshot() from public;
grant execute on function public.register_device_session(text,text,text) to authenticated;
grant execute on function public.touch_device_session(text) to authenticated;
grant execute on function public.revoke_device_session(uuid) to authenticated;
grant execute on function public.admin_end_of_day_snapshot(date) to authenticated;
grant execute on function public.close_daily_reconciliation(date,numeric,text) to authenticated;
grant execute on function public.admin_security_snapshot() to authenticated;

-- ============================================================================
-- 013_advanced_controls_notifications.sql
-- ============================================================================
-- Advanced controls: fine-grained seller permissions, operational notifications,
-- fraud signals and secure stock-count workflow.

create table if not exists public.seller_permissions(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  can_sell boolean not null default true,
  can_process_prescriptions boolean not null default true,
  can_request_refund boolean not null default true,
  can_request_cancellation boolean not null default true,
  can_request_stock_adjustment boolean not null default true,
  can_view_own_reports boolean not null default true,
  max_discount_percent numeric(5,2) not null default 0 check(max_discount_percent between 0 and 100),
  max_transaction_amount numeric(12,2),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.operational_notifications(
  id uuid primary key default gen_random_uuid(),
  notification_type text not null,
  severity text not null default 'info' check(severity in ('info','warning','critical')),
  title text not null,
  message text not null,
  entity_type text,
  entity_id text,
  target_user_id uuid references public.profiles(id) on delete cascade,
  metadata jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_operational_notifications_target on public.operational_notifications(target_user_id,read_at,created_at desc);
create index if not exists idx_operational_notifications_open on public.operational_notifications(resolved_at,created_at desc);

create table if not exists public.stock_counts(
  id uuid primary key default gen_random_uuid(),
  count_number text unique not null,
  status text not null default 'draft' check(status in ('draft','submitted','approved','rejected')),
  notes text,
  counted_by uuid not null references public.profiles(id),
  reviewed_by uuid references public.profiles(id),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.stock_count_items(
  id uuid primary key default gen_random_uuid(),
  stock_count_id uuid not null references public.stock_counts(id) on delete cascade,
  medicine_id uuid not null references public.medicines(id),
  batch_id uuid references public.batches(id),
  system_quantity integer not null,
  counted_quantity integer not null check(counted_quantity>=0),
  variance integer generated always as (counted_quantity-system_quantity) stored,
  unique(stock_count_id,medicine_id,batch_id)
);
create index if not exists idx_stock_counts_status on public.stock_counts(status,created_at desc);

alter table public.seller_permissions enable row level security;
alter table public.operational_notifications enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_count_items enable row level security;

create policy "seller own permissions" on public.seller_permissions for select using(user_id=auth.uid() or public.current_role()='admin');
create policy "admin manage permissions" on public.seller_permissions for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "admin notifications" on public.operational_notifications for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "own notifications" on public.operational_notifications for select using(target_user_id=auth.uid());
create policy "admin stock counts" on public.stock_counts for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "staff own stock counts" on public.stock_counts for select using(counted_by=auth.uid() or public.current_role()='admin');
create policy "admin stock count items" on public.stock_count_items for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "staff own stock count items" on public.stock_count_items for select using(exists(select 1 from public.stock_counts c where c.id=stock_count_id and c.counted_by=auth.uid()));

create or replace function public.ensure_seller_permissions()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.role='seller' then
    insert into public.seller_permissions(user_id) values(new.id) on conflict(user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists trg_ensure_seller_permissions on public.profiles;
create trigger trg_ensure_seller_permissions after insert or update of role on public.profiles for each row execute function public.ensure_seller_permissions();
insert into public.seller_permissions(user_id)
select id from public.profiles where role='seller' on conflict(user_id) do nothing;

create or replace function public.get_my_seller_permissions()
returns jsonb language sql stable security definer set search_path=public as $$
select coalesce(to_jsonb(p),'{}'::jsonb) from public.seller_permissions p where p.user_id=auth.uid() and public.current_role()='seller';
$$;

create or replace function public.admin_set_seller_permissions(
  p_user_id uuid,
  p_can_sell boolean,
  p_can_process_prescriptions boolean,
  p_can_request_refund boolean,
  p_can_request_cancellation boolean,
  p_can_request_stock_adjustment boolean,
  p_can_view_own_reports boolean,
  p_max_discount_percent numeric,
  p_max_transaction_amount numeric default null
)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.profiles where id=p_user_id and role='seller') then raise exception 'Seller account not found'; end if;
  if p_max_discount_percent<0 or p_max_discount_percent>100 then raise exception 'Invalid discount limit'; end if;
  if p_max_transaction_amount is not null and p_max_transaction_amount<=0 then raise exception 'Invalid transaction limit'; end if;
  insert into public.seller_permissions(user_id,can_sell,can_process_prescriptions,can_request_refund,can_request_cancellation,can_request_stock_adjustment,can_view_own_reports,max_discount_percent,max_transaction_amount,updated_by,updated_at)
  values(p_user_id,p_can_sell,p_can_process_prescriptions,p_can_request_refund,p_can_request_cancellation,p_can_request_stock_adjustment,p_can_view_own_reports,p_max_discount_percent,p_max_transaction_amount,auth.uid(),now())
  on conflict(user_id) do update set can_sell=excluded.can_sell,can_process_prescriptions=excluded.can_process_prescriptions,can_request_refund=excluded.can_request_refund,can_request_cancellation=excluded.can_request_cancellation,can_request_stock_adjustment=excluded.can_request_stock_adjustment,can_view_own_reports=excluded.can_view_own_reports,max_discount_percent=excluded.max_discount_percent,max_transaction_amount=excluded.max_transaction_amount,updated_by=auth.uid(),updated_at=now();
  perform public.audit('SELLER_PERMISSIONS_UPDATED','profile',p_user_id::text,jsonb_build_object('max_discount_percent',p_max_discount_percent,'max_transaction_amount',p_max_transaction_amount));
  return true;
end $$;

create or replace function public.admin_create_notification(
  p_type text,p_severity text,p_title text,p_message text,p_entity_type text default null,p_entity_id text default null,p_target_user_id uuid default null,p_metadata jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  insert into public.operational_notifications(notification_type,severity,title,message,entity_type,entity_id,target_user_id,metadata)
  values(left(p_type,80),p_severity,left(p_title,180),left(p_message,1000),p_entity_type,p_entity_id,p_target_user_id,coalesce(p_metadata,'{}'::jsonb)) returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_notification_snapshot()
returns jsonb language sql stable security definer set search_path=public as $$
with low as (select count(*)::bigint n from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity<=m.reorder_level and m.active),
expiry as (select count(*)::bigint n from public.batches where quantity>0 and expiry_date between current_date and current_date+30),
expired as (select count(*)::bigint n from public.batches where quantity>0 and expiry_date<current_date),
refunds as (select count(*)::bigint n from public.approvals where status='pending' and action_type in ('refund','cancel_sale')),
adj as (select count(*)::bigint n from public.stock_adjustment_requests where status='pending'),
alerts as (select count(*)::bigint n from public.security_alerts where resolved=false)
select jsonb_build_object('low_stock',(select n from low),'expiring_batches',(select n from expiry),'expired_batches',(select n from expired),'pending_refunds',(select n from refunds),'pending_adjustments',(select n from adj),'open_security_alerts',(select n from alerts),'unread_notifications',(select count(*) from public.operational_notifications where target_user_id is null and read_at is null and resolved_at is null)) where public.current_role()='admin';
$$;

create or replace function public.admin_create_stock_count(p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  insert into public.stock_counts(count_number,notes,counted_by) values('SC-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-MS'),p_notes,auth.uid()) returning id into v_id;
  insert into public.stock_count_items(stock_count_id,medicine_id,batch_id,system_quantity,counted_quantity)
  select v_id,m.id,b.id,b.quantity,b.quantity from public.batches b join public.medicines m on m.id=b.medicine_id where b.quantity>0;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'CREATE_STOCK_COUNT','stock_count',v_id::text);
  return v_id;
end $$;

create or replace function public.admin_submit_stock_count(p_stock_count_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  update public.stock_counts set status='submitted',submitted_at=now() where id=p_stock_count_id and status='draft';
  if not found then raise exception 'Stock count is not editable'; end if;
  select jsonb_build_object('count_number',c.count_number,'items',count(i.*),'variance_units',coalesce(sum(i.variance),0)) into v from public.stock_counts c left join public.stock_count_items i on i.stock_count_id=c.id where c.id=p_stock_count_id group by c.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'SUBMIT_STOCK_COUNT','stock_count',p_stock_count_id::text,v);
  return v;
end $$;

-- Generate operational signals without allowing sellers to create their own alerts.
create or replace function public.generate_operational_notifications()
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer:=0; v_low integer; v_expiring integer; v_expired integer; v_pending integer;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  select count(*) into v_low from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity<=m.reorder_level and m.active;
  select count(*) into v_expiring from public.batches where quantity>0 and expiry_date between current_date and current_date+30;
  select count(*) into v_expired from public.batches where quantity>0 and expiry_date<current_date;
  select count(*) into v_pending from public.approvals where status='pending';
  if v_low>0 and not exists(select 1 from public.operational_notifications where notification_type='low_stock' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('low_stock','warning','Low stock requires attention',v_low||' medicine records are at or below their reorder level.',jsonb_build_object('count',v_low)); v_count:=v_count+1;
  end if;
  if v_expiring>0 and not exists(select 1 from public.operational_notifications where notification_type='expiry' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('expiry','warning','Stock nearing expiry',v_expiring||' batches expire within 30 days.',jsonb_build_object('count',v_expiring)); v_count:=v_count+1;
  end if;
  if v_expired>0 and not exists(select 1 from public.operational_notifications where notification_type='expired_stock' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('expired_stock','critical','Expired stock detected',v_expired||' batches still have quantity after expiry and must not be dispensed.',jsonb_build_object('count',v_expired)); v_count:=v_count+1;
  end if;
  if v_pending>0 and not exists(select 1 from public.operational_notifications where notification_type='approvals' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('approvals','info','Approvals are waiting',v_pending||' seller action requests are waiting for admin review.',jsonb_build_object('count',v_pending)); v_count:=v_count+1;
  end if;
  return v_count;
end $$;

revoke all on function public.get_my_seller_permissions() from public;
revoke all on function public.admin_set_seller_permissions(uuid,boolean,boolean,boolean,boolean,boolean,boolean,numeric,numeric) from public;
revoke all on function public.admin_create_notification(text,text,text,text,text,text,uuid,jsonb) from public;
revoke all on function public.admin_notification_snapshot() from public;
revoke all on function public.admin_create_stock_count(text) from public;
revoke all on function public.admin_submit_stock_count(uuid) from public;
revoke all on function public.generate_operational_notifications() from public;
grant execute on function public.get_my_seller_permissions() to authenticated;
grant execute on function public.admin_set_seller_permissions(uuid,boolean,boolean,boolean,boolean,boolean,boolean,numeric,numeric) to authenticated;
grant execute on function public.admin_create_notification(text,text,text,text,text,text,uuid,jsonb) to authenticated;
grant execute on function public.admin_notification_snapshot() to authenticated;
grant execute on function public.admin_create_stock_count(text) to authenticated;
grant execute on function public.admin_submit_stock_count(uuid) to authenticated;
grant execute on function public.generate_operational_notifications() to authenticated;

-- ============================================================================
-- 014_enforce_seller_permissions.sql
-- ============================================================================
-- Enforce seller permission controls inside privileged transaction functions.

create or replace function public.create_sale(p_items jsonb,p_prescription_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid:=gen_random_uuid(); v_number text; v_total numeric(12,2):=0; item jsonb; v_price numeric; v_qty int; v_med uuid; v_stock int; v_required boolean; v_rem int; v_pi uuid; v_batch_id uuid; v_can_sell boolean:=true; v_max numeric;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' then
    select can_sell,max_transaction_amount into v_can_sell,v_max from public.seller_permissions where user_id=auth.uid();
    if coalesce(v_can_sell,false)=false then raise exception 'Your seller account is not permitted to process sales'; end if;
  end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Sale requires items'; end if;
  if p_prescription_id is not null and not exists(select 1 from public.prescriptions where id=p_prescription_id and status in ('verified','dispensing','dispensed')) then raise exception 'Prescription is not verified'; end if;
  v_number:='SALE-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_sale_id::text,'-',''),1,6);
  insert into public.sales(id,sale_number,seller_id,prescription_id,total_amount,status) values(v_sale_id,v_number,auth.uid(),p_prescription_id,0,'pending_payment');
  for item in select * from jsonb_array_elements(p_items) loop
    v_med:=(item->>'medicine_id')::uuid; v_qty:=(item->>'quantity')::int; v_batch_id:=nullif(item->>'batch_id','')::uuid;
    if v_qty<=0 then raise exception 'Invalid quantity'; end if;
    select selling_price,prescription_required into v_price,v_required from public.medicines where id=v_med and active=true;
    if v_price is null then raise exception 'Medicine unavailable'; end if;
    if v_required and p_prescription_id is null then raise exception 'Prescription required for this medicine'; end if;
    if p_prescription_id is not null then
      select id,quantity_prescribed-quantity_dispensed into v_pi,v_rem from public.prescription_items where prescription_id=p_prescription_id and medicine_id=v_med for update;
      if v_pi is null or v_rem<v_qty then raise exception 'Sale quantity exceeds prescription balance'; end if;
    end if;
    select quantity into v_stock from public.inventory where medicine_id=v_med for update;
    if coalesce(v_stock,0)<v_qty then raise exception 'Insufficient stock for medicine %',v_med; end if;
    if v_batch_id is not null and not exists(select 1 from public.batches where id=v_batch_id and medicine_id=v_med and expiry_date>=current_date and quantity>=v_qty) then raise exception 'Selected batch is invalid, expired or has insufficient stock'; end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price,prescription_item_id,batch_id) values(v_sale_id,v_med,v_qty,v_price,v_pi,v_batch_id);
    v_total:=v_total+v_qty*v_price;
  end loop;
  if public.current_role()='seller' and v_max is not null and v_total>v_max then raise exception 'Transaction exceeds your authorized seller limit'; end if;
  update public.sales set total_amount=v_total where id=v_sale_id;
  perform public.audit('SALE_CREATED','sale',v_sale_id::text,jsonb_build_object('total',v_total,'prescription_id',p_prescription_id));
  return v_sale_id;
exception when others then
  delete from public.sale_items where sale_id=v_sale_id;
  delete from public.sales where id=v_sale_id;
  raise;
end $$;

create or replace function public.request_action(p_action_type text,p_target_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_allowed boolean:=true;
begin
  if public.current_role()<>'seller' then raise exception 'Only seller requests use this workflow'; end if;
  select case
    when p_action_type='refund' then can_request_refund
    when p_action_type='cancel_sale' then can_request_cancellation
    when p_action_type='stock_adjustment' then can_request_stock_adjustment
    else true end into v_allowed from public.seller_permissions where user_id=auth.uid();
  if not coalesce(v_allowed,false) then raise exception 'Your seller account is not permitted to request this action'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'A reason is required'; end if;
  insert into public.approvals(action_type,target_id,requested_by,reason) values(p_action_type,p_target_id,trim(p_reason)) returning id into v_id;
  perform public.audit('APPROVAL_REQUESTED',p_action_type,v_id::text,jsonb_build_object('target_id',p_target_id,'reason',trim(p_reason)));
  return v_id;
end $$;

revoke all on function public.create_sale(jsonb,uuid) from public;
revoke all on function public.request_action(text,uuid,text) from public;
grant execute on function public.create_sale(jsonb,uuid) to authenticated;
grant execute on function public.request_action(text,uuid,text) to authenticated;

create or replace function public.create_prescription(p_patient_name text,p_prescriber_name text,p_prescription_date date,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_number text; i jsonb; v_med uuid; v_qty int; v_allowed boolean:=true;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' then select can_process_prescriptions into v_allowed from public.seller_permissions where user_id=auth.uid(); if not coalesce(v_allowed,false) then raise exception 'Your seller account is not permitted to process prescriptions'; end if; end if;
  if nullif(trim(p_patient_name),'') is null then raise exception 'Patient name is required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Prescription requires at least one medicine'; end if;
  v_number:='RX-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_id::text,'-',''),1,6);
  insert into public.prescriptions(id,prescription_number,patient_name,prescriber_name,prescription_date,status,created_by)
  values(v_id,v_number,trim(p_patient_name),nullif(trim(p_prescriber_name),''),coalesce(p_prescription_date,current_date),'received',auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity_prescribed')::int;
    if v_qty is null or v_qty<=0 then raise exception 'Invalid prescribed quantity'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.prescription_items(prescription_id,medicine_id,dosage_instructions,quantity_prescribed)
    values(v_id,v_med,nullif(i->>'dosage_instructions',''),v_qty);
  end loop;
  perform public.audit('PRESCRIPTION_CREATED','prescription',v_id::text,jsonb_build_object('prescription_number',v_number));
  return v_id;
exception when others then
  delete from public.prescription_items where prescription_id=v_id;
  delete from public.prescriptions where id=v_id;
  raise;
end $$;
revoke all on function public.create_prescription(text,text,date,jsonb) from public;
grant execute on function public.create_prescription(text,text,date,jsonb) to authenticated;

-- ============================================================================
-- 015_security_hardening_final.sql
-- ============================================================================
-- Final security hardening layer.
-- Sensitive financial/audit state transitions must happen through trusted RPCs.

-- Prevent browser clients from directly rewriting or deleting financial/audit records.
revoke update, delete on table public.audit_logs from anon, authenticated;
revoke update, delete on table public.payments from anon, authenticated;
revoke update, delete on table public.sales from anon, authenticated;
revoke update, delete on table public.sale_items from anon, authenticated;

-- Audit records are append-only.
create or replace function public.block_audit_mutation()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  raise exception 'Audit records are immutable';
end $$;
drop trigger if exists trg_audit_immutable on public.audit_logs;
create trigger trg_audit_immutable before update or delete on public.audit_logs
for each row execute function public.block_audit_mutation();

-- Resolve security alerts through a server-side audited action.
create or replace function public.resolve_security_alert(p_alert_id uuid,p_note text default null)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if public.current_role() <> 'admin' then raise exception 'Administrator access required'; end if;
  update public.security_alerts
     set resolved=true,resolved_by=auth.uid(),resolved_at=now(),details=details || jsonb_build_object('resolution_note',nullif(left(trim(coalesce(p_note,'')),500),''))
   where id=p_alert_id and resolved=false;
  if not found then return false; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SECURITY_ALERT_RESOLVED','security_alert',p_alert_id::text,jsonb_build_object('note',nullif(left(trim(coalesce(p_note,'')),500),'')));
  return true;
end $$;
revoke all on function public.resolve_security_alert(uuid,text) from public;
grant execute on function public.resolve_security_alert(uuid,text) to authenticated;

-- Run a deterministic security scan from trusted database state.
-- Alerts are de-duplicated for 24 hours to avoid notification flooding.
create or replace function public.admin_run_security_scan()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_created integer := 0;
  r record;
begin
  if public.current_role() <> 'admin' then raise exception 'Administrator access required'; end if;

  -- Multiple active sessions for one user.
  for r in
    select user_id,count(*) active_sessions
    from public.device_sessions
    where revoked_at is null and last_seen_at >= now()-interval '30 days'
    group by user_id having count(*) >= 3
  loop
    if not exists(select 1 from public.security_alerts where user_id=r.user_id and alert_type='multiple_active_sessions' and resolved=false and created_at>=now()-interval '24 hours') then
      insert into public.security_alerts(user_id,alert_type,severity,title,details)
      values(r.user_id,'multiple_active_sessions','high','Multiple active device sessions',jsonb_build_object('active_sessions',r.active_sessions));
      v_created := v_created + 1;
    end if;
  end loop;

  -- Repeated cancellation/refund requests in a short period.
  for r in
    select requested_by,count(*) request_count
    from public.approvals
    where created_at>=now()-interval '24 hours' and action_type in ('refund','cancel_sale')
    group by requested_by having count(*) >= 5
  loop
    if not exists(select 1 from public.security_alerts where user_id=r.requested_by and alert_type='high_refund_activity' and resolved=false and created_at>=now()-interval '24 hours') then
      insert into public.security_alerts(user_id,alert_type,severity,title,details)
      values(r.requested_by,'high_refund_activity','high','Unusually high refund/cancellation activity',jsonb_build_object('requests_last_24h',r.request_count));
      v_created := v_created + 1;
    end if;
  end loop;

  -- Large cash variances from closed daily reconciliations.
  for r in
    select closed_by,variance,business_date
    from public.daily_reconciliations
    where closed_at>=now()-interval '7 days' and abs(variance)>=1000
  loop
    if not exists(select 1 from public.security_alerts where user_id=r.closed_by and alert_type='cash_variance' and resolved=false and created_at>=now()-interval '24 hours' and details->>'business_date'=r.business_date::text) then
      insert into public.security_alerts(user_id,alert_type,severity,title,details)
      values(r.closed_by,'cash_variance',case when abs(r.variance)>=5000 then 'critical' else 'high' end,'Cash reconciliation variance detected',jsonb_build_object('business_date',r.business_date,'variance',r.variance));
      v_created := v_created + 1;
    end if;
  end loop;

  -- Expired stock still carrying quantity is operationally critical.
  if exists(select 1 from public.batches where quantity>0 and expiry_date<current_date) then
    if not exists(select 1 from public.security_alerts where alert_type='expired_stock' and resolved=false and created_at>=now()-interval '24 hours') then
      insert into public.security_alerts(alert_type,severity,title,details)
      values('expired_stock','critical','Expired stock remains in inventory',jsonb_build_object('batch_count',(select count(*) from public.batches where quantity>0 and expiry_date<current_date)));
      v_created := v_created + 1;
    end if;
  end if;

  return jsonb_build_object('created',v_created,'open_alerts',(select count(*) from public.security_alerts where resolved=false));
end $$;
revoke all on function public.admin_run_security_scan() from public;
grant execute on function public.admin_run_security_scan() to authenticated;

-- Log permission changes at the database boundary as well.
create or replace function public.audit_permission_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='UPDATE' and (old.* is distinct from new.*) then
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'SELLER_PERMISSION_CHANGED','seller_permissions',new.user_id::text,
           jsonb_build_object('can_sell',new.can_sell,'can_process_prescriptions',new.can_process_prescriptions,
           'can_request_refund',new.can_request_refund,'can_request_cancellation',new.can_request_cancellation,
           'can_request_stock_adjustment',new.can_request_stock_adjustment,'max_discount_percent',new.max_discount_percent,
           'max_transaction_amount',new.max_transaction_amount));
  end if;
  return new;
end $$;
drop trigger if exists trg_audit_permission_change on public.seller_permissions;
create trigger trg_audit_permission_change after update on public.seller_permissions
for each row execute function public.audit_permission_change();

-- ============================================================================
-- 016_advanced_pharmacy_operations.sql
-- ============================================================================
-- Advanced pharmacy operations: purchasing, supplier ledger, locations, holds,
-- reorder intelligence, quarantine/recall, branch foundation and split payments.

create table if not exists public.pharmacy_branches(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 code text not null unique,
 phone text,
 address text,
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.branch_memberships(
 branch_id uuid not null references public.pharmacy_branches(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 is_manager boolean not null default false,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 primary key(branch_id,user_id)
);

create table if not exists public.purchase_orders(
 id uuid primary key default gen_random_uuid(),
 po_number text not null unique,
 supplier_id uuid references public.suppliers(id),
 supplier_name text,
 status text not null default 'draft' check(status in ('draft','submitted','approved','ordered','partially_received','received','cancelled')),
 expected_date date,
 notes text,
 total_cost numeric(12,2) not null default 0,
 created_by uuid not null references public.profiles(id),
 approved_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.purchase_order_items(
 id uuid primary key default gen_random_uuid(),
 purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
 medicine_id uuid not null references public.medicines(id),
 quantity_ordered integer not null check(quantity_ordered>0),
 quantity_received integer not null default 0 check(quantity_received>=0),
 unit_cost numeric(12,2) not null check(unit_cost>=0),
 total_cost numeric(12,2) generated always as (quantity_ordered*unit_cost) stored
);

create table if not exists public.supplier_ledger(
 id uuid primary key default gen_random_uuid(),
 supplier_id uuid references public.suppliers(id),
 supplier_name text not null,
 entry_type text not null check(entry_type in ('invoice','payment','credit','debit')),
 reference text,
 amount numeric(12,2) not null check(amount>0),
 entry_date date not null default current_date,
 notes text,
 recorded_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);

create table if not exists public.stock_locations(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 location_type text not null default 'shelf' check(location_type in ('shelf','refrigerator','controlled','quarantine','store','other')),
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.medicine_locations(
 medicine_id uuid not null references public.medicines(id) on delete cascade,
 location_id uuid not null references public.stock_locations(id) on delete restrict,
 preferred boolean not null default true,
 created_at timestamptz not null default now(),
 primary key(medicine_id,location_id)
);

create table if not exists public.held_sales(
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null references public.profiles(id) on delete cascade,
 hold_reference text not null,
 cart jsonb not null default '[]'::jsonb,
 prescription_id uuid references public.prescriptions(id),
 notes text,
 created_at timestamptz not null default now(),
 unique(seller_id,hold_reference)
);

create table if not exists public.reorder_recommendations(
 id uuid primary key default gen_random_uuid(),
 medicine_id uuid not null references public.medicines(id) on delete cascade,
 recommended_quantity integer not null check(recommended_quantity>0),
 average_daily_sales numeric(12,2) not null default 0,
 days_of_cover numeric(12,2),
 reason text not null,
 status text not null default 'open' check(status in ('open','converted','dismissed')),
 generated_at timestamptz not null default now()
);

create table if not exists public.stock_quarantine(
 id uuid primary key default gen_random_uuid(),
 batch_id uuid not null references public.batches(id),
 medicine_id uuid not null references public.medicines(id),
 quantity integer not null check(quantity>0),
 reason text not null,
 status text not null default 'quarantined' check(status in ('quarantined','released','disposed','returned')),
 created_by uuid not null references public.profiles(id),
 resolved_by uuid references public.profiles(id),
 resolved_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.recall_notices(
 id uuid primary key default gen_random_uuid(),
 medicine_id uuid not null references public.medicines(id),
 batch_id uuid references public.batches(id),
 reason text not null,
 status text not null default 'open' check(status in ('open','resolved')),
 created_by uuid not null references public.profiles(id),
 resolved_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);

alter table public.pharmacy_branches enable row level security;
alter table public.branch_memberships enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.supplier_ledger enable row level security;
alter table public.stock_locations enable row level security;
alter table public.medicine_locations enable row level security;
alter table public.held_sales enable row level security;
alter table public.reorder_recommendations enable row level security;
alter table public.stock_quarantine enable row level security;
alter table public.recall_notices enable row level security;

drop policy if exists "staff read branches" on public.pharmacy_branches;
create policy "staff read branches" on public.pharmacy_branches for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage branches" on public.pharmacy_branches;
create policy "admin manage branches" on public.pharmacy_branches for all using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "staff read locations" on public.stock_locations;
create policy "staff read locations" on public.stock_locations for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage locations" on public.stock_locations;
create policy "admin manage locations" on public.stock_locations for all using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "staff read medicine locations" on public.medicine_locations;
create policy "staff read medicine locations" on public.medicine_locations for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage medicine locations" on public.medicine_locations;
create policy "admin manage medicine locations" on public.medicine_locations for all using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "admin purchase orders" on public.purchase_orders;
create policy "admin purchase orders" on public.purchase_orders for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin purchase order items" on public.purchase_order_items;
create policy "admin purchase order items" on public.purchase_order_items for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin supplier ledger" on public.supplier_ledger;
create policy "admin supplier ledger" on public.supplier_ledger for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "seller held sales" on public.held_sales;
create policy "seller held sales" on public.held_sales for all using(seller_id=auth.uid()) with check(seller_id=auth.uid());
drop policy if exists "admin held sales" on public.held_sales;
create policy "admin held sales" on public.held_sales for select using(public.current_role()='admin');
drop policy if exists "admin reorder recommendations" on public.reorder_recommendations;
create policy "admin reorder recommendations" on public.reorder_recommendations for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin quarantine" on public.stock_quarantine;
create policy "admin quarantine" on public.stock_quarantine for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin recalls" on public.recall_notices;
create policy "admin recalls" on public.recall_notices for all using(public.current_role()='admin') with check(public.current_role()='admin');

do $$ begin
  if not exists(select 1 from public.stock_locations) then
    insert into public.stock_locations(name,location_type) values
      ('Main Shelf','shelf'),('Refrigerator','refrigerator'),('Controlled Storage','controlled'),('Quarantine','quarantine');
  end if;
end $$;

create or replace function public.admin_create_purchase_order(p_supplier_id uuid,p_supplier_name text,p_expected_date date,p_notes text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_no text; i jsonb; v_total numeric:=0; v_med uuid; v_qty int; v_cost numeric;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Purchase order requires items'; end if;
  v_no:='PO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_id::text,'-',''),1,6);
  insert into public.purchase_orders(id,po_number,supplier_id,supplier_name,expected_date,notes,created_by)
  values(v_id,v_no,p_supplier_id,nullif(trim(p_supplier_name),''),p_expected_date,nullif(trim(p_notes),''),auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity')::int; v_cost:=(i->>'unit_cost')::numeric;
    if v_qty<=0 or v_cost<0 then raise exception 'Invalid purchase item'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.purchase_order_items(purchase_order_id,medicine_id,quantity_ordered,unit_cost) values(v_id,v_med,v_qty,v_cost);
    v_total:=v_total+v_qty*v_cost;
  end loop;
  update public.purchase_orders set total_cost=v_total,status='submitted',updated_at=now() where id=v_id;
  perform public.audit('PURCHASE_ORDER_CREATED','purchase_order',v_id::text,jsonb_build_object('total_cost',v_total));
  return v_id;
end $$;

create or replace function public.admin_update_purchase_order_status(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_status not in ('draft','submitted','approved','ordered','cancelled') then raise exception 'Invalid purchase order status'; end if;
  update public.purchase_orders set status=p_status,approved_by=case when p_status='approved' then auth.uid() else approved_by end,updated_at=now() where id=p_id;
  if not found then raise exception 'Purchase order not found'; end if;
  perform public.audit('PURCHASE_ORDER_STATUS','purchase_order',p_id::text,jsonb_build_object('status',p_status));
end $$;

create or replace function public.admin_record_supplier_payment(p_supplier_id uuid,p_supplier_name text,p_amount numeric,p_reference text,p_notes text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_amount<=0 then raise exception 'Amount must be greater than zero'; end if;
  insert into public.supplier_ledger(id,supplier_id,supplier_name,entry_type,reference,amount,notes,recorded_by)
  values(v_id,p_supplier_id,coalesce(nullif(trim(p_supplier_name),''),'Supplier'),'payment',nullif(trim(p_reference),''),p_amount,nullif(trim(p_notes),''),auth.uid());
  perform public.audit('SUPPLIER_PAYMENT','supplier',coalesce(p_supplier_id::text,p_supplier_name),jsonb_build_object('amount',p_amount,'reference',p_reference));
  return v_id;
end $$;

create or replace function public.admin_supplier_balances()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select coalesce(jsonb_agg(x order by x.balance desc),'[]'::jsonb) into v from (
    select coalesce(supplier_id::text,supplier_name) key,supplier_name,
      sum(case when entry_type in ('invoice','debit') then amount else -amount end) balance
    from public.supplier_ledger group by supplier_id,supplier_name
  ) x where x.balance<>0;
  return v;
end $$;

create or replace function public.generate_reorder_recommendations()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  insert into public.reorder_recommendations(medicine_id,recommended_quantity,average_daily_sales,days_of_cover,reason)
  select m.id,greatest(m.reorder_level-coalesce(i.quantity,0),ceil(coalesce(s.avg_daily,0)*14)::int),coalesce(s.avg_daily,0),
         case when coalesce(i.quantity,0)=0 then 0 else coalesce(i.quantity,0)/nullif(s.avg_daily,0) end,
         case when coalesce(i.quantity,0)=0 then 'Out of stock' when coalesce(s.avg_daily,0)>0 and i.quantity/s.avg_daily<7 then 'Less than 7 days of cover' else 'Below reorder level' end
  from public.medicines m join public.inventory i on i.medicine_id=m.id
  left join lateral (select coalesce(sum(si.quantity),0)/30.0 avg_daily from public.sale_items si join public.sales sa on sa.id=si.sale_id where si.medicine_id=m.id and sa.status='paid' and sa.created_at>=now()-interval '30 days') s on true
  where m.active and (i.quantity<=m.reorder_level or i.quantity=0) and not exists(select 1 from public.reorder_recommendations r where r.medicine_id=m.id and r.status='open');
  select coalesce(jsonb_agg(r order by r.generated_at desc),'[]'::jsonb) into v from public.reorder_recommendations r where r.status='open';
  return v;
end $$;

create or replace function public.admin_inventory_intelligence()
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select jsonb_build_object(
    'fast_moving',(select coalesce(jsonb_agg(x order by x.qty desc),'[]') from (select m.name,sum(si.quantity) qty from sale_items si join sales s on s.id=si.sale_id join medicines m on m.id=si.medicine_id where s.status='paid' and s.created_at>=now()-interval '30 days' group by m.name order by qty desc limit 10)x),
    'slow_moving',(select coalesce(jsonb_agg(x order by x.qty),'[]') from (select m.name,sum(si.quantity) qty from sale_items si join sales s on s.id=si.sale_id join medicines m on m.id=si.medicine_id where s.status='paid' and s.created_at>=now()-interval '30 days' group by m.name order by qty limit 10)x),
    'dead_stock',(select coalesce(jsonb_agg(x),'[]') from (select m.name,i.quantity,i.updated_at from inventory i join medicines m on m.id=i.medicine_id where i.quantity>0 and not exists(select 1 from sale_items si join sales s on s.id=si.sale_id where si.medicine_id=m.id and s.status='paid' and s.created_at>=now()-interval '60 days') order by i.quantity desc limit 20)x),
    'expiry',(select coalesce(jsonb_agg(x order by x.expiry_date),'[]') from (select m.name,b.batch_number,b.expiry_date,b.quantity from batches b join medicines m on m.id=b.medicine_id where b.quantity>0 and b.expiry_date<=current_date+90 order by b.expiry_date limit 30)x),
    'reorder',(select coalesce(jsonb_agg(x order by x.recommended_quantity desc),'[]') from (select r.*,m.name from reorder_recommendations r join medicines m on m.id=r.medicine_id where r.status='open')x)
  ) into result;
  return result;
end $$;

create or replace function public.set_medicine_location(p_medicine_id uuid,p_location_id uuid,p_preferred boolean default true)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if not exists(select 1 from medicines where id=p_medicine_id) then raise exception 'Medicine not found'; end if;
  if not exists(select 1 from stock_locations where id=p_location_id and active) then raise exception 'Location not found'; end if;
  if p_preferred then update medicine_locations set preferred=false where medicine_id=p_medicine_id; end if;
  insert into medicine_locations(medicine_id,location_id,preferred) values(p_medicine_id,p_location_id,p_preferred)
  on conflict(medicine_id,location_id) do update set preferred=excluded.preferred;
end $$;

create or replace function public.hold_sale(p_hold_reference text,p_cart jsonb,p_prescription_id uuid default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'seller' then raise exception 'Seller authorization required'; end if;
  if not exists(select 1 from seller_permissions where user_id=auth.uid() and can_sell) then raise exception 'Seller cannot process sales'; end if;
  if jsonb_array_length(coalesce(p_cart,'[]'::jsonb))=0 then raise exception 'Cart is empty'; end if;
  insert into held_sales(id,seller_id,hold_reference,cart,prescription_id,notes) values(v_id,auth.uid(),trim(p_hold_reference),p_cart,p_prescription_id,nullif(trim(p_notes),''))
  on conflict(seller_id,hold_reference) do update set cart=excluded.cart,prescription_id=excluded.prescription_id,notes=excluded.notes,created_at=now();
  perform public.audit('SALE_HELD','held_sale',v_id::text,jsonb_build_object('reference',p_hold_reference));
  return v_id;
end $$;

create or replace function public.my_held_sales()
returns setof public.held_sales language sql security definer set search_path=public as $$
  select * from public.held_sales where seller_id=auth.uid() order by created_at desc
$$;

create or replace function public.delete_held_sale(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  delete from held_sales where id=p_id and seller_id=auth.uid();
end $$;

-- Split manual payments for cash/other. Stock is deducted only when the sum reaches the sale total.
create or replace function public.add_manual_sale_payment(p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null)
returns numeric language plpgsql security definer set search_path=public as $$
declare s public.sales%rowtype; paid numeric; r record; b public.batches%rowtype; v_sum numeric;
begin
  select * into s from sales where id=p_sale_id for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if public.current_role()='seller' and s.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if p_method not in ('cash','other') or p_amount<=0 then raise exception 'Invalid split payment'; end if;
  select coalesce(sum(amount),0) into paid from payments where sale_id=p_sale_id and status='paid';
  if paid+p_amount>s.total_amount then raise exception 'Payment exceeds outstanding balance'; end if;
  insert into payments(sale_id,method,amount,provider_reference,status,confirmed_at) values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  v_sum:=paid+p_amount;
  if abs(v_sum-s.total_amount)<=0.01 then
    for r in select * from sale_items where sale_id=p_sale_id for update loop
      if r.batch_id is not null then
        select * into b from batches where id=r.batch_id and expiry_date>=current_date and quantity>=r.quantity for update;
      else
        select * into b from batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity order by expiry_date,received_at limit 1 for update;
        if b.id is not null then update sale_items set batch_id=b.id where id=r.id; end if;
      end if;
      if b.id is null then raise exception 'Insufficient unexpired stock while completing payment'; end if;
      update batches set quantity=quantity-r.quantity where id=b.id;
      update inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
      if not found then raise exception 'Inventory changed while completing payment'; end if;
      insert into stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(r.medicine_id,b.id,'sale',-r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('split_payment',true));
    end loop;
    update sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object('amount',v_sum));
  end if;
  return greatest(s.total_amount-v_sum,0);
end $$;

revoke all on function public.admin_create_purchase_order(uuid,text,date,text,jsonb) from public;
revoke all on function public.admin_update_purchase_order_status(uuid,text) from public;
revoke all on function public.admin_record_supplier_payment(uuid,text,numeric,text,text) from public;
revoke all on function public.admin_supplier_balances() from public;
revoke all on function public.generate_reorder_recommendations() from public;
revoke all on function public.admin_inventory_intelligence() from public;
revoke all on function public.set_medicine_location(uuid,uuid,boolean) from public;
revoke all on function public.hold_sale(text,jsonb,uuid,text) from public;
revoke all on function public.my_held_sales() from public;
revoke all on function public.delete_held_sale(uuid) from public;
revoke all on function public.add_manual_sale_payment(uuid,text,numeric,text) from public;
grant execute on function public.admin_create_purchase_order(uuid,text,date,text,jsonb) to authenticated;
grant execute on function public.admin_update_purchase_order_status(uuid,text) to authenticated;
grant execute on function public.admin_record_supplier_payment(uuid,text,numeric,text,text) to authenticated;
grant execute on function public.admin_supplier_balances() to authenticated;
grant execute on function public.generate_reorder_recommendations() to authenticated;
grant execute on function public.admin_inventory_intelligence() to authenticated;
grant execute on function public.set_medicine_location(uuid,uuid,boolean) to authenticated;
grant execute on function public.hold_sale(text,jsonb,uuid,text) to authenticated;
grant execute on function public.my_held_sales() to authenticated;
grant execute on function public.delete_held_sale(uuid) to authenticated;
grant execute on function public.add_manual_sale_payment(uuid,text,numeric,text) to authenticated;

-- ============================================================================
-- 017_operational_workflows.sql
-- ============================================================================
-- Complete operational workflows: PO receiving, quarantine/recall, branches and supplier performance.

create or replace function public.admin_receive_purchase_order(p_po_id uuid,p_invoice_number text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare po public.purchase_orders%rowtype; i jsonb; it public.purchase_order_items%rowtype; v_qty int; v_cost numeric; v_batch uuid; v_receipt uuid:=gen_random_uuid(); v_no text; v_total numeric:=0;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into po from purchase_orders where id=p_po_id for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if po.status not in ('approved','ordered','partially_received') then raise exception 'Purchase order is not ready for receiving'; end if;
  v_no:='GRN-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_receipt::text,'-',''),1,6);
  insert into stock_receipts(id,receipt_number,supplier_name,invoice_number,received_by) values(v_receipt,v_no,po.supplier_name,nullif(trim(p_invoice_number),''),auth.uid());
  for i in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    select * into it from purchase_order_items where id=(i->>'item_id')::uuid and purchase_order_id=p_po_id for update;
    if not found then raise exception 'Purchase order item not found'; end if;
    v_qty:=(i->>'quantity')::int; v_cost:=coalesce((i->>'unit_cost')::numeric,it.unit_cost);
    if v_qty is null or v_qty<=0 or it.quantity_received+v_qty>it.quantity_ordered then raise exception 'Invalid received quantity'; end if;
    insert into batches(medicine_id,batch_number,expiry_date,quantity,supplier_name)
      values(it.medicine_id,trim(i->>'batch_number'),(i->>'expiry_date')::date,v_qty,po.supplier_name)
      on conflict(medicine_id,batch_number) do update set quantity=batches.quantity+excluded.quantity,expiry_date=excluded.expiry_date,supplier_name=excluded.supplier_name
      returning id into v_batch;
    insert into stock_receipt_items(receipt_id,medicine_id,batch_id,quantity,unit_cost) values(v_receipt,it.medicine_id,v_batch,v_qty,v_cost);
    insert into stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(it.medicine_id,v_batch,'receive',v_qty,'purchase_order',p_po_id,auth.uid(),jsonb_build_object('purchase_order',po.po_number,'invoice',p_invoice_number));
    insert into inventory(medicine_id,quantity) values(it.medicine_id,v_qty) on conflict(medicine_id) do update set quantity=inventory.quantity+excluded.quantity;
    update purchase_order_items set quantity_received=quantity_received+v_qty where id=it.id;
    v_total:=v_total+v_qty*v_cost;
  end loop;
  if not exists(select 1 from purchase_order_items where purchase_order_id=p_po_id and quantity_received<quantity_ordered) then update purchase_orders set status='received',updated_at=now() where id=p_po_id;
  else update purchase_orders set status='partially_received',updated_at=now() where id=p_po_id; end if;
  update stock_receipts set total_cost=v_total where id=v_receipt;
  if po.supplier_id is not null or po.supplier_name is not null then
    insert into supplier_ledger(supplier_id,supplier_name,entry_type,reference,amount,notes,recorded_by) values(po.supplier_id,coalesce(po.supplier_name,'Supplier'),'invoice',p_invoice_number,v_total,'Purchase order receipt',auth.uid());
  end if;
  perform public.audit('PURCHASE_ORDER_RECEIVED','purchase_order',p_po_id::text,jsonb_build_object('receipt',v_no,'total_cost',v_total));
  return v_receipt;
end $$;

create or replace function public.admin_quarantine_batch(p_batch_id uuid,p_quantity integer,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare b public.batches%rowtype; q uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into b from batches where id=p_batch_id for update;
  if not found or p_quantity<=0 or b.quantity<p_quantity then raise exception 'Invalid quarantine quantity'; end if;
  update batches set quantity=quantity-p_quantity where id=p_batch_id;
  update inventory set quantity=quantity-p_quantity where medicine_id=b.medicine_id and quantity>=p_quantity;
  if not found then raise exception 'Inventory cannot be reduced for quarantine'; end if;
  insert into stock_quarantine(id,batch_id,medicine_id,quantity,reason,created_by) values(q,b.id,b.medicine_id,p_quantity,trim(p_reason),auth.uid());
  insert into stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(b.medicine_id,b.id,'adjustment',-p_quantity,'quarantine',q,auth.uid(),jsonb_build_object('reason',p_reason));
  perform public.audit('BATCH_QUARANTINED','batch',b.id::text,jsonb_build_object('quantity',p_quantity,'reason',p_reason));
  return q;
end $$;

create or replace function public.admin_resolve_quarantine(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare q public.stock_quarantine%rowtype;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_status not in ('released','disposed','returned') then raise exception 'Invalid resolution'; end if;
  select * into q from stock_quarantine where id=p_id for update;
  if not found or q.status<>'quarantined' then raise exception 'Quarantine record unavailable'; end if;
  if p_status='released' then update batches set quantity=quantity+q.quantity where id=q.batch_id; update inventory set quantity=quantity+q.quantity where medicine_id=q.medicine_id; end if;
  update stock_quarantine set status=p_status,resolved_by=auth.uid(),resolved_at=now() where id=p_id;
  perform public.audit('QUARANTINE_RESOLVED','quarantine',p_id::text,jsonb_build_object('status',p_status));
end $$;

create or replace function public.admin_create_recall(p_medicine_id uuid,p_batch_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  insert into recall_notices(id,medicine_id,batch_id,reason,created_by) values(v_id,p_medicine_id,p_batch_id,trim(p_reason),auth.uid());
  perform public.audit('RECALL_CREATED','recall',v_id::text,jsonb_build_object('medicine_id',p_medicine_id,'batch_id',p_batch_id,'reason',p_reason));
  return v_id;
end $$;

create or replace function public.admin_resolve_recall(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  update recall_notices set status='resolved',resolved_by=auth.uid(),resolved_at=now() where id=p_id and status='open';
  if not found then raise exception 'Recall not found'; end if;
  perform public.audit('RECALL_RESOLVED','recall',p_id::text,'{}');
end $$;

create or replace function public.admin_create_branch(p_name text,p_code text,p_phone text,p_address text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  insert into pharmacy_branches(id,name,code,phone,address) values(v_id,trim(p_name),upper(trim(p_code)),nullif(trim(p_phone),''),nullif(trim(p_address),''));
  perform public.audit('BRANCH_CREATED','branch',v_id::text,jsonb_build_object('code',p_code));
  return v_id;
end $$;

create or replace function public.admin_assign_branch(p_user_id uuid,p_branch_id uuid,p_manager boolean default false)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if not exists(select 1 from profiles where id=p_user_id) or not exists(select 1 from pharmacy_branches where id=p_branch_id and active) then raise exception 'User or branch not found'; end if;
  insert into branch_memberships(branch_id,user_id,is_manager) values(p_branch_id,p_user_id,p_manager) on conflict(branch_id,user_id) do update set is_manager=excluded.is_manager,active=true;
  perform public.audit('BRANCH_ASSIGNED','branch_membership',p_user_id::text,jsonb_build_object('branch_id',p_branch_id,'manager',p_manager));
end $$;

create or replace function public.admin_supplier_performance()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select coalesce(jsonb_agg(x order by x.purchase_value desc),'[]') into v from (
    select coalesce(supplier_name,'Unknown') supplier_name,count(*) receipts,coalesce(sum(total_cost),0) purchase_value,max(received_at) last_received
    from stock_receipts where status='received' and received_at>=now()-interval '180 days' group by supplier_name
  )x;
  return v;
end $$;

revoke all on function public.admin_receive_purchase_order(uuid,text,jsonb) from public;
revoke all on function public.admin_quarantine_batch(uuid,integer,text) from public;
revoke all on function public.admin_resolve_quarantine(uuid,text) from public;
revoke all on function public.admin_create_recall(uuid,uuid,text) from public;
revoke all on function public.admin_resolve_recall(uuid) from public;
revoke all on function public.admin_create_branch(text,text,text,text) from public;
revoke all on function public.admin_assign_branch(uuid,uuid,boolean) from public;
revoke all on function public.admin_supplier_performance() from public;
grant execute on function public.admin_receive_purchase_order(uuid,text,jsonb) to authenticated;
grant execute on function public.admin_quarantine_batch(uuid,integer,text) to authenticated;
grant execute on function public.admin_resolve_quarantine(uuid,text) to authenticated;
grant execute on function public.admin_create_recall(uuid,uuid,text) to authenticated;
grant execute on function public.admin_resolve_recall(uuid) to authenticated;
grant execute on function public.admin_create_branch(text,text,text,text) to authenticated;
grant execute on function public.admin_assign_branch(uuid,uuid,boolean) to authenticated;
grant execute on function public.admin_supplier_performance() to authenticated;

-- ============================================================================
-- 018_admin_command_center_analytics.sql
-- ============================================================================
create or replace function public.admin_dashboard_analytics()
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  with days as (
    select d::date report_date
    from generate_series(current_date-6,current_date,interval '1 day') d
  ),
  daily as (
    select d.report_date,
      coalesce((select sum(s.total_amount) from public.sales s where s.status='paid' and s.created_at::date=d.report_date),0)::numeric sales,
      coalesce((select sum(si.quantity*m.purchase_price) from public.sale_items si join public.medicines m on m.id=si.medicine_id join public.sales s on s.id=si.sale_id where s.status='paid' and s.created_at::date=d.report_date),0)::numeric cogs
    from days d
  ),
  stock as (
    select
      (select count(*) from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity<=m.reorder_level and m.active)::bigint low_stock,
      (select count(*) from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity=0 and m.active)::bigint out_of_stock,
      (select count(*) from public.batches where quantity>0 and expiry_date between current_date and current_date+30)::bigint expiring_batches,
      (select count(*) from public.batches where quantity>0 and expiry_date<current_date)::bigint expired_batches
  )
  select jsonb_build_object(
    'week',(select coalesce(jsonb_agg(jsonb_build_object('date',report_date,'sales',sales,'gross_profit',sales-cogs) order by report_date),'[]'::jsonb) from daily),
    'stock',(select to_jsonb(stock) from stock)
  ) where public.current_role()='admin';
$$;

revoke all on function public.admin_dashboard_analytics() from public;
grant execute on function public.admin_dashboard_analytics() to authenticated;
-- ============================================================================
-- 019_backend_integrity_hardening.sql
-- ============================================================================
create or replace function public.set_seller_active(p_user_id uuid,p_active boolean)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_role public.user_role;
begin
  if public.current_role()<>'admin' then
    raise exception 'Admin access required';
  end if;

  select role into v_role
  from public.profiles
  where id=p_user_id
  for update;

  if not found or v_role<>'seller' then
    raise exception 'Seller account not found';
  end if;

  update public.profiles set active=p_active where id=p_user_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(
    auth.uid(),
    case when p_active then 'seller_activated' else 'seller_disabled' end,
    'profiles',
    p_user_id::text,
    jsonb_build_object('active',p_active)
  );

  return true;
end;
$$;

revoke all on function public.set_seller_active(uuid,boolean) from public;
grant execute on function public.set_seller_active(uuid,boolean) to authenticated;

create or replace function public.prepare_mpesa_payment(p_sale_id uuid,p_phone text)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_sale public.sales%rowtype;
  v_id uuid;
begin
  select * into v_sale
  from public.sales
  where id=p_sale_id
  for update;

  if not found then raise exception 'Sale not found'; end if;
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Phone number is required'; end if;
  if v_sale.total_amount<=0 then raise exception 'Sale total must be greater than zero'; end if;
  if v_sale.total_amount<>trunc(v_sale.total_amount) then
    raise exception 'M-Pesa payments require a whole-shilling sale total';
  end if;
  if exists(
    select 1 from public.payments
    where sale_id=p_sale_id and method='mpesa' and status='pending'
  ) then
    raise exception 'An M-Pesa payment is already pending for this sale';
  end if;

  insert into public.payments(sale_id,method,amount,phone_number,status)
  values(p_sale_id,'mpesa',v_sale.total_amount,trim(p_phone),'pending')
  returning id into v_id;

  perform public.audit(
    'MPESA_PAYMENT_PREPARED',
    'payment',
    v_id::text,
    jsonb_build_object('sale_id',p_sale_id,'amount',v_sale.total_amount)
  );
  return v_id;
end;
$$;

revoke all on function public.prepare_mpesa_payment(uuid,text) from public;
grant execute on function public.prepare_mpesa_payment(uuid,text) to authenticated;
-- ============================================================================
-- 020_admin_transaction_visibility.sql
-- ============================================================================
create or replace function public.notify_admin_sale_event()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_seller text;
  v_action text;
  v_title text;
  v_message text;
  v_severity text:='info';
begin
  if tg_op='UPDATE' then
    if new.status is distinct from old.status then
      if new.status not in ('cancelled','refunded') then return new; end if;
    elsif new.total_amount is distinct from old.total_amount and new.total_amount>0 then
      null;
    else
      return new;
    end if;
  end if;
  if new.total_amount<=0 then return new; end if;

  select coalesce(full_name,'Seller') into v_seller
  from public.profiles where id=new.seller_id;

  v_action:=case
    when new.status='cancelled' then 'SALE_CANCELLED'
    when new.status='refunded' then 'SALE_REFUNDED'
    else 'SALE_OPENED'
  end;
  v_title:=case
    when new.status='cancelled' then 'Sale cancelled'
    when new.status='refunded' then 'Sale refunded'
    else 'New sale opened'
  end;
  if new.status in ('cancelled','refunded') then v_severity:='warning'; end if;
  v_message:=format('%s · KSh %s · %s',new.sale_number,to_char(new.total_amount,'FM999,999,999,990.00'),v_seller);

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),v_action,'sale',new.id::text,jsonb_build_object(
    'sale_number',new.sale_number,
    'seller_id',new.seller_id,
    'seller_name',v_seller,
    'amount',new.total_amount,
    'status',new.status
  ));

  insert into public.operational_notifications(notification_type,severity,title,message,entity_type,entity_id,metadata)
  values('transaction',v_severity,v_title,v_message,'sale',new.id::text,jsonb_build_object(
    'event',v_action,
    'sale_number',new.sale_number,
    'seller_id',new.seller_id,
    'seller_name',v_seller,
    'amount',new.total_amount,
    'sale_status',new.status
  ));
  return new;
end;
$$;

create or replace function public.notify_admin_payment_event()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_sale_number text;
  v_seller_id uuid;
  v_seller text;
  v_action text;
  v_title text;
  v_severity text:='info';
begin
  if tg_op='UPDATE' and new.status is not distinct from old.status then return new; end if;

  select s.sale_number,s.seller_id,coalesce(pr.full_name,'Seller')
  into v_sale_number,v_seller_id,v_seller
  from public.sales s
  join public.profiles pr on pr.id=s.seller_id
  where s.id=new.sale_id;

  v_action:='PAYMENT_'||upper(new.status::text);
  v_title:=case new.status
    when 'pending' then 'Payment started'
    when 'paid' then 'Payment received'
    when 'failed' then 'Payment failed'
    when 'refunded' then 'Payment refunded'
    else 'Payment updated'
  end;
  if new.status in ('failed','refunded') then v_severity:='warning'; end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),v_action,'payment',new.id::text,jsonb_build_object(
    'sale_id',new.sale_id,
    'sale_number',v_sale_number,
    'seller_id',v_seller_id,
    'seller_name',v_seller,
    'amount',new.amount,
    'method',new.method,
    'status',new.status,
    'provider_reference',new.provider_reference,
    'mpesa_receipt',new.mpesa_receipt
  ));

  insert into public.operational_notifications(notification_type,severity,title,message,entity_type,entity_id,metadata)
  values(
    'transaction',
    v_severity,
    v_title,
    format('%s · KSh %s · %s · %s',coalesce(v_sale_number,'Sale'),to_char(new.amount,'FM999,999,999,990.00'),upper(new.method),v_seller),
    'payment',
    new.id::text,
    jsonb_build_object(
      'event',v_action,
      'payment_id',new.id,
      'sale_id',new.sale_id,
      'sale_number',v_sale_number,
      'seller_id',v_seller_id,
      'seller_name',v_seller,
      'amount',new.amount,
      'method',new.method,
      'payment_status',new.status,
      'provider_reference',new.provider_reference,
      'mpesa_receipt',new.mpesa_receipt
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_admin_sale_visibility on public.sales;
create trigger trg_admin_sale_visibility
after insert or update of status,total_amount on public.sales
for each row execute function public.notify_admin_sale_event();

drop trigger if exists trg_admin_payment_visibility on public.payments;
create trigger trg_admin_payment_visibility
after insert or update of status on public.payments
for each row execute function public.notify_admin_payment_event();

create or replace function public.notify_admin_audit_event()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_severity text:='info';
  v_title text;
  v_message text;
begin
  if new.action in (
    'SALE_CREATED',
    'SALE_OPENED',
    'SALE_CANCELLED',
    'SALE_REFUNDED',
    'PAYMENT_CONFIRMED',
    'MPESA_PAYMENT_PREPARED',
    'PAYMENT_PENDING',
    'PAYMENT_PAID',
    'PAYMENT_FAILED',
    'PAYMENT_REFUNDED',
    'STOCK_DEDUCTED',
    'SPLIT_PAYMENT_COMPLETED'
  ) then
    return new;
  end if;

  if new.action ilike '%RESOLVED%' then
    v_severity:='info';
  elsif new.action ilike '%SECURITY%' or new.action ilike '%REVOKE%' then
    v_severity:='critical';
  elsif new.action ilike '%FAILED%'
     or new.action ilike '%REJECTED%'
     or new.action ilike '%REFUND%'
     or new.action ilike '%CANCEL%'
     or new.action ilike '%DISABLED%'
     or new.action ilike '%QUARANTINE%' then
    v_severity:='warning';
  end if;

  v_title:=initcap(replace(lower(new.action),'_',' '));
  v_message:=format('%s · %s',replace(new.entity_type,'_',' '),coalesce(new.entity_id,'record'));

  insert into public.operational_notifications(
    notification_type,severity,title,message,entity_type,entity_id,metadata
  ) values (
    'business_activity',v_severity,v_title,v_message,new.entity_type,new.entity_id,
    jsonb_build_object('action',new.action,'actor_id',new.actor_id,'audit_id',new.id)
  );
  return new;
end;
$$;

drop trigger if exists trg_admin_audit_visibility on public.audit_logs;
create trigger trg_admin_audit_visibility
after insert on public.audit_logs
for each row execute function public.notify_admin_audit_event();

create or replace function public.notify_admin_security_alert()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  insert into public.operational_notifications(
    notification_type,severity,title,message,entity_type,entity_id,metadata
  ) values (
    'security',
    case when new.severity in ('high','critical') then 'critical'
         when new.severity='medium' then 'warning'
         else 'info' end,
    new.title,
    format('%s · %s',replace(new.alert_type,'_',' '),coalesce(new.user_id::text,'business-wide')),
    'security_alert',
    new.id::text,
    jsonb_build_object('alert_type',new.alert_type,'severity',new.severity,'user_id',new.user_id,'details',new.details)
  );
  return new;
end;
$$;

drop trigger if exists trg_admin_security_alert_visibility on public.security_alerts;
create trigger trg_admin_security_alert_visibility
after insert on public.security_alerts
for each row execute function public.notify_admin_security_alert();

create or replace function public.audit_admin_master_data_change()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_before jsonb:='{}'::jsonb;
  v_after jsonb:=to_jsonb(new);
  v_changes jsonb;
  v_entity_id text;
  v_label text;
  v_action text;
begin
  if tg_op='UPDATE' then
    v_before:=to_jsonb(old);
    select coalesce(jsonb_object_agg(current_value.key,current_value.value),'{}'::jsonb)
    into v_changes
    from jsonb_each(v_after) as current_value(key,value)
    where v_before->current_value.key is distinct from current_value.value
      and current_value.key not in ('updated_at','updated_by')
      and not (tg_table_name='medicines' and current_value.key in ('selling_price','purchase_price'));
    if v_changes='{}'::jsonb then return new; end if;
  else
    v_changes:=v_after-'created_at'-'updated_at'-'updated_by';
  end if;

  v_entity_id:=coalesce(v_after->>'id',v_after->>'name','settings');
  v_label:=coalesce(v_after->>'name',v_after->>'pharmacy_name',v_entity_id);
  v_action:=case
    when tg_op='INSERT' then upper(tg_table_name)||'_CREATED'
    else upper(tg_table_name)||'_UPDATED'
  end;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),v_action,tg_table_name,v_entity_id,jsonb_build_object('label',v_label,'changes',v_changes));
  return new;
end;
$$;

drop trigger if exists trg_audit_medicine_master_data on public.medicines;
create trigger trg_audit_medicine_master_data
after insert or update on public.medicines
for each row execute function public.audit_admin_master_data_change();

drop trigger if exists trg_audit_supplier_master_data on public.suppliers;
create trigger trg_audit_supplier_master_data
after insert or update on public.suppliers
for each row execute function public.audit_admin_master_data_change();

drop trigger if exists trg_audit_pharmacy_settings on public.pharmacy_settings;
create trigger trg_audit_pharmacy_settings
after update on public.pharmacy_settings
for each row execute function public.audit_admin_master_data_change();

revoke all on function public.notify_admin_sale_event() from public,anon,authenticated;
revoke all on function public.notify_admin_payment_event() from public,anon,authenticated;
revoke all on function public.notify_admin_audit_event() from public,anon,authenticated;
revoke all on function public.notify_admin_security_alert() from public,anon,authenticated;
revoke all on function public.audit_admin_master_data_change() from public,anon,authenticated;

create or replace function public.admin_transaction_feed(
  p_limit integer default 200,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns table(
  payment_id uuid,
  sale_id uuid,
  sale_number text,
  seller_name text,
  amount numeric,
  method text,
  status text,
  provider_reference text,
  mpesa_receipt text,
  created_at timestamptz,
  confirmed_at timestamptz
)
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
begin
  if public.current_role()<>'admin' then
    raise exception 'Admin access required';
  end if;

  return query
  select p.id,p.sale_id,s.sale_number,coalesce(pr.full_name,'Seller'),p.amount,p.method,p.status::text,
         p.provider_reference,p.mpesa_receipt,p.created_at,p.confirmed_at
  from public.payments p
  join public.sales s on s.id=p.sale_id
  join public.profiles pr on pr.id=s.seller_id
  where p_before_created_at is null
     or (p.created_at,p.id)<(p_before_created_at,p_before_id)
  order by p.created_at desc,p.id desc
  limit greatest(1,least(coalesce(p_limit,200),500));
end;
$$;

revoke all on function public.admin_transaction_feed(integer,timestamptz,uuid) from public,anon;
grant execute on function public.admin_transaction_feed(integer,timestamptz,uuid) to authenticated;

create or replace function public.admin_activity_feed(
  p_limit integer default 50,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns table(
  id uuid,
  severity text,
  title text,
  message text,
  notification_type text,
  entity_type text,
  entity_id text,
  metadata jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
begin
  if public.current_role()<>'admin' then
    raise exception 'Admin access required';
  end if;

  return query
  select n.id,n.severity,n.title,n.message,n.notification_type,n.entity_type,n.entity_id,n.metadata,n.read_at,n.created_at
  from public.operational_notifications n
  where p_before_created_at is null or (n.created_at,n.id)<(p_before_created_at,p_before_id)
  order by n.created_at desc,n.id desc
  limit greatest(1,least(coalesce(p_limit,50),200));
end;
$$;

revoke all on function public.admin_activity_feed(integer,timestamptz,uuid) from public,anon;
grant execute on function public.admin_activity_feed(integer,timestamptz,uuid) to authenticated;

create index if not exists idx_operational_notifications_history
on public.operational_notifications(created_at desc,id desc);
-- ============================================================================
-- 021_sale_customer_details.sql
-- ============================================================================
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

-- ============================================================================
-- 022_mpesa_c2b_inbox.sql
-- ============================================================================
-- Store PayBill details and receive confirmed C2B transactions for admin reconciliation.
alter table public.pharmacy_settings
  add column if not exists paybill_account_number text;

update public.pharmacy_settings
set paybill_number=coalesce(nullif(trim(paybill_number),''),'247247'),
    paybill_account_number=coalesce(nullif(trim(paybill_account_number),''),'427459')
where id=true;

create table if not exists public.mpesa_c2b_transactions(
  trans_id text primary key,
  account_reference text not null,
  amount numeric(12,2) not null check(amount>0),
  phone_number text,
  payer_name text,
  transaction_time timestamptz,
  received_at timestamptz not null default now(),
  raw_payload jsonb not null,
  status text not null default 'unmatched' check(status in ('unmatched','matched','ignored')),
  matched_sale_id uuid references public.sales(id),
  matched_by uuid references public.profiles(id),
  matched_at timestamptz
);

create index if not exists idx_mpesa_c2b_unmatched on public.mpesa_c2b_transactions(received_at desc) where status='unmatched';
alter table public.mpesa_c2b_transactions enable row level security;
revoke all on public.mpesa_c2b_transactions from public,anon;
revoke insert,update,delete on public.mpesa_c2b_transactions from authenticated;
grant select on public.mpesa_c2b_transactions to authenticated;
drop policy if exists "admin read c2b transactions" on public.mpesa_c2b_transactions;
create policy "admin read c2b transactions" on public.mpesa_c2b_transactions for select using(public.current_role()='admin');

create or replace function public.validate_mpesa_c2b_account(p_account_reference text,p_amount numeric)
returns text
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_account text;
begin
  select paybill_account_number into v_account from public.pharmacy_settings where id=true;
  if p_account_reference is null or v_account is null or trim(p_account_reference)<>trim(v_account) then return 'C2B00012'; end if;
  if p_amount is null or p_amount<=0 then return 'C2B00013'; end if;
  return '0';
end;
$$;

create or replace function public.record_mpesa_c2b_callback(
  p_receipt text,p_account_reference text,p_amount numeric,p_phone text,
  p_payer_name text,p_transaction_time timestamptz,p_payload jsonb
)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_existing public.mpesa_c2b_transactions%rowtype;
begin
  if nullif(trim(p_receipt),'') is null then raise exception 'M-Pesa receipt is required'; end if;
  if nullif(trim(p_account_reference),'') is null then raise exception 'PayBill account reference is required'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be positive'; end if;

  insert into public.mpesa_c2b_transactions(trans_id,account_reference,amount,phone_number,payer_name,transaction_time,raw_payload)
  values(trim(p_receipt),trim(p_account_reference),p_amount,p_phone,nullif(trim(p_payer_name),''),p_transaction_time,coalesce(p_payload,'{}'::jsonb))
  on conflict(trans_id) do nothing;
  if not found then
    select * into v_existing from public.mpesa_c2b_transactions where trans_id=trim(p_receipt);
    if v_existing.account_reference<>trim(p_account_reference) or v_existing.amount<>p_amount then
      raise exception 'Duplicate M-Pesa receipt has different payment details';
    end if;
  end if;
end;
$$;

revoke all on function public.validate_mpesa_c2b_account(text,numeric) from public,anon,authenticated;
grant execute on function public.validate_mpesa_c2b_account(text,numeric) to service_role;
revoke all on function public.record_mpesa_c2b_callback(text,text,numeric,text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.record_mpesa_c2b_callback(text,text,numeric,text,text,timestamptz,jsonb) to service_role;

-- ============================================================================
-- 023_admin_match_c2b_payments.sql
-- ============================================================================
-- Admins manually assign fixed-account PayBill payments to the correct sale.
create or replace function public.admin_match_mpesa_c2b(p_trans_id text,p_sale_number text)
returns numeric
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  t public.mpesa_c2b_transactions%rowtype;
  s public.sales%rowtype;
  r record;
  b public.batches%rowtype;
  v_paid numeric(12,2);
  v_remaining numeric(12,2);
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into t from public.mpesa_c2b_transactions where trans_id=trim(p_trans_id) for update;
  if not found or t.status<>'unmatched' then raise exception 'PayBill transaction is unavailable or already matched'; end if;
  select * into s from public.sales where sale_number=trim(p_sale_number) for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale not found or is not awaiting payment'; end if;

  select coalesce(sum(amount),0) into v_paid from public.payments where sale_id=s.id and status='paid';
  if v_paid+t.amount>s.total_amount+0.01 then raise exception 'Payment exceeds the sale balance'; end if;

  insert into public.payments(sale_id,method,amount,provider_reference,mpesa_receipt,phone_number,transaction_time,status,confirmed_at,callback_payload)
  values(s.id,'mpesa',t.amount,t.trans_id,t.trans_id,t.phone_number,t.transaction_time,'paid',now(),t.raw_payload);
  v_remaining:=greatest(s.total_amount-(v_paid+t.amount),0);

  if v_remaining<=0.01 then
    for r in select * from public.sale_items where sale_id=s.id for update loop
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
      values(r.medicine_id,b.id,'sale',-r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('mpesa_receipt',t.trans_id,'source','manual_c2b_match'));
      if r.prescription_item_id is not null then
        update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id;
      end if;
    end loop;
    update public.sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object('amount',v_paid+t.amount,'source','mpesa_c2b'));
  end if;

  update public.mpesa_c2b_transactions set status='matched',matched_sale_id=s.id,matched_by=auth.uid(),matched_at=now() where trans_id=t.trans_id;
  perform public.audit('MPESA_C2B_MANUALLY_MATCHED','sale',s.id::text,jsonb_build_object('receipt',t.trans_id,'amount',t.amount,'remaining',v_remaining));
  return v_remaining;
end;
$$;

revoke all on function public.admin_match_mpesa_c2b(text,text) from public,anon;
grant execute on function public.admin_match_mpesa_c2b(text,text) to authenticated;

-- ============================================================================
-- 024_manual_mpesa_verification.sql
-- ============================================================================
-- Manual M-PESA receipt verification now; preserve a source field for future API verification.
alter table public.payments
  add column if not exists verified_by uuid references public.profiles(id),
  add column if not exists verification_source text not null default 'manual'
    check (verification_source in ('manual','daraja_stk','daraja_c2b'));

create or replace function public.set_payment_verification_source()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.method='mpesa' and new.checkout_request_id is not null then
    new.verification_source:='daraja_stk';
    new.verified_by:=null;
  elsif new.method='mpesa' and new.mpesa_receipt is not null and new.callback_payload is not null and new.verified_by is null then
    new.verification_source:='daraja_c2b';
    new.verified_by:=auth.uid();
  end if;
  return new;
end;
$$;
drop trigger if exists trg_payment_verification_source on public.payments;
create trigger trg_payment_verification_source before insert or update
on public.payments for each row execute function public.set_payment_verification_source();

create or replace function public.verify_manual_mpesa_payment(
  p_sale_id uuid,
  p_amount numeric,
  p_transaction_code text
)
returns numeric
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  s public.sales%rowtype;
  r record;
  b public.batches%rowtype;
  v_code text:=upper(trim(coalesce(p_transaction_code,'')));
begin
  if public.current_role() is null or public.current_role() not in ('admin','seller') then raise exception 'Staff authorization required'; end if;
  if length(v_code)<6 or length(v_code)>64 or v_code !~ '^[A-Z0-9]+$' then
    raise exception 'Enter a valid M-PESA transaction code';
  end if;

  select * into s from public.sales where id=p_sale_id for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if public.current_role()='seller' and s.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if p_amount is null or p_amount<>s.total_amount then raise exception 'M-PESA amount must exactly match the sale total'; end if;
  if exists(select 1 from public.payments where sale_id=s.id and status='paid') then raise exception 'This sale already has a recorded payment'; end if;
  if exists(select 1 from public.payments where upper(mpesa_receipt)=v_code) then raise exception 'This M-PESA transaction code has already been used'; end if;

  insert into public.payments(sale_id,method,amount,provider_reference,mpesa_receipt,status,confirmed_at,verified_by,verification_source)
  values(s.id,'mpesa',p_amount,v_code,v_code,'paid',now(),auth.uid(),'manual');

  for r in select * from public.sale_items where sale_id=s.id for update loop
    if r.batch_id is not null then
      select * into b from public.batches where id=r.batch_id and medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity for update;
    else
      select * into b from public.batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity order by expiry_date,received_at limit 1 for update;
      if b.id is not null then update public.sale_items set batch_id=b.id where id=r.id; end if;
    end if;
    if b.id is null then raise exception 'Insufficient unexpired stock while completing payment'; end if;
    update public.batches set quantity=quantity-r.quantity where id=b.id;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Inventory changed while completing payment'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,b.id,'sale',-r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('mpesa_receipt',v_code,'verification_source','manual'));
    if r.prescription_item_id is not null then
      update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id;
    end if;
  end loop;

  update public.sales set status='paid' where id=s.id;
  perform public.audit('MANUAL_MPESA_PAYMENT_VERIFIED','sale',s.id::text,jsonb_build_object('amount',p_amount,'transaction_code',v_code,'verified_by',auth.uid()));
  return 0;
end;
$$;

revoke all on function public.verify_manual_mpesa_payment(uuid,numeric,text) from public,anon;
grant execute on function public.verify_manual_mpesa_payment(uuid,numeric,text) to authenticated;

-- Expose verification attribution in the admin transaction view.
drop function public.admin_transaction_feed(integer,timestamptz,uuid);
create function public.admin_transaction_feed(
  p_limit integer default 200,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns table(
  payment_id uuid,sale_id uuid,sale_number text,seller_name text,amount numeric,method text,status text,
  provider_reference text,mpesa_receipt text,created_at timestamptz,confirmed_at timestamptz,
  verified_by_name text,verification_source text
)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin access required'; end if;
  return query
  select p.id,p.sale_id,s.sale_number,coalesce(seller.full_name,'Seller'),p.amount,p.method,p.status::text,
         p.provider_reference,p.mpesa_receipt,p.created_at,p.confirmed_at,
         coalesce(verifier.full_name,case when p.verification_source='manual' then 'Staff' else 'Safaricom' end),
         p.verification_source
  from public.payments p
  join public.sales s on s.id=p.sale_id
  join public.profiles seller on seller.id=s.seller_id
  left join public.profiles verifier on verifier.id=p.verified_by
  where p_before_created_at is null or (p.created_at,p.id)<(p_before_created_at,p_before_id)
  order by p.created_at desc,p.id desc
  limit greatest(1,least(coalesce(p_limit,200),500));
end;
$$;
revoke all on function public.admin_transaction_feed(integer,timestamptz,uuid) from public,anon;
grant execute on function public.admin_transaction_feed(integer,timestamptz,uuid) to authenticated;

-- ============================================================================
-- 025_pending_sales_and_single_admin.sql
-- ============================================================================
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
