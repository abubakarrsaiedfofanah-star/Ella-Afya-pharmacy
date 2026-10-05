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
