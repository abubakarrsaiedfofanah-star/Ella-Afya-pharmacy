-- PayBill statement entries are trusted evidence imported by an authenticated Admin.
-- A sale is completed only when a seller's code and amount match an imported entry.
create table if not exists public.mpesa_statement_entries(
  transaction_code text primary key check(transaction_code ~ '^[A-Z0-9]{6,64}$'),
  amount numeric(12,2) not null check(amount>0),
  transaction_time timestamptz,
  source_name text not null,
  imported_by uuid not null references public.profiles(id),
  imported_at timestamptz not null default now()
);
alter table public.mpesa_statement_entries enable row level security;
revoke all on public.mpesa_statement_entries from public,anon,authenticated;

create or replace function public.submit_manual_mpesa_claim(p_sale_id uuid,p_amount numeric,p_transaction_code text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  s public.sales%rowtype;
  e public.mpesa_statement_entries%rowtype;
  v_code text:=upper(trim(coalesce(p_transaction_code,'')));
  v_id uuid;
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

  select * into e from public.mpesa_statement_entries where transaction_code=v_code for update;
  if found then
    if e.amount=p_amount then
      perform public.verify_manual_mpesa_payment(s.id,p_amount,v_code);
      update public.payments set verified_by=e.imported_by where sale_id=s.id and mpesa_receipt=v_code;
      update public.manual_mpesa_claims set status='approved',reviewed_by=e.imported_by,reviewed_at=now() where id=v_id;
      perform public.audit('MANUAL_MPESA_CLAIM_AUTO_MATCHED','sale',s.id::text,jsonb_build_object('claim_id',v_id,'source_name',e.source_name,'imported_by',e.imported_by));
    else
      update public.manual_mpesa_claims set status='rejected',reviewed_by=e.imported_by,reviewed_at=now() where id=v_id;
      perform public.audit('MANUAL_MPESA_CLAIM_AMOUNT_MISMATCH','sale',s.id::text,jsonb_build_object('claim_id',v_id,'claim_amount',p_amount,'statement_amount',e.amount));
    end if;
  else
    perform public.audit('MANUAL_MPESA_CLAIM_SUBMITTED','sale',s.id::text,jsonb_build_object('claim_id',v_id,'amount',p_amount));
  end if;
  return v_id;
exception when unique_violation then raise exception 'This M-Pesa transaction code has already been submitted or used';
end $$;
revoke all on function public.submit_manual_mpesa_claim(uuid,numeric,text) from public,anon;
grant execute on function public.submit_manual_mpesa_claim(uuid,numeric,text) to authenticated;

create or replace function public.admin_import_mpesa_statement(p_transactions jsonb,p_source_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  item jsonb;
  v_code text;
  v_amount numeric;
  v_time timestamptz;
  v_existing public.mpesa_statement_entries%rowtype;
  v_claim public.manual_mpesa_claims%rowtype;
  v_new integer:=0;
  v_matched integer:=0;
  v_mismatched integer:=0;
  v_unmatched integer:=0;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin access required'; end if;
  if p_source_name is null or length(trim(p_source_name))=0 or length(p_source_name)>255 then raise exception 'Invalid statement file name'; end if;
  if p_transactions is null or jsonb_typeof(p_transactions)<>'array' then raise exception 'Statement transactions must be a JSON array'; end if;
  if jsonb_array_length(p_transactions)=0 or jsonb_array_length(p_transactions)>10000 then
    raise exception 'Statement must contain between 1 and 10000 transaction rows';
  end if;

  for item in select value from jsonb_array_elements(p_transactions) loop
    v_code:=upper(trim(coalesce(item->>'transaction_code','')));
    if length(v_code)<6 or length(v_code)>64 or v_code !~ '^[A-Z0-9]+$' then raise exception 'Statement contains an invalid transaction code'; end if;
    begin
      v_amount:=nullif(item->>'amount','')::numeric;
      v_time:=nullif(item->>'transaction_time','')::timestamptz;
    exception when others then raise exception 'Statement contains an invalid amount or transaction date for code %',v_code; end;
    if v_amount is null or v_amount<=0 then raise exception 'Statement amount must be greater than zero for code %',v_code; end if;

    insert into public.mpesa_statement_entries(transaction_code,amount,transaction_time,source_name,imported_by)
    values(v_code,v_amount,v_time,trim(p_source_name),auth.uid()) on conflict(transaction_code) do nothing;
    if found then v_new:=v_new+1; end if;
    select * into v_existing from public.mpesa_statement_entries where transaction_code=v_code for update;
    if v_existing.amount<>v_amount then raise exception 'Transaction code % already exists with a different amount',v_code; end if;
  end loop;

  update public.manual_mpesa_claims c set status='rejected',reviewed_by=auth.uid(),reviewed_at=now()
  from public.sales s where s.id=c.sale_id and c.status='pending' and s.status<>'pending_payment';

  for v_claim in
    select c.* from public.manual_mpesa_claims c
    join public.mpesa_statement_entries e on e.transaction_code=c.transaction_code
    join public.sales s on s.id=c.sale_id and s.status='pending_payment'
    where c.status='pending' order by c.created_at for update of c
  loop
    select * into v_existing from public.mpesa_statement_entries where transaction_code=v_claim.transaction_code;
    if v_existing.amount=v_claim.amount then
      perform public.verify_manual_mpesa_payment(v_claim.sale_id,v_claim.amount,v_claim.transaction_code);
      update public.payments set verified_by=auth.uid() where sale_id=v_claim.sale_id and mpesa_receipt=v_claim.transaction_code;
      update public.manual_mpesa_claims set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=v_claim.id;
      perform public.audit('MANUAL_MPESA_CLAIM_AUTO_MATCHED','sale',v_claim.sale_id::text,jsonb_build_object('claim_id',v_claim.id,'source_name',p_source_name));
      v_matched:=v_matched+1;
    else
      update public.manual_mpesa_claims set status='rejected',reviewed_by=auth.uid(),reviewed_at=now() where id=v_claim.id;
      perform public.audit('MANUAL_MPESA_CLAIM_AMOUNT_MISMATCH','sale',v_claim.sale_id::text,jsonb_build_object('claim_id',v_claim.id,'claim_amount',v_claim.amount,'statement_amount',v_existing.amount));
      v_mismatched:=v_mismatched+1;
    end if;
  end loop;

  select count(*)::integer into v_unmatched from public.mpesa_statement_entries e
  where e.source_name=trim(p_source_name) and not exists(select 1 from public.manual_mpesa_claims c where c.transaction_code=e.transaction_code);
  perform public.audit('MPESA_STATEMENT_IMPORTED','payment_statement',p_source_name,jsonb_build_object('new_transactions',v_new,'matched_claims',v_matched,'amount_mismatches',v_mismatched,'unmatched_transactions',v_unmatched));
  return jsonb_build_object('new_transactions',v_new,'matched_claims',v_matched,'amount_mismatches',v_mismatched,'unmatched_transactions',v_unmatched);
end $$;
revoke all on function public.admin_import_mpesa_statement(jsonb,text) from public,anon;
grant execute on function public.admin_import_mpesa_statement(jsonb,text) to authenticated;

notify pgrst,'reload schema';
