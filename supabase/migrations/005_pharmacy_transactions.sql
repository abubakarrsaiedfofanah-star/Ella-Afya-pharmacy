-- Advanced pharmacy transaction layer. Run after 004_receipts_and_security.sql.

alter table public.sale_items add column if not exists batch_id uuid references public.batches(id);
alter table public.sale_items add column if not exists prescription_item_id uuid references public.prescription_items(id);

alter table public.payments add column if not exists merchant_request_id text;
alter table public.payments add column if not exists checkout_request_id text;
alter table public.payments add column if not exists mpesa_receipt text;
alter table public.payments add column if not exists phone_number text;
alter table public.payments add column if not exists transaction_time timestamptz;
alter table public.payments add column if not exists callback_payload jsonb;
create unique index if not exists uq_payments_checkout on public.payments(checkout_request_id) where checkout_request_id is not null;
create unique index if not exists uq_payments_mpesa_receipt on public.payments(mpesa_receipt) where mpesa_receipt is not null;

create table if not exists public.stock_receipts(
 id uuid primary key default gen_random_uuid(),
 receipt_number text unique not null,
 supplier_name text,
 invoice_number text,
 received_by uuid not null references public.profiles(id),
 total_cost numeric(12,2) not null default 0 check(total_cost>=0),
 status text not null default 'received' check(status in ('received','voided')),
 received_at timestamptz not null default now()
);
create table if not exists public.stock_receipt_items(
 id uuid primary key default gen_random_uuid(),
 receipt_id uuid not null references public.stock_receipts(id) on delete restrict,
 medicine_id uuid not null references public.medicines(id) on delete restrict,
 batch_id uuid not null references public.batches(id) on delete restrict,
 quantity integer not null check(quantity>0),
 unit_cost numeric(12,2) not null check(unit_cost>=0),
 total_cost numeric(12,2) generated always as (quantity*unit_cost) stored
);
create table if not exists public.stock_movements(
 id bigint generated always as identity primary key,
 medicine_id uuid not null references public.medicines(id),
 batch_id uuid references public.batches(id),
 movement_type text not null check(movement_type in ('receive','sale','refund','adjustment','expiry','void_receive')),
 quantity integer not null,
 reference_type text,
 reference_id uuid,
 actor_id uuid references public.profiles(id),
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists idx_stock_movements_created on public.stock_movements(created_at);
create index if not exists idx_stock_movements_medicine on public.stock_movements(medicine_id,created_at);

create table if not exists public.mpesa_callbacks(
 id bigint generated always as identity primary key,
 checkout_request_id text,
 merchant_request_id text,
 result_code integer,
 result_description text,
 raw_payload jsonb not null,
 received_at timestamptz not null default now()
);
create unique index if not exists uq_mpesa_callback_checkout on public.mpesa_callbacks(checkout_request_id);

alter table public.stock_receipts enable row level security;
alter table public.stock_receipt_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.mpesa_callbacks enable row level security;

create policy "admin stock receipts" on public.stock_receipts for select using(public.current_role()='admin');
create policy "admin stock receipt items" on public.stock_receipt_items for select using(public.current_role()='admin');
create policy "admin stock movements" on public.stock_movements for select using(public.current_role()='admin');
create policy "admin mpesa callbacks" on public.mpesa_callbacks for select using(public.current_role()='admin');

create or replace function public.create_prescription(p_patient_name text,p_prescriber_name text,p_prescription_date date,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_number text; i jsonb; v_med uuid; v_qty int;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
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
end $$;

create or replace function public.review_prescription(p_prescription_id uuid,p_approve boolean,p_reason text default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_status public.prescription_status;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select status into v_status from public.prescriptions where id=p_prescription_id for update;
  if not found then raise exception 'Prescription not found'; end if;
  update public.prescriptions set status=case when p_approve then 'verified' else 'rejected' end,verified_by=auth.uid(),updated_at=now() where id=p_prescription_id;
  perform public.audit(case when p_approve then 'PRESCRIPTION_VERIFIED' else 'PRESCRIPTION_REJECTED' end,'prescription',p_prescription_id::text,jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.dispense_prescription(p_prescription_id uuid,p_items jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare i jsonb; v_item public.prescription_items%rowtype; v_batch public.batches%rowtype; v_med uuid; v_qty int; v_batch_id uuid; v_remaining int; v_status public.prescription_status;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required for standalone dispensing'; end if;
  select status into v_status from public.prescriptions where id=p_prescription_id for update;
  if v_status not in ('verified','dispensing') then raise exception 'Prescription must be verified before dispensing'; end if;
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity')::int; v_batch_id:=nullif(i->>'batch_id','')::uuid;
    if v_qty is null or v_qty<=0 then raise exception 'Invalid dispensing quantity'; end if;
    select * into v_item from public.prescription_items where prescription_id=p_prescription_id and medicine_id=v_med for update;
    if not found then raise exception 'Medicine is not on this prescription'; end if;
    v_remaining:=v_item.quantity_prescribed-v_item.quantity_dispensed;
    if v_qty>v_remaining then raise exception 'Dispensing quantity exceeds prescribed quantity'; end if;
    if v_batch_id is not null then
      select * into v_batch from public.batches where id=v_batch_id and medicine_id=v_med for update;
      if not found then raise exception 'Selected batch is invalid'; end if;
      if v_batch.expiry_date<current_date then raise exception 'Selected batch has expired'; end if;
      if v_batch.quantity<v_qty then raise exception 'Selected batch has insufficient stock'; end if;
      update public.batches set quantity=quantity-v_qty where id=v_batch.id;
    else
      select * into v_batch from public.batches where medicine_id=v_med and expiry_date>=current_date and quantity>0 order by expiry_date,received_at limit 1 for update;
      if not found or v_batch.quantity<v_qty then raise exception 'No suitable unexpired batch has enough stock'; end if;
      update public.batches set quantity=quantity-v_qty where id=v_batch.id;
    end if;
    update public.inventory set quantity=quantity-v_qty where medicine_id=v_med and quantity>=v_qty;
    if not found then raise exception 'Inventory mismatch'; end if;
    update public.prescription_items set quantity_dispensed=quantity_dispensed+v_qty where id=v_item.id;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(v_med,v_batch.id,'sale',-v_qty,'prescription',p_prescription_id,auth.uid(),jsonb_build_object('dispensed',true));
  end loop;
  update public.prescriptions set status=case when not exists(select 1 from public.prescription_items where prescription_id=p_prescription_id and quantity_dispensed<quantity_prescribed) then 'completed' else 'dispensed' end,updated_at=now() where id=p_prescription_id;
  perform public.audit('PRESCRIPTION_DISPENSED','prescription',p_prescription_id::text,jsonb_build_object('items',p_items));
end $$;

create or replace function public.receive_stock(p_supplier_name text,p_invoice_number text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_receipt uuid:=gen_random_uuid(); v_number text; i jsonb; v_med uuid; v_qty int; v_cost numeric; v_batch uuid; v_total numeric(12,2):=0;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Receiving requires items'; end if;
  v_number:='GRN-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_receipt::text,'-',''),1,6);
  insert into public.stock_receipts(id,receipt_number,supplier_name,invoice_number,received_by) values(v_receipt,v_number,nullif(trim(p_supplier_name),''),nullif(trim(p_invoice_number),''),auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity')::int; v_cost:=(i->>'unit_cost')::numeric;
    if v_qty is null or v_qty<=0 or v_cost is null or v_cost<0 then raise exception 'Invalid receiving item'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.batches(medicine_id,batch_number,expiry_date,quantity,supplier_name)
    values(v_med,trim(i->>'batch_number'),(i->>'expiry_date')::date,v_qty,nullif(trim(p_supplier_name),''))
    on conflict(medicine_id,batch_number) do update set quantity=public.batches.quantity+excluded.quantity,expiry_date=excluded.expiry_date,supplier_name=excluded.supplier_name
    returning id into v_batch;
    insert into public.stock_receipt_items(receipt_id,medicine_id,batch_id,quantity,unit_cost) values(v_receipt,v_med,v_batch,v_qty,v_cost);
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(v_med,v_batch,'receive',v_qty,'stock_receipt',v_receipt,auth.uid(),jsonb_build_object('batch_number',i->>'batch_number','expiry_date',i->>'expiry_date'));
    insert into public.inventory(medicine_id,quantity) values(v_med,v_qty) on conflict(medicine_id) do update set quantity=public.inventory.quantity+excluded.quantity;
    v_total:=v_total+(v_qty*v_cost);
  end loop;
  update public.stock_receipts set total_cost=v_total where id=v_receipt;
  perform public.audit('STOCK_RECEIVED','stock_receipt',v_receipt::text,jsonb_build_object('total_cost',v_total,'receipt_number',v_number));
  return v_receipt;
end $$;

create or replace function public.prepare_mpesa_payment(p_sale_id uuid,p_phone text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype; v_id uuid;
begin
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Phone number is required'; end if;
  insert into public.payments(sale_id,method,amount,phone_number,status) values(p_sale_id,'mpesa',v_sale.total_amount,trim(p_phone),'pending') returning id into v_id;
  perform public.audit('MPESA_PAYMENT_PREPARED','payment',v_id::text,jsonb_build_object('sale_id',p_sale_id,'amount',v_sale.total_amount));
  return v_id;
end $$;

create or replace function public.apply_mpesa_callback(p_checkout_request_id text,p_merchant_request_id text,p_result_code integer,p_result_description text,p_receipt text,p_amount numeric,p_phone text,p_transaction_time timestamptz,p_payload jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare p public.payments%rowtype; s public.sales%rowtype; r record; v_batch_id uuid;
begin
  if p_checkout_request_id is null then raise exception 'CheckoutRequestID required'; end if;
  insert into public.mpesa_callbacks(checkout_request_id,merchant_request_id,result_code,result_description,raw_payload)
  values(p_checkout_request_id,p_merchant_request_id,p_result_code,p_result_description,p_payload)
  on conflict(checkout_request_id) do nothing;
  select * into p from public.payments where checkout_request_id=p_checkout_request_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if p.status='paid' then return; end if;
  select * into s from public.sales where id=p.sale_id for update;
  if p_result_code<>0 then update public.payments set status='failed',callback_payload=p_payload where id=p.id; return; end if;
  if abs(p_amount-p.amount)>0.01 then raise exception 'M-Pesa amount does not match sale'; end if;
  if p.phone_number is not null and p_phone is not null and regexp_replace(p.phone_number,'[^0-9]','','g')<>regexp_replace(p_phone,'[^0-9]','','g') then raise exception 'M-Pesa phone does not match payment request'; end if;
  if s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  for r in select * from public.sale_items where sale_id=s.id for update loop
    v_batch_id:=r.batch_id;
    if v_batch_id is not null then
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id and expiry_date>=current_date and quantity>=r.quantity;
      if not found then raise exception 'Selected batch unavailable while completing M-Pesa payment'; end if;
    else
      select b.id into v_batch_id from public.batches b where b.medicine_id=r.medicine_id and b.expiry_date>=current_date and b.quantity>=r.quantity order by b.expiry_date,b.received_at limit 1 for update;
      if v_batch_id is null then raise exception 'No suitable batch available while completing M-Pesa payment'; end if;
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id;
      update public.sale_items set batch_id=v_batch_id where id=r.id;
    end if;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock unavailable while completing M-Pesa payment'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,v_batch_id,'sale',-r.quantity,'sale',s.id,null,jsonb_build_object('mpesa_receipt',p_receipt));
  end loop;
  update public.payments set status='paid',confirmed_at=now(),mpesa_receipt=p_receipt,merchant_request_id=p_merchant_request_id,phone_number=coalesce(p_phone,phone_number),transaction_time=p_transaction_time,callback_payload=p_payload where id=p.id;
  update public.sales set status='paid' where id=s.id;
end $$;

create or replace function public.financial_report(p_from date,p_to date)
returns table(report_date date, sales_count bigint,gross_sales numeric,total_paid numeric,cash_paid numeric,mpesa_paid numeric,other_paid numeric,refunded numeric)
language sql stable security definer set search_path=public as $$
  with days as (select d::date report_date from generate_series(p_from::timestamptz,p_to::timestamptz,interval '1 day') d),
  s as (select created_at::date report_date,count(*) filter(where status='paid') sales_count,coalesce(sum(total_amount) filter(where status='paid'),0) gross_sales from public.sales group by created_at::date),
  p as (select created_at::date report_date,coalesce(sum(amount) filter(where status='paid'),0) total_paid,coalesce(sum(amount) filter(where status='paid' and method='cash'),0) cash_paid,coalesce(sum(amount) filter(where status='paid' and method='mpesa'),0) mpesa_paid,coalesce(sum(amount) filter(where status='paid' and method='other'),0) other_paid,coalesce(sum(amount) filter(where status='refunded'),0) refunded from public.payments group by created_at::date)
  select d.report_date,coalesce(s.sales_count,0),coalesce(s.gross_sales,0),coalesce(p.total_paid,0),coalesce(p.cash_paid,0),coalesce(p.mpesa_paid,0),coalesce(p.other_paid,0),coalesce(p.refunded,0)
  from days d left join s using(report_date) left join p using(report_date)
  where public.current_role()='admin' order by d.report_date;
$$;

-- Replace the original sale creation/payment confirmation with batch-aware, prescription-aware logic.
create or replace function public.create_sale(p_items jsonb,p_prescription_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid:=gen_random_uuid(); v_number text; v_total numeric(12,2):=0; item jsonb; v_price numeric; v_qty int; v_med uuid; v_stock int; v_required boolean; v_rem int; v_pi uuid; v_batch_id uuid;
begin
  if public.current_role() not in ('admin','seller') then raise exception 'Unauthorized'; end if;
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
    if v_batch_id is not null then
      if not exists(select 1 from public.batches where id=v_batch_id and medicine_id=v_med and expiry_date>=current_date) then raise exception 'Selected batch is invalid or expired'; end if;
    end if;
    insert into public.sale_items(sale_id,medicine_id,quantity,unit_price,prescription_item_id,batch_id) values(v_sale_id,v_med,v_qty,v_price,v_pi,v_batch_id);
    v_total:=v_total+v_qty*v_price;
  end loop;
  update public.sales set total_amount=v_total where id=v_sale_id;
  perform public.audit('SALE_CREATED','sale',v_sale_id::text,jsonb_build_object('total',v_total,'prescription_id',p_prescription_id));
  return v_sale_id;
end $$;

create or replace function public.confirm_sale_payment(p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype; r record; b public.batches%rowtype; v_remaining int;
begin
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if public.current_role()='seller' and v_sale.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if v_sale.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if p_amount<>v_sale.total_amount then raise exception 'Payment amount does not match sale total'; end if;
  if p_method not in ('mpesa','cash','other') then raise exception 'Invalid payment method'; end if;
  if p_method='mpesa' then raise exception 'Use the secure M-Pesa payment flow'; end if;
  for r in select * from public.sale_items where sale_id=p_sale_id for update loop
    if r.batch_id is not null then
      select * into b from public.batches where id=r.batch_id and medicine_id=r.medicine_id for update;
      if not found or b.expiry_date<current_date or b.quantity<r.quantity then raise exception 'Selected batch unavailable or expired'; end if;
      update public.batches set quantity=quantity-r.quantity where id=b.id;
    else
      select * into b from public.batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>0 order by expiry_date,received_at limit 1 for update;
      if not found or b.quantity<r.quantity then raise exception 'No suitable unexpired batch has enough stock'; end if;
      update public.batches set quantity=quantity-r.quantity where id=b.id;
      update public.sale_items set batch_id=b.id where id=r.id;
    end if;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock changed; payment not completed'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(r.medicine_id,b.id,'sale',-r.quantity,'sale',p_sale_id,auth.uid(),'{}');
    if r.prescription_item_id is not null then update public.prescription_items set quantity_dispensed=quantity_dispensed+r.quantity where id=r.prescription_item_id; end if;
  end loop;
  insert into public.payments(sale_id,method,amount,provider_reference,status,confirmed_at) values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  update public.sales set status='paid' where id=p_sale_id;
  perform public.audit('PAYMENT_CONFIRMED','sale',p_sale_id::text,jsonb_build_object('method',p_method,'amount',p_amount,'reference',p_reference));
  return p_sale_id;
end $$;

-- Rebuild refund approval so approved refunds restore the exact sold batches.
create or replace function public.decide_approval(p_approval_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare a public.approvals%rowtype; s public.sales%rowtype; r record;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into a from public.approvals where id=p_approval_id for update;
  if not found or a.status<>'pending' then raise exception 'Approval unavailable'; end if;
  if p_approve and a.action_type='refund' then
    select * into s from public.sales where id=a.target_id for update;
    if s.status<>'paid' then raise exception 'Sale is not refundable'; end if;
    for r in select * from public.sale_items where sale_id=s.id loop
      if r.batch_id is not null then update public.batches set quantity=quantity+r.quantity where id=r.batch_id;
      else update public.inventory set quantity=quantity+r.quantity where medicine_id=r.medicine_id; end if;
      update public.inventory set quantity=quantity+r.quantity where medicine_id=r.medicine_id and r.batch_id is not null;
      insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(r.medicine_id,r.batch_id,'refund',r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('approval_id',a.id));
    end loop;
    update public.sales set status='refunded' where id=s.id;
    update public.payments set status='refunded' where sale_id=s.id and status='paid';
  elsif p_approve and a.action_type='cancel_sale' then
    update public.sales set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid() where id=a.target_id and status='pending_payment';
  end if;
  update public.approvals set approved_by=auth.uid(),status=case when p_approve then 'approved' else 'rejected' end,decided_at=now() where id=p_approval_id;
  perform public.audit(case when p_approve then 'APPROVAL_APPROVED' else 'APPROVAL_REJECTED' end,a.action_type,a.target_id::text,jsonb_build_object('approval_id',p_approval_id));
end $$;

revoke all on function public.create_prescription(text,text,date,jsonb) from public;
revoke all on function public.review_prescription(uuid,boolean,text) from public;
revoke all on function public.dispense_prescription(uuid,jsonb) from public;
revoke all on function public.receive_stock(text,text,jsonb) from public;
revoke all on function public.prepare_mpesa_payment(uuid,text) from public;
revoke all on function public.apply_mpesa_callback(text,text,integer,text,text,numeric,text,timestamptz,jsonb) from public;
revoke all on function public.financial_report(date,date) from public;
revoke all on function public.create_sale(jsonb,uuid) from public;
revoke all on function public.confirm_sale_payment(uuid,text,numeric,text) from public;
revoke all on function public.decide_approval(uuid,boolean) from public;
grant execute on function public.create_prescription(text,text,date,jsonb) to authenticated;
grant execute on function public.review_prescription(uuid,boolean,text) to authenticated;
grant execute on function public.dispense_prescription(uuid,jsonb) to authenticated;
grant execute on function public.receive_stock(text,text,jsonb) to authenticated;
grant execute on function public.prepare_mpesa_payment(uuid,text) to authenticated;
grant execute on function public.apply_mpesa_callback(text,text,integer,text,text,numeric,text,timestamptz,jsonb) to service_role;
grant execute on function public.financial_report(date,date) to authenticated;
grant execute on function public.create_sale(jsonb,uuid) to authenticated;
grant execute on function public.confirm_sale_payment(uuid,text,numeric,text) to authenticated;
grant execute on function public.decide_approval(uuid,boolean) to authenticated;

create or replace function public.apply_mpesa_c2b_callback(p_receipt text,p_sale_number text,p_amount numeric,p_phone text,p_transaction_time timestamptz,p_payload jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare s public.sales%rowtype; r record; v_batch_id uuid;
begin
  if p_receipt is null then raise exception 'M-Pesa receipt is required'; end if;
  if exists(select 1 from public.payments where mpesa_receipt=p_receipt and status='paid') then return; end if;
  select * into s from public.sales where sale_number=trim(p_sale_number) for update;
  if not found then raise exception 'Sale reference not found'; end if;
  if s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if abs(p_amount-s.total_amount)>0.01 then raise exception 'M-Pesa amount does not match sale'; end if;
  for r in select * from public.sale_items where sale_id=s.id for update loop
    v_batch_id:=r.batch_id;
    if v_batch_id is not null then
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id and expiry_date>=current_date and quantity>=r.quantity;
      if not found then raise exception 'Selected batch unavailable'; end if;
    else
      select b.id into v_batch_id from public.batches b where b.medicine_id=r.medicine_id and b.expiry_date>=current_date and b.quantity>=r.quantity order by b.expiry_date,b.received_at limit 1 for update;
      if v_batch_id is null then raise exception 'No suitable batch available'; end if;
      update public.batches set quantity=quantity-r.quantity where id=v_batch_id;
      update public.sale_items set batch_id=v_batch_id where id=r.id;
    end if;
    update public.inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
    if not found then raise exception 'Stock unavailable'; end if;
    insert into public.stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details)
    values(r.medicine_id,v_batch_id,'sale',-r.quantity,'sale',s.id,null,jsonb_build_object('mpesa_receipt',p_receipt,'source','C2B'));
  end loop;
  insert into public.payments(sale_id,method,amount,provider_reference,mpesa_receipt,phone_number,transaction_time,status,confirmed_at,callback_payload)
  values(s.id,'mpesa',p_amount,p_receipt,p_receipt,p_phone,p_transaction_time,'paid',now(),p_payload);
  update public.sales set status='paid' where id=s.id;
end $$;
revoke all on function public.apply_mpesa_c2b_callback(text,text,numeric,text,timestamptz,jsonb) from public;
grant execute on function public.apply_mpesa_c2b_callback(text,text,numeric,text,timestamptz,jsonb) to service_role;
