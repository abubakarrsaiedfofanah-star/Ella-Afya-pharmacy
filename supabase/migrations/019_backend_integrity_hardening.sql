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