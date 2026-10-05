-- Complete operational workflows: PO receiving, quarantine/recall, branches and supplier performance.

create or replace function public.admin_receive_purchase_order(p_po_id uuid,p_invoice_number text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare po public.purchase_orders%rowtype; i jsonb; it public.purchase_order_items%rowtype; v_qty int; v_cost numeric; v_batch uuid; v_receipt uuid:=gen_random_uuid(); v_no text; v_total numeric:=0;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into po from purchase_orders where id=p_po_id for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if po.status not in ('approved','ordered','partially_received') then raise exception 'Purchase order is not ready for receiving'; end if;
  v_no:='GRN-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_receipt::text,'-',''),1,6);
  insert into stock_receipts(id,receipt_number,supplier_name,invoice_number,received_by) values(v_receipt,v_no,po.supplier_name,nullif(trim(p_invoice_number),''),auth.uid());
  for i in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    select * into it from purchase_order_items where id=(i->>'item_id')::uuid and purchase_order_id=p_po_id for update;
    if not found then raise exception 'Purchase order item not found'; end if;
    v_qty:=(i->>'quantity')::int; v_cost:=coalesce((i->>'unit_cost')::numeric,it.unit_cost);
    if v_qty is null or v_qty<=0 or it.quantity_received+v_qty>it.quantity_ordered then raise exception 'Invalid received quantity'; end if;
    insert into batches(medicine_id,batch_number,expiry_date,quantity,supplier_name)
      values(it.medicine_id,trim(i->>'batch_number'),(i->>'expiry_date')::date,v_qty,po.supplier_name)
      on conflict(medicine_id,batch_number) do update set quantity=batches.quantity+excluded.quantity,expiry_date=excluded.expiry_date,supplier_name=excluded.supplier_name
      returning id into v_batch;
    insert into stock_receipt_items(receipt_id,medicine_id,batch_id,quantity,unit_cost) values(v_receipt,it.medicine_id,v_batch,v_qty,v_cost);
    insert into stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(it.medicine_id,v_batch,'receive',v_qty,'purchase_order',p_po_id,auth.uid(),jsonb_build_object('purchase_order',po.po_number,'invoice',p_invoice_number));
    insert into inventory(medicine_id,quantity) values(it.medicine_id,v_qty) on conflict(medicine_id) do update set quantity=inventory.quantity+excluded.quantity;
    update purchase_order_items set quantity_received=quantity_received+v_qty where id=it.id;
    v_total:=v_total+v_qty*v_cost;
  end loop;
  if not exists(select 1 from purchase_order_items where purchase_order_id=p_po_id and quantity_received<quantity_ordered) then update purchase_orders set status='received',updated_at=now() where id=p_po_id;
  else update purchase_orders set status='partially_received',updated_at=now() where id=p_po_id; end if;
  update stock_receipts set total_cost=v_total where id=v_receipt;
  if po.supplier_id is not null or po.supplier_name is not null then
    insert into supplier_ledger(supplier_id,supplier_name,entry_type,reference,amount,notes,recorded_by) values(po.supplier_id,coalesce(po.supplier_name,'Supplier'),'invoice',p_invoice_number,v_total,'Purchase order receipt',auth.uid());
  end if;
  perform public.audit('PURCHASE_ORDER_RECEIVED','purchase_order',p_po_id::text,jsonb_build_object('receipt',v_no,'total_cost',v_total));
  return v_receipt;
end $$;

create or replace function public.admin_quarantine_batch(p_batch_id uuid,p_quantity integer,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare b public.batches%rowtype; q uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select * into b from batches where id=p_batch_id for update;
  if not found or p_quantity<=0 or b.quantity<p_quantity then raise exception 'Invalid quarantine quantity'; end if;
  update batches set quantity=quantity-p_quantity where id=p_batch_id;
  update inventory set quantity=quantity-p_quantity where medicine_id=b.medicine_id and quantity>=p_quantity;
  if not found then raise exception 'Inventory cannot be reduced for quarantine'; end if;
  insert into stock_quarantine(id,batch_id,medicine_id,quantity,reason,created_by) values(q,b.id,b.medicine_id,p_quantity,trim(p_reason),auth.uid());
  insert into stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(b.medicine_id,b.id,'adjustment',-p_quantity,'quarantine',q,auth.uid(),jsonb_build_object('reason',p_reason));
  perform public.audit('BATCH_QUARANTINED','batch',b.id::text,jsonb_build_object('quantity',p_quantity,'reason',p_reason));
  return q;
end $$;

create or replace function public.admin_resolve_quarantine(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
declare q public.stock_quarantine%rowtype;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_status not in ('released','disposed','returned') then raise exception 'Invalid resolution'; end if;
  select * into q from stock_quarantine where id=p_id for update;
  if not found or q.status<>'quarantined' then raise exception 'Quarantine record unavailable'; end if;
  if p_status='released' then update batches set quantity=quantity+q.quantity where id=q.batch_id; update inventory set quantity=quantity+q.quantity where medicine_id=q.medicine_id; end if;
  update stock_quarantine set status=p_status,resolved_by=auth.uid(),resolved_at=now() where id=p_id;
  perform public.audit('QUARANTINE_RESOLVED','quarantine',p_id::text,jsonb_build_object('status',p_status));
end $$;

create or replace function public.admin_create_recall(p_medicine_id uuid,p_batch_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  insert into recall_notices(id,medicine_id,batch_id,reason,created_by) values(v_id,p_medicine_id,p_batch_id,trim(p_reason),auth.uid());
  perform public.audit('RECALL_CREATED','recall',v_id::text,jsonb_build_object('medicine_id',p_medicine_id,'batch_id',p_batch_id,'reason',p_reason));
  return v_id;
end $$;

create or replace function public.admin_resolve_recall(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  update recall_notices set status='resolved',resolved_by=auth.uid(),resolved_at=now() where id=p_id and status='open';
  if not found then raise exception 'Recall not found'; end if;
  perform public.audit('RECALL_RESOLVED','recall',p_id::text,'{}');
end $$;

create or replace function public.admin_create_branch(p_name text,p_code text,p_phone text,p_address text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  insert into pharmacy_branches(id,name,code,phone,address) values(v_id,trim(p_name),upper(trim(p_code)),nullif(trim(p_phone),''),nullif(trim(p_address),''));
  perform public.audit('BRANCH_CREATED','branch',v_id::text,jsonb_build_object('code',p_code));
  return v_id;
end $$;

create or replace function public.admin_assign_branch(p_user_id uuid,p_branch_id uuid,p_manager boolean default false)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if not exists(select 1 from profiles where id=p_user_id) or not exists(select 1 from pharmacy_branches where id=p_branch_id and active) then raise exception 'User or branch not found'; end if;
  insert into branch_memberships(branch_id,user_id,is_manager) values(p_branch_id,p_user_id,p_manager) on conflict(branch_id,user_id) do update set is_manager=excluded.is_manager,active=true;
  perform public.audit('BRANCH_ASSIGNED','branch_membership',p_user_id::text,jsonb_build_object('branch_id',p_branch_id,'manager',p_manager));
end $$;

create or replace function public.admin_supplier_performance()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select coalesce(jsonb_agg(x order by x.purchase_value desc),'[]') into v from (
    select coalesce(supplier_name,'Unknown') supplier_name,count(*) receipts,coalesce(sum(total_cost),0) purchase_value,max(received_at) last_received
    from stock_receipts where status='received' and received_at>=now()-interval '180 days' group by supplier_name
  )x;
  return v;
end $$;

revoke all on function public.admin_receive_purchase_order(uuid,text,jsonb) from public;
revoke all on function public.admin_quarantine_batch(uuid,integer,text) from public;
revoke all on function public.admin_resolve_quarantine(uuid,text) from public;
revoke all on function public.admin_create_recall(uuid,uuid,text) from public;
revoke all on function public.admin_resolve_recall(uuid) from public;
revoke all on function public.admin_create_branch(text,text,text,text) from public;
revoke all on function public.admin_assign_branch(uuid,uuid,boolean) from public;
revoke all on function public.admin_supplier_performance() from public;
grant execute on function public.admin_receive_purchase_order(uuid,text,jsonb) to authenticated;
grant execute on function public.admin_quarantine_batch(uuid,integer,text) to authenticated;
grant execute on function public.admin_resolve_quarantine(uuid,text) to authenticated;
grant execute on function public.admin_create_recall(uuid,uuid,text) to authenticated;
grant execute on function public.admin_resolve_recall(uuid) to authenticated;
grant execute on function public.admin_create_branch(text,text,text,text) to authenticated;
grant execute on function public.admin_assign_branch(uuid,uuid,boolean) to authenticated;
grant execute on function public.admin_supplier_performance() to authenticated;
