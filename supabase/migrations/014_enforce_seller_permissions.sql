-- Enforce seller permission controls inside privileged transaction functions.

create or replace function public.create_sale(p_items jsonb,p_prescription_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid:=gen_random_uuid(); v_number text; v_total numeric(12,2):=0; item jsonb; v_price numeric; v_qty int; v_med uuid; v_stock int; v_required boolean; v_rem int; v_pi uuid; v_batch_id uuid; v_can_sell boolean:=true; v_max numeric;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' then
    select can_sell,max_transaction_amount into v_can_sell,v_max from public.seller_permissions where user_id=auth.uid();
    if coalesce(v_can_sell,false)=false then raise exception 'Your seller account is not permitted to process sales'; end if;
  end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Sale requires items'; end if;
  if p_prescription_id is not null and not exists(select 1 from public.prescriptions where id=p_prescription_id and status in ('verified','dispensing','dispensed')) then raise exception 'Prescription is not verified'; end if;
  v_number:='SALE-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_sale_id::text,'-',''),1,6);
  insert into public.sales(id,sale_number,seller_id,prescription_id,total_amount,status) values(v_sale_id,v_number,auth.uid(),p_prescription_id,0,'pending_payment');
  for item in select * from jsonb_array_elements(p_items) loop
    v_med:=(item->>'medicine_id')::uuid; v_qty:=(item->>'quantity')::int; v_batch_id:=nullif(item->>'batch_id','')::uuid;
    if v_qty<=0 then raise exception 'Invalid quantity'; end if;
    select selling_price,prescription_required into v_price,v_required from public.medicines where id=v_med and active=true;
    if v_price is null then raise exception 'Medicine unavailable'; end if;
    if v_required and p_prescription_id is null then raise exception 'Prescription required for this medicine'; end if;
    if p_prescription_id is not null then
      select id,quantity_prescribed-quantity_dispensed into v_pi,v_rem from public.prescription_items where prescription_id=p_prescription_id and medicine_id=v_med for update;
      if v_pi is null or v_rem<v_qty then raise exception 'Sale quantity exceeds prescription balance'; end if;
    end if;
    select quantity into v_stock from public.inventory where medicine_id=v_med for update;
    if coalesce(v_stock,0)<v_qty then raise exception 'Insufficient stock for medicine %',v_med; end if;
    if v_batch_id is not null and not exists(select 1 from public.batches where id=v_batch_id and medicine_id=v_med and expiry_date>=current_date and quantity>=v_qty) then raise exception 'Selected batch is invalid, expired or has insufficient stock'; end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price,prescription_item_id,batch_id) values(v_sale_id,v_med,v_qty,v_price,v_pi,v_batch_id);
    v_total:=v_total+v_qty*v_price;
  end loop;
  if public.current_role()='seller' and v_max is not null and v_total>v_max then raise exception 'Transaction exceeds your authorized seller limit'; end if;
  update public.sales set total_amount=v_total where id=v_sale_id;
  perform public.audit('SALE_CREATED','sale',v_sale_id::text,jsonb_build_object('total',v_total,'prescription_id',p_prescription_id));
  return v_sale_id;
exception when others then
  delete from public.sale_items where sale_id=v_sale_id;
  delete from public.sales where id=v_sale_id;
  raise;
end $$;

create or replace function public.request_action(p_action_type text,p_target_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_allowed boolean:=true;
begin
  if public.current_role()<>'seller' then raise exception 'Only seller requests use this workflow'; end if;
  select case
    when p_action_type='refund' then can_request_refund
    when p_action_type='cancel_sale' then can_request_cancellation
    when p_action_type='stock_adjustment' then can_request_stock_adjustment
    else true end into v_allowed from public.seller_permissions where user_id=auth.uid();
  if not coalesce(v_allowed,false) then raise exception 'Your seller account is not permitted to request this action'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'A reason is required'; end if;
  insert into public.approvals(action_type,target_id,requested_by,reason) values(p_action_type,p_target_id,trim(p_reason)) returning id into v_id;
  perform public.audit('APPROVAL_REQUESTED',p_action_type,v_id::text,jsonb_build_object('target_id',p_target_id,'reason',trim(p_reason)));
  return v_id;
end $$;

revoke all on function public.create_sale(jsonb,uuid) from public;
revoke all on function public.request_action(text,uuid,text) from public;
grant execute on function public.create_sale(jsonb,uuid) to authenticated;
grant execute on function public.request_action(text,uuid,text) to authenticated;

create or replace function public.create_prescription(p_patient_name text,p_prescriber_name text,p_prescription_date date,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_number text; i jsonb; v_med uuid; v_qty int; v_allowed boolean:=true;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' then select can_process_prescriptions into v_allowed from public.seller_permissions where user_id=auth.uid(); if not coalesce(v_allowed,false) then raise exception 'Your seller account is not permitted to process prescriptions'; end if; end if;
  if nullif(trim(p_patient_name),'') is null then raise exception 'Patient name is required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Prescription requires at least one medicine'; end if;
  v_number:='RX-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_id::text,'-',''),1,6);
  insert into public.prescriptions(id,prescription_number,patient_name,prescriber_name,prescription_date,status,created_by)
  values(v_id,v_number,trim(p_patient_name),nullif(trim(p_prescriber_name),''),coalesce(p_prescription_date,current_date),'received',auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity_prescribed')::int;
    if v_qty is null or v_qty<=0 then raise exception 'Invalid prescribed quantity'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.prescription_items(prescription_id,medicine_id,dosage_instructions,quantity_prescribed)
    values(v_id,v_med,nullif(i->>'dosage_instructions',''),v_qty);
  end loop;
  perform public.audit('PRESCRIPTION_CREATED','prescription',v_id::text,jsonb_build_object('prescription_number',v_number));
  return v_id;
exception when others then
  delete from public.prescription_items where prescription_id=v_id;
  delete from public.prescriptions where id=v_id;
  raise;
end $$;
revoke all on function public.create_prescription(text,text,date,jsonb) from public;
grant execute on function public.create_prescription(text,text,date,jsonb) to authenticated;
