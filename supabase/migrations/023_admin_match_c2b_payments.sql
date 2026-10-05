-- Admins manually assign fixed-account PayBill payments to the correct sale.
create or replace function public.admin_match_mpesa_c2b(p_trans_id text,p_sale_number text)
returns numeric
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  t public.mpesa_c2b_transactions%rowtype;
  s public.sales%rowtype;
  r record;
  b public.batches%rowtype;
  v_paid numeric(12,2);
  v_remaining numeric(12,2);
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into t from public.mpesa_c2b_transactions where trans_id=trim(p_trans_id) for update;
  if not found or t.status<>'unmatched' then raise exception 'PayBill transaction is unavailable or already matched'; end if;
  select * into s from public.sales where sale_number=trim(p_sale_number) for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale not found or is not awaiting payment'; end if;

  select coalesce(sum(amount),0) into v_paid from public.payments where sale_id=s.id and status='paid';
  if v_paid+t.amount>s.total_amount+0.01 then raise exception 'Payment exceeds the sale balance'; end if;

  insert into public.payments(sale_id,method,amount,provider_reference,mpesa_receipt,phone_number,transaction_time,status,confirmed_at,callback_payload)
  values(s.id,'mpesa',t.amount,t.trans_id,t.trans_id,t.phone_number,t.transaction_time,'paid',now(),t.raw_payload);
  v_remaining:=greatest(s.total_amount-(v_paid+t.amount),0);

  if v_remaining<=0.01 then
    for r in select * from public.sale_items where sale_id=s.id for update loop
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
      values(r.medicine_id,b.id,'sale',-r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('mpesa_receipt',t.trans_id,'source','manual_c2b_match'));
      if r.prescription_item_id is not null then
        update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id;
      end if;
    end loop;
    update public.sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object('amount',v_paid+t.amount,'source','mpesa_c2b'));
  end if;

  update public.mpesa_c2b_transactions set status='matched',matched_sale_id=s.id,matched_by=auth.uid(),matched_at=now() where trans_id=t.trans_id;
  perform public.audit('MPESA_C2B_MANUALLY_MATCHED','sale',s.id::text,jsonb_build_object('receipt',t.trans_id,'amount',t.amount,'remaining',v_remaining));
  return v_remaining;
end;
$$;

revoke all on function public.admin_match_mpesa_c2b(text,text) from public,anon;
grant execute on function public.admin_match_mpesa_c2b(text,text) to authenticated;
