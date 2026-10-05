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
