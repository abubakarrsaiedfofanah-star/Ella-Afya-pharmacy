-- Separate the calculated monthly pay from payment transactions so a month can
-- be paid in installments and every installment has its own signed receipt.
create table if not exists public.payroll_periods(
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.profiles(id) on delete restrict,
  staff_name text not null,
  pay_month date not null check(extract(day from pay_month)=1),
  base_pay numeric(12,2) not null check(base_pay>=0),
  additions numeric(12,2) not null default 0 check(additions>=0),
  deductions numeric(12,2) not null default 0 check(deductions>=0),
  gross_pay numeric(12,2) generated always as (base_pay+additions) stored,
  net_pay numeric(12,2) generated always as (base_pay+additions-deductions) stored check(base_pay+additions>=deductions),
  currency_code text not null default 'KES',
  created_at timestamptz not null default now(),
  unique(staff_id,pay_month)
);

alter table public.payroll_payments
  add column if not exists payroll_period_id uuid references public.payroll_periods(id) on delete restrict,
  add column if not exists cash_tendered numeric(12,2) check(cash_tendered is null or cash_tendered>=0),
  add column if not exists change_due numeric(12,2) check(change_due is null or change_due>=0);
alter table public.payroll_payments drop constraint if exists payroll_payments_staff_id_pay_month_key;
create index if not exists idx_payroll_payments_period_paid on public.payroll_payments(payroll_period_id,paid_at desc);
create index if not exists idx_payroll_payments_month_paid on public.payroll_payments(pay_month desc,paid_at desc,id desc);

-- Existing records represented one full monthly payment. Preserve their value
-- as the period net pay and link each old receipt to its new period.
insert into public.payroll_periods(staff_id,staff_name,pay_month,base_pay,additions,deductions,currency_code)
select p.staff_id,p.staff_name,p.pay_month,p.amount,0,0,p.currency_code
from public.payroll_payments p
where p.payroll_period_id is null
on conflict(staff_id,pay_month) do nothing;
update public.payroll_payments p
set payroll_period_id=pp.id
from public.payroll_periods pp
where p.payroll_period_id is null and pp.staff_id=p.staff_id and pp.pay_month=p.pay_month;

alter table public.payroll_periods enable row level security;
revoke all on public.payroll_periods from public,anon,authenticated;
grant select on public.payroll_periods to authenticated;
drop policy if exists "admin read payroll periods" on public.payroll_periods;
create policy "admin read payroll periods" on public.payroll_periods for select using(public.current_role()='admin');

create or replace function public.admin_calculate_staff_payroll(
  p_staff_id uuid,p_pay_month date,p_base_pay numeric,p_additions numeric default 0,p_deductions numeric default 0
)
returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp
as $$
declare v_period public.payroll_periods%rowtype; v_paid numeric(12,2); v_staff text;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_staff_id is null or p_pay_month is null or extract(day from p_pay_month)<>1 then raise exception 'Choose a valid staff member and pay month'; end if;
  select full_name into v_staff from public.profiles where id=p_staff_id and role='seller';
  if not found then raise exception 'Choose a valid staff account'; end if;
  if p_base_pay is null or p_additions is null or p_deductions is null or least(p_base_pay,p_additions,p_deductions)<0 then raise exception 'Pay amounts cannot be negative'; end if;
  if p_base_pay<>round(p_base_pay,2) or p_additions<>round(p_additions,2) or p_deductions<>round(p_deductions,2) then raise exception 'Pay amounts must use two decimal places'; end if;
  select * into v_period from public.payroll_periods where staff_id=p_staff_id and pay_month=p_pay_month;
  if found then
    select coalesce(sum(amount),0)::numeric(12,2) into v_paid from public.payroll_payments where payroll_period_id=v_period.id;
  else
    if p_base_pay+p_additions<p_deductions then raise exception 'Deductions cannot exceed gross pay'; end if;
    select coalesce(currency,'KES') into v_period.currency_code from public.pharmacy_settings where id=true;
    v_period.staff_name:=v_staff; v_period.base_pay:=p_base_pay; v_period.additions:=p_additions; v_period.deductions:=p_deductions;
    v_period.gross_pay:=p_base_pay+p_additions; v_period.net_pay:=p_base_pay+p_additions-p_deductions;
    v_period.pay_month:=p_pay_month;
    v_paid:=0;
  end if;
  return jsonb_build_object('staff_name',v_period.staff_name,'pay_month',v_period.pay_month,'base_pay',v_period.base_pay,
    'additions',v_period.additions,'deductions',v_period.deductions,'gross_pay',v_period.gross_pay,'net_pay',v_period.net_pay,
    'paid',v_paid,'balance',greatest(v_period.net_pay-v_paid,0),'currency_code',coalesce(v_period.currency_code,'KES'));
end;
$$;
revoke all on function public.admin_calculate_staff_payroll(uuid,date,numeric,numeric,numeric) from public,anon;
grant execute on function public.admin_calculate_staff_payroll(uuid,date,numeric,numeric,numeric) to authenticated;

drop function if exists public.admin_record_staff_payroll(uuid,date,numeric,text,text,text);
create or replace function public.admin_record_staff_payroll(
  p_staff_id uuid,p_pay_month date,p_base_pay numeric,p_additions numeric,p_deductions numeric,
  p_amount_paid numeric,p_payment_method text,p_payment_reference text default null,p_notes text default null
)
returns public.payroll_payments
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  v_staff_name text; v_admin_name text; v_currency text; v_signature_path text; v_signature_name text;
  v_period public.payroll_periods%rowtype; v_payment public.payroll_payments%rowtype; v_paid numeric(12,2); v_amount numeric(12,2);
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_staff_id is null or p_pay_month is null or extract(day from p_pay_month)<>1 then raise exception 'Choose a valid payroll month'; end if;
  if p_base_pay is null or p_additions is null or p_deductions is null or least(p_base_pay,p_additions,p_deductions)<0 then raise exception 'Pay amounts cannot be negative'; end if;
  if p_base_pay<>round(p_base_pay,2) or p_additions<>round(p_additions,2) or p_deductions<>round(p_deductions,2) then raise exception 'Pay amounts must use two decimal places'; end if;
  if p_base_pay+p_additions<p_deductions then raise exception 'Deductions cannot exceed gross pay'; end if;
  if p_amount_paid is null or p_amount_paid<=0 or p_amount_paid<>round(p_amount_paid,2) then raise exception 'Payment must be greater than zero and use two decimal places'; end if;
  if p_payment_method not in ('cash','mpesa','bank','other') then raise exception 'Choose a valid payment method'; end if;
  if p_payment_method in ('mpesa','bank') and nullif(trim(p_payment_reference),'') is null then raise exception 'A payment reference is required for M-Pesa or bank payments'; end if;
  select full_name into v_staff_name from public.profiles where id=p_staff_id and role='seller';
  if not found then raise exception 'Choose a valid staff account'; end if;
  select full_name into v_admin_name from public.profiles where id=auth.uid() and role='admin';
  select currency,receipt_signature_path,receipt_signature_name into v_currency,v_signature_path,v_signature_name from public.pharmacy_settings where id=true;
  if nullif(trim(v_signature_path),'') is null or nullif(trim(v_signature_name),'') is null then raise exception 'Save the admin receipt signature and signer name in Pharmacy Settings first'; end if;

  insert into public.payroll_periods(staff_id,staff_name,pay_month,base_pay,additions,deductions,currency_code)
  values(p_staff_id,v_staff_name,p_pay_month,p_base_pay,p_additions,p_deductions,coalesce(nullif(trim(v_currency),''),'KES'))
  on conflict(staff_id,pay_month) do nothing;
  select * into v_period from public.payroll_periods where staff_id=p_staff_id and pay_month=p_pay_month for update;
  if v_period.base_pay<>p_base_pay or v_period.additions<>p_additions or v_period.deductions<>p_deductions then
    raise exception 'This month already has a saved pay calculation. Use its saved amounts to record the balance.';
  end if;
  select coalesce(sum(amount),0)::numeric(12,2) into v_paid from public.payroll_payments where payroll_period_id=v_period.id;
  v_amount:=p_amount_paid::numeric(12,2);
  if v_amount>v_period.net_pay-v_paid then raise exception 'Payment exceeds the remaining payroll balance of %',v_period.net_pay-v_paid; end if;

  insert into public.payroll_payments(payroll_number,staff_id,staff_name,pay_month,amount,currency_code,payment_method,payment_reference,notes,paid_by,paid_by_name,signature_admin_id,signature_path,signature_name,payroll_period_id)
  values('PAY-'||to_char(p_pay_month,'YYYYMM')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),p_staff_id,v_staff_name,p_pay_month,v_amount,coalesce(nullif(trim(v_currency),''),'KES'),p_payment_method,nullif(trim(p_payment_reference),''),nullif(trim(p_notes),''),auth.uid(),coalesce(v_admin_name,'Administrator'),auth.uid(),v_signature_path,v_signature_name,v_period.id)
  returning * into v_payment;
  perform public.audit('STAFF_PAYROLL_RECORDED','payroll',v_payment.id::text,jsonb_build_object('staff_id',p_staff_id,'pay_month',p_pay_month,'amount_paid',v_amount,'net_pay',v_period.net_pay,'balance',v_period.net_pay-v_paid-v_amount,'method',p_payment_method));
  return v_payment;
end;
$$;
revoke all on function public.admin_record_staff_payroll(uuid,date,numeric,numeric,numeric,numeric,text,text,text) from public,anon;
grant execute on function public.admin_record_staff_payroll(uuid,date,numeric,numeric,numeric,numeric,text,text,text) to authenticated;

-- Compatibility for an older Admin browser while it refreshes: treat its
-- entered payment as the complete base pay for that month.
create or replace function public.admin_record_staff_payroll(
  p_staff_id uuid,p_pay_month date,p_amount numeric,p_payment_method text,p_payment_reference text default null,p_notes text default null
)
returns public.payroll_payments
language sql security definer set search_path=public,pg_temp
as $$
  select public.admin_record_staff_payroll(p_staff_id,p_pay_month,p_amount,0,0,p_amount,p_payment_method,p_payment_reference,p_notes);
$$;
revoke all on function public.admin_record_staff_payroll(uuid,date,numeric,text,text,text) from public,anon;
grant execute on function public.admin_record_staff_payroll(uuid,date,numeric,text,text,text) to authenticated;

create or replace function public.admin_payroll_history(
  p_month date default null,p_staff_id uuid default null,p_search text default null,p_limit integer default 100,p_offset integer default 0
)
returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp
as $$
declare v_search text:=trim(coalesce(p_search,'')); v_result jsonb;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  with filtered as (
    select pp.*,pr.base_pay,pr.additions,pr.deductions,pr.gross_pay,pr.net_pay,pr.id as period_id,
      (select coalesce(sum(paid.amount),0) from public.payroll_payments paid where paid.payroll_period_id=pr.id)::numeric(12,2) period_paid
    from public.payroll_payments pp left join public.payroll_periods pr on pr.id=pp.payroll_period_id
    where (p_month is null or pp.pay_month=p_month) and (p_staff_id is null or pp.staff_id=p_staff_id)
      and (v_search='' or concat_ws(' ',pp.payroll_number,pp.staff_name,pp.payment_reference,pp.notes) ilike '%'||replace(replace(v_search,'%','\%'),'_','\_')||'%')
  ), page_rows as (
    select * from filtered order by pay_month desc,paid_at desc,id desc
    limit greatest(1,least(coalesce(p_limit,100),100)) offset greatest(0,least(coalesce(p_offset,0),1000000))
  )
  select jsonb_build_object(
    'rows',(select coalesce(jsonb_agg(to_jsonb(r) order by r.pay_month desc,r.paid_at desc,r.id desc),'[]'::jsonb) from page_rows r),
    'payment_count',(select count(*) from filtered),
    'staff_count',(select count(distinct staff_id) from filtered),
    'totals_by_currency',(select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency_code,'amount',c.total) order by c.currency_code),'[]'::jsonb)
      from (select currency_code,sum(amount)::numeric(12,2) total from filtered group by currency_code) c)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_payroll_history(date,uuid,text,integer,integer) from public,anon;
grant execute on function public.admin_payroll_history(date,uuid,text,integer,integer) to authenticated;

-- Keep seller receipts able to report cash tender and change from the payment
-- ledger. Values are recorded by the payment RPC, never inferred in the UI.
alter table public.payments
  add column if not exists cash_tendered numeric(12,2) check(cash_tendered is null or cash_tendered>=0),
  add column if not exists change_due numeric(12,2) check(change_due is null or change_due>=0);

drop function if exists public.add_manual_sale_payment(uuid,text,numeric,text);
create or replace function public.add_manual_sale_payment(
  p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null,p_cash_tendered numeric default null
)
returns numeric
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
  s public.sales%rowtype; paid numeric(12,2); r record; b public.batches%rowtype;
  v_sum numeric(12,2); v_amount numeric(12,2); v_tendered numeric(12,2); v_change numeric(12,2);
begin
  if auth.uid() is null or public.current_role() not in ('admin','seller') then raise exception 'Active staff authorization required'; end if;
  select * into s from public.sales where id=p_sale_id for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if public.current_role()='seller' then
    if s.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
    if not exists(select 1 from public.seller_permissions where user_id=auth.uid() and can_sell=true) then raise exception 'Seller is not permitted to process sales'; end if;
  end if;
  if p_method not in ('cash','other') or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Enter a valid payment amount to two decimal places'; end if;
  v_amount:=p_amount::numeric(12,2);
  if p_method='cash' then
    if p_cash_tendered is null or p_cash_tendered<v_amount or p_cash_tendered<>round(p_cash_tendered,2) then raise exception 'Cash received must cover the payment and use two decimal places'; end if;
    v_tendered:=p_cash_tendered::numeric(12,2); v_change:=v_tendered-v_amount;
  elsif p_cash_tendered is not null then raise exception 'Cash received is only valid for cash payments'; end if;
  select coalesce(sum(amount),0)::numeric(12,2) into paid from public.payments where sale_id=p_sale_id and status='paid';
  if paid+v_amount>s.total_amount then raise exception 'Payment exceeds outstanding balance'; end if;
  insert into public.payments(sale_id,method,amount,provider_reference,status,confirmed_at,cash_tendered,change_due)
  values(p_sale_id,p_method,v_amount,p_reference,'paid',now(),v_tendered,v_change);
  v_sum:=paid+v_amount;
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
      if r.prescription_item_id is not null then update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id; end if;
    end loop;
    update public.sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object('amount',v_sum));
  end if;
  return greatest(s.total_amount-v_sum,0);
end;
$$;
revoke all on function public.add_manual_sale_payment(uuid,text,numeric,text,numeric) from public,anon;
grant execute on function public.add_manual_sale_payment(uuid,text,numeric,text,numeric) to authenticated;

notify pgrst,'reload schema';
