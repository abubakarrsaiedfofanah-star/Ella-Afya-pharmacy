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
