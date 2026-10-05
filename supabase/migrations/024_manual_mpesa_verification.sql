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
