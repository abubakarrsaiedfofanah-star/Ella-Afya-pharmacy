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
