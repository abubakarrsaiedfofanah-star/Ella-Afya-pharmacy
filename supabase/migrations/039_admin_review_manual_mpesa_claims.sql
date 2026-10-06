-- Manual M-Pesa codes are seller-submitted claims, not provider-verified payments.
-- Keep the sale pending until an Admin checks the code against the PayBill statement.
create table if not exists public.manual_mpesa_claims(
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete restrict,
  submitted_by uuid not null references public.profiles(id),
  amount numeric(12,2) not null check(amount>0),
  transaction_code text not null check(transaction_code ~ '^[A-Z0-9]{6,64}$'),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(transaction_code)
);
create index if not exists manual_mpesa_claims_pending_idx
  on public.manual_mpesa_claims(created_at desc) where status='pending';
create unique index if not exists manual_mpesa_one_pending_claim_per_sale_idx
  on public.manual_mpesa_claims(sale_id) where status='pending';
alter table public.manual_mpesa_claims enable row level security;
revoke all on public.manual_mpesa_claims from public,anon,authenticated;

create or replace function public.submit_manual_mpesa_claim(p_sale_id uuid,p_amount numeric,p_transaction_code text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.sales%rowtype; v_code text:=upper(trim(coalesce(p_transaction_code,''))); v_id uuid;
begin
  if auth.uid() is null or public.current_role()<>'seller' then raise exception 'Active Sales authorization required'; end if;
  select * into s from public.sales where id=p_sale_id for update;
  if not found or s.status<>'pending_payment' or s.seller_id<>auth.uid() then raise exception 'Sale is not awaiting payment'; end if;
  if not exists(select 1 from public.seller_permissions where user_id=auth.uid() and can_sell=true) then raise exception 'Seller is not permitted to process sales'; end if;
  if p_amount is null or p_amount<>s.total_amount then raise exception 'M-Pesa amount must exactly match the sale total'; end if;
  if length(v_code)<6 or length(v_code)>64 or v_code !~ '^[A-Z0-9]+$' then raise exception 'Enter a valid M-Pesa transaction code'; end if;
  if exists(select 1 from public.payments where upper(mpesa_receipt)=v_code) then raise exception 'This M-Pesa transaction code has already been used'; end if;
  insert into public.manual_mpesa_claims(sale_id,submitted_by,amount,transaction_code)
  values(s.id,auth.uid(),p_amount,v_code) returning id into v_id;
  perform public.audit('MANUAL_MPESA_CLAIM_SUBMITTED','sale',s.id::text,jsonb_build_object('claim_id',v_id,'amount',p_amount));
  return v_id;
exception when unique_violation then raise exception 'This M-Pesa transaction code has already been submitted';
end $$;
revoke all on function public.submit_manual_mpesa_claim(uuid,numeric,text) from public,anon;
grant execute on function public.submit_manual_mpesa_claim(uuid,numeric,text) to authenticated;

create or replace function public.admin_manual_mpesa_claims()
returns table(claim_id uuid,sale_id uuid,sale_number text,seller_name text,amount numeric,transaction_code text,submitted_at timestamptz)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin access required'; end if;
  return query select c.id,c.sale_id,s.sale_number,case when c.submitted_by is null then 'Safaricom (automatic)' else coalesce(p.full_name,'Sales staff') end,c.amount,c.transaction_code,c.created_at
    from public.manual_mpesa_claims c join public.sales s on s.id=c.sale_id
    left join public.profiles p on p.id=c.submitted_by where c.status='pending'
    order by c.created_at asc limit 200;
end $$;
revoke all on function public.admin_manual_mpesa_claims() from public,anon;
grant execute on function public.admin_manual_mpesa_claims() to authenticated;

create or replace function public.admin_review_manual_mpesa_claim(p_claim_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare c public.manual_mpesa_claims%rowtype;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin access required'; end if;
  select * into c from public.manual_mpesa_claims where id=p_claim_id for update;
  if not found or c.status<>'pending' then raise exception 'Claim is no longer awaiting review'; end if;
  if p_approve then
    perform public.verify_manual_mpesa_payment(c.sale_id,c.amount,c.transaction_code);
  end if;
  update public.manual_mpesa_claims set status=case when p_approve then 'approved' else 'rejected' end,
    reviewed_by=auth.uid(),reviewed_at=now() where id=c.id;
  perform public.audit(case when p_approve then 'MANUAL_MPESA_CLAIM_APPROVED' else 'MANUAL_MPESA_CLAIM_REJECTED' end,
    'sale',c.sale_id::text,jsonb_build_object('claim_id',c.id,'amount',c.amount));
end $$;
revoke all on function public.admin_review_manual_mpesa_claim(uuid,boolean) from public,anon;
grant execute on function public.admin_review_manual_mpesa_claim(uuid,boolean) to authenticated;

-- Only the Admin review RPC may call the legacy verifier. Nested calls made by
-- the security-definer review function execute as its owner.
revoke all on function public.verify_manual_mpesa_payment(uuid,numeric,text) from public,anon,authenticated;

notify pgrst,'reload schema';
