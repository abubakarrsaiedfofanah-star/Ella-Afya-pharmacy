-- Admin-only staff payroll records and protected signature snapshots for receipts.
alter table public.pharmacy_settings
  add column if not exists receipt_signature_path text,
  add column if not exists receipt_signature_name text,
  add column if not exists receipt_signature_updated_by uuid references public.profiles(id);

alter table public.sales
  add column if not exists authorized_signature_admin uuid references public.profiles(id),
  add column if not exists authorized_signature_path text,
  add column if not exists authorized_signature_name text,
  add column if not exists signature_applied_at timestamptz;

create or replace function public.capture_sale_receipt_signature()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_path text; v_name text; v_admin uuid;
begin
  if new.status='paid' and (tg_op='INSERT' or old.status is distinct from 'paid') then
    select receipt_signature_path,receipt_signature_name,receipt_signature_updated_by
      into v_path,v_name,v_admin
      from public.pharmacy_settings where id=true;
    if nullif(trim(v_path),'') is null or nullif(trim(v_name),'') is null or v_admin is null then
      raise exception 'Admin must save a receipt signature and signer name before completing a sale';
    end if;
    new.authorized_signature_path:=v_path;
    new.authorized_signature_name:=v_name;
    new.authorized_signature_admin:=v_admin;
    new.signature_applied_at:=now();
  elsif tg_op='UPDATE' and old.status='paid' and (
    new.authorized_signature_admin is distinct from old.authorized_signature_admin or
    new.authorized_signature_path is distinct from old.authorized_signature_path or
    new.authorized_signature_name is distinct from old.authorized_signature_name or
    new.signature_applied_at is distinct from old.signature_applied_at
  ) then
    raise exception 'Receipt signature records are immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.capture_sale_receipt_signature() from public,anon,authenticated;
drop trigger if exists trg_capture_sale_receipt_signature on public.sales;
drop trigger if exists trg_capture_sale_receipt_signature_insert on public.sales;
drop trigger if exists trg_capture_sale_receipt_signature_update on public.sales;
create trigger trg_capture_sale_receipt_signature_insert
before insert on public.sales for each row execute function public.capture_sale_receipt_signature();
create trigger trg_capture_sale_receipt_signature_update
before update of status,authorized_signature_admin,authorized_signature_path,authorized_signature_name,signature_applied_at
on public.sales for each row execute function public.capture_sale_receipt_signature();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('receipt-signatures','receipt-signatures',false,1048576,array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set public=false,file_size_limit=1048576,allowed_mime_types=array['image/png','image/jpeg','image/webp'];

drop policy if exists "staff can read receipt signature images" on storage.objects;
create policy "staff can read receipt signature images" on storage.objects for select
using(bucket_id='receipt-signatures' and (
  public.current_role()='admin' or
  (public.current_role()='seller' and exists(
    select 1 from public.sales s
    where s.authorized_signature_path=name and s.seller_id=auth.uid()
      and s.status in ('paid','refunded','cancelled')
  ))
));
drop policy if exists "admin can upload own receipt signature" on storage.objects;
create policy "admin can upload own receipt signature" on storage.objects for insert to authenticated
with check(bucket_id='receipt-signatures' and public.current_role()='admin' and (storage.foldername(name))[1]=auth.uid()::text);

create table if not exists public.payroll_payments(
  id uuid primary key default gen_random_uuid(),
  payroll_number text not null unique,
  staff_id uuid not null references public.profiles(id) on delete restrict,
  staff_name text not null,
  pay_month date not null check(extract(day from pay_month)=1),
  amount numeric(12,2) not null check(amount>0),
  currency_code text not null default 'KES',
  payment_method text not null check(payment_method in ('cash','mpesa','bank','other')),
  payment_reference text,
  notes text,
  paid_at timestamptz not null default now(),
  paid_by uuid not null references public.profiles(id),
  paid_by_name text not null,
  signature_admin_id uuid not null references public.profiles(id),
  signature_path text not null,
  signature_name text not null,
  created_at timestamptz not null default now(),
  unique(staff_id,pay_month)
);
alter table public.payroll_payments enable row level security;
revoke all on public.payroll_payments from public,anon,authenticated;
grant select on public.payroll_payments to authenticated;
drop policy if exists "admin read payroll payments" on public.payroll_payments;
create policy "admin read payroll payments" on public.payroll_payments for select using(public.current_role()='admin');

create or replace function public.admin_record_staff_payroll(
  p_staff_id uuid,
  p_pay_month date,
  p_amount numeric,
  p_payment_method text,
  p_payment_reference text default null,
  p_notes text default null
)
returns public.payroll_payments
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_staff_name text; v_admin_name text; v_currency text; v_signature_path text; v_signature_name text; v_payment public.payroll_payments%rowtype;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'MFA-verified administrator authorization required'; end if;
  if p_staff_id is null or p_pay_month is null or extract(day from p_pay_month)<>1 then raise exception 'Choose a valid payroll month'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Monthly amount must be greater than zero'; end if;
  if p_payment_method not in ('cash','mpesa','bank','other') then raise exception 'Choose a valid payment method'; end if;
  if p_payment_method in ('mpesa','bank') and nullif(trim(p_payment_reference),'') is null then raise exception 'A payment reference is required for M-Pesa or bank payments'; end if;
  select full_name into v_staff_name from public.profiles where id=p_staff_id and role='seller';
  if not found then raise exception 'Choose a valid staff account'; end if;
  select full_name into v_admin_name from public.profiles where id=auth.uid() and role='admin';
  select currency,receipt_signature_path,receipt_signature_name into v_currency,v_signature_path,v_signature_name from public.pharmacy_settings where id=true;
  if nullif(trim(v_signature_path),'') is null or nullif(trim(v_signature_name),'') is null then raise exception 'Save the admin receipt signature and signer name in Pharmacy Settings first'; end if;

  insert into public.payroll_payments(payroll_number,staff_id,staff_name,pay_month,amount,currency_code,payment_method,payment_reference,notes,paid_by,paid_by_name,signature_admin_id,signature_path,signature_name)
  values('PAY-'||to_char(p_pay_month,'YYYYMM')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),p_staff_id,v_staff_name,p_pay_month,p_amount,coalesce(nullif(trim(v_currency),''),'KES'),p_payment_method,nullif(trim(p_payment_reference),''),nullif(trim(p_notes),''),auth.uid(),coalesce(v_admin_name,'Administrator'),auth.uid(),v_signature_path,v_signature_name)
  returning * into v_payment;

  perform public.audit('STAFF_PAYROLL_RECORDED','payroll',v_payment.id::text,jsonb_build_object('staff_id',p_staff_id,'pay_month',p_pay_month,'amount',p_amount,'method',p_payment_method));
  return v_payment;
end;
$$;
revoke all on function public.admin_record_staff_payroll(uuid,date,numeric,text,text,text) from public,anon;
grant execute on function public.admin_record_staff_payroll(uuid,date,numeric,text,text,text) to authenticated;

create or replace function public.audit_receipt_signature_change()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.receipt_signature_path is distinct from old.receipt_signature_path or new.receipt_signature_name is distinct from old.receipt_signature_name then
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'RECEIPT_SIGNATURE_CHANGED','pharmacy_settings','true',jsonb_build_object('signature_path_changed',new.receipt_signature_path is distinct from old.receipt_signature_path,'signer_name_changed',new.receipt_signature_name is distinct from old.receipt_signature_name));
  end if;
  return new;
end;
$$;
revoke all on function public.audit_receipt_signature_change() from public,anon,authenticated;
drop trigger if exists trg_audit_receipt_signature_change on public.pharmacy_settings;
create trigger trg_audit_receipt_signature_change after update on public.pharmacy_settings for each row execute function public.audit_receipt_signature_change();

-- Keep public verification minimal while confirming the recorded authorizer.
create or replace view public.receipt_verification as
select s.sale_number,s.total_amount,s.status,s.created_at,s.authorized_signature_name,
       (s.authorized_signature_path is not null and s.signature_applied_at is not null) as signature_attached
from public.sales s
where s.status in ('paid','refunded','cancelled');
grant select on public.receipt_verification to anon,authenticated;
