-- Advanced pharmacy operations: purchasing, supplier ledger, locations, holds,
-- reorder intelligence, quarantine/recall, branch foundation and split payments.

create table if not exists public.pharmacy_branches(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 code text not null unique,
 phone text,
 address text,
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.branch_memberships(
 branch_id uuid not null references public.pharmacy_branches(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 is_manager boolean not null default false,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 primary key(branch_id,user_id)
);

create table if not exists public.purchase_orders(
 id uuid primary key default gen_random_uuid(),
 po_number text not null unique,
 supplier_id uuid references public.suppliers(id),
 supplier_name text,
 status text not null default 'draft' check(status in ('draft','submitted','approved','ordered','partially_received','received','cancelled')),
 expected_date date,
 notes text,
 total_cost numeric(12,2) not null default 0,
 created_by uuid not null references public.profiles(id),
 approved_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.purchase_order_items(
 id uuid primary key default gen_random_uuid(),
 purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
 medicine_id uuid not null references public.medicines(id),
 quantity_ordered integer not null check(quantity_ordered>0),
 quantity_received integer not null default 0 check(quantity_received>=0),
 unit_cost numeric(12,2) not null check(unit_cost>=0),
 total_cost numeric(12,2) generated always as (quantity_ordered*unit_cost) stored
);

create table if not exists public.supplier_ledger(
 id uuid primary key default gen_random_uuid(),
 supplier_id uuid references public.suppliers(id),
 supplier_name text not null,
 entry_type text not null check(entry_type in ('invoice','payment','credit','debit')),
 reference text,
 amount numeric(12,2) not null check(amount>0),
 entry_date date not null default current_date,
 notes text,
 recorded_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);

create table if not exists public.stock_locations(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 location_type text not null default 'shelf' check(location_type in ('shelf','refrigerator','controlled','quarantine','store','other')),
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.medicine_locations(
 medicine_id uuid not null references public.medicines(id) on delete cascade,
 location_id uuid not null references public.stock_locations(id) on delete restrict,
 preferred boolean not null default true,
 created_at timestamptz not null default now(),
 primary key(medicine_id,location_id)
);

create table if not exists public.held_sales(
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null references public.profiles(id) on delete cascade,
 hold_reference text not null,
 cart jsonb not null default '[]'::jsonb,
 prescription_id uuid references public.prescriptions(id),
 notes text,
 created_at timestamptz not null default now(),
 unique(seller_id,hold_reference)
);

create table if not exists public.reorder_recommendations(
 id uuid primary key default gen_random_uuid(),
 medicine_id uuid not null references public.medicines(id) on delete cascade,
 recommended_quantity integer not null check(recommended_quantity>0),
 average_daily_sales numeric(12,2) not null default 0,
 days_of_cover numeric(12,2),
 reason text not null,
 status text not null default 'open' check(status in ('open','converted','dismissed')),
 generated_at timestamptz not null default now()
);

create table if not exists public.stock_quarantine(
 id uuid primary key default gen_random_uuid(),
 batch_id uuid not null references public.batches(id),
 medicine_id uuid not null references public.medicines(id),
 quantity integer not null check(quantity>0),
 reason text not null,
 status text not null default 'quarantined' check(status in ('quarantined','released','disposed','returned')),
 created_by uuid not null references public.profiles(id),
 resolved_by uuid references public.profiles(id),
 resolved_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.recall_notices(
 id uuid primary key default gen_random_uuid(),
 medicine_id uuid not null references public.medicines(id),
 batch_id uuid references public.batches(id),
 reason text not null,
 status text not null default 'open' check(status in ('open','resolved')),
 created_by uuid not null references public.profiles(id),
 resolved_by uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);

alter table public.pharmacy_branches enable row level security;
alter table public.branch_memberships enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.supplier_ledger enable row level security;
alter table public.stock_locations enable row level security;
alter table public.medicine_locations enable row level security;
alter table public.held_sales enable row level security;
alter table public.reorder_recommendations enable row level security;
alter table public.stock_quarantine enable row level security;
alter table public.recall_notices enable row level security;

drop policy if exists "staff read branches" on public.pharmacy_branches;
create policy "staff read branches" on public.pharmacy_branches for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage branches" on public.pharmacy_branches;
create policy "admin manage branches" on public.pharmacy_branches for all using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "staff read locations" on public.stock_locations;
create policy "staff read locations" on public.stock_locations for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage locations" on public.stock_locations;
create policy "admin manage locations" on public.stock_locations for all using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "staff read medicine locations" on public.medicine_locations;
create policy "staff read medicine locations" on public.medicine_locations for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage medicine locations" on public.medicine_locations;
create policy "admin manage medicine locations" on public.medicine_locations for all using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists "admin purchase orders" on public.purchase_orders;
create policy "admin purchase orders" on public.purchase_orders for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin purchase order items" on public.purchase_order_items;
create policy "admin purchase order items" on public.purchase_order_items for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin supplier ledger" on public.supplier_ledger;
create policy "admin supplier ledger" on public.supplier_ledger for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "seller held sales" on public.held_sales;
create policy "seller held sales" on public.held_sales for all using(seller_id=auth.uid()) with check(seller_id=auth.uid());
drop policy if exists "admin held sales" on public.held_sales;
create policy "admin held sales" on public.held_sales for select using(public.current_role()='admin');
drop policy if exists "admin reorder recommendations" on public.reorder_recommendations;
create policy "admin reorder recommendations" on public.reorder_recommendations for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin quarantine" on public.stock_quarantine;
create policy "admin quarantine" on public.stock_quarantine for all using(public.current_role()='admin') with check(public.current_role()='admin');
drop policy if exists "admin recalls" on public.recall_notices;
create policy "admin recalls" on public.recall_notices for all using(public.current_role()='admin') with check(public.current_role()='admin');

do $$ begin
  if not exists(select 1 from public.stock_locations) then
    insert into public.stock_locations(name,location_type) values
      ('Main Shelf','shelf'),('Refrigerator','refrigerator'),('Controlled Storage','controlled'),('Quarantine','quarantine');
  end if;
end $$;

create or replace function public.admin_create_purchase_order(p_supplier_id uuid,p_supplier_name text,p_expected_date date,p_notes text,p_items jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid(); v_no text; i jsonb; v_total numeric:=0; v_med uuid; v_qty int; v_cost numeric;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Purchase order requires items'; end if;
  v_no:='PO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS')||'-'||substr(replace(v_id::text,'-',''),1,6);
  insert into public.purchase_orders(id,po_number,supplier_id,supplier_name,expected_date,notes,created_by)
  values(v_id,v_no,p_supplier_id,nullif(trim(p_supplier_name),''),p_expected_date,nullif(trim(p_notes),''),auth.uid());
  for i in select * from jsonb_array_elements(p_items) loop
    v_med:=(i->>'medicine_id')::uuid; v_qty:=(i->>'quantity')::int; v_cost:=(i->>'unit_cost')::numeric;
    if v_qty<=0 or v_cost<0 then raise exception 'Invalid purchase item'; end if;
    if not exists(select 1 from public.medicines where id=v_med and active=true) then raise exception 'Medicine unavailable'; end if;
    insert into public.purchase_order_items(purchase_order_id,medicine_id,quantity_ordered,unit_cost) values(v_id,v_med,v_qty,v_cost);
    v_total:=v_total+v_qty*v_cost;
  end loop;
  update public.purchase_orders set total_cost=v_total,status='submitted',updated_at=now() where id=v_id;
  perform public.audit('PURCHASE_ORDER_CREATED','purchase_order',v_id::text,jsonb_build_object('total_cost',v_total));
  return v_id;
end $$;

create or replace function public.admin_update_purchase_order_status(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_status not in ('draft','submitted','approved','ordered','cancelled') then raise exception 'Invalid purchase order status'; end if;
  update public.purchase_orders set status=p_status,approved_by=case when p_status='approved' then auth.uid() else approved_by end,updated_at=now() where id=p_id;
  if not found then raise exception 'Purchase order not found'; end if;
  perform public.audit('PURCHASE_ORDER_STATUS','purchase_order',p_id::text,jsonb_build_object('status',p_status));
end $$;

create or replace function public.admin_record_supplier_payment(p_supplier_id uuid,p_supplier_name text,p_amount numeric,p_reference text,p_notes text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_amount<=0 then raise exception 'Amount must be greater than zero'; end if;
  insert into public.supplier_ledger(id,supplier_id,supplier_name,entry_type,reference,amount,notes,recorded_by)
  values(v_id,p_supplier_id,coalesce(nullif(trim(p_supplier_name),''),'Supplier'),'payment',nullif(trim(p_reference),''),p_amount,nullif(trim(p_notes),''),auth.uid());
  perform public.audit('SUPPLIER_PAYMENT','supplier',coalesce(p_supplier_id::text,p_supplier_name),jsonb_build_object('amount',p_amount,'reference',p_reference));
  return v_id;
end $$;

create or replace function public.admin_supplier_balances()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select coalesce(jsonb_agg(x order by x.balance desc),'[]'::jsonb) into v from (
    select coalesce(supplier_id::text,supplier_name) key,supplier_name,
      sum(case when entry_type in ('invoice','debit') then amount else -amount end) balance
    from public.supplier_ledger group by supplier_id,supplier_name
  ) x where x.balance<>0;
  return v;
end $$;

create or replace function public.generate_reorder_recommendations()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  insert into public.reorder_recommendations(medicine_id,recommended_quantity,average_daily_sales,days_of_cover,reason)
  select m.id,greatest(m.reorder_level-coalesce(i.quantity,0),ceil(coalesce(s.avg_daily,0)*14)::int),coalesce(s.avg_daily,0),
         case when coalesce(i.quantity,0)=0 then 0 else coalesce(i.quantity,0)/nullif(s.avg_daily,0) end,
         case when coalesce(i.quantity,0)=0 then 'Out of stock' when coalesce(s.avg_daily,0)>0 and i.quantity/s.avg_daily<7 then 'Less than 7 days of cover' else 'Below reorder level' end
  from public.medicines m join public.inventory i on i.medicine_id=m.id
  left join lateral (select coalesce(sum(si.quantity),0)/30.0 avg_daily from public.sale_items si join public.sales sa on sa.id=si.sale_id where si.medicine_id=m.id and sa.status='paid' and sa.created_at>=now()-interval '30 days') s on true
  where m.active and (i.quantity<=m.reorder_level or i.quantity=0) and not exists(select 1 from public.reorder_recommendations r where r.medicine_id=m.id and r.status='open');
  select coalesce(jsonb_agg(r order by r.generated_at desc),'[]'::jsonb) into v from public.reorder_recommendations r where r.status='open';
  return v;
end $$;

create or replace function public.admin_inventory_intelligence()
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  select jsonb_build_object(
    'fast_moving',(select coalesce(jsonb_agg(x order by x.qty desc),'[]') from (select m.name,sum(si.quantity) qty from sale_items si join sales s on s.id=si.sale_id join medicines m on m.id=si.medicine_id where s.status='paid' and s.created_at>=now()-interval '30 days' group by m.name order by qty desc limit 10)x),
    'slow_moving',(select coalesce(jsonb_agg(x order by x.qty),'[]') from (select m.name,sum(si.quantity) qty from sale_items si join sales s on s.id=si.sale_id join medicines m on m.id=si.medicine_id where s.status='paid' and s.created_at>=now()-interval '30 days' group by m.name order by qty limit 10)x),
    'dead_stock',(select coalesce(jsonb_agg(x),'[]') from (select m.name,i.quantity,i.updated_at from inventory i join medicines m on m.id=i.medicine_id where i.quantity>0 and not exists(select 1 from sale_items si join sales s on s.id=si.sale_id where si.medicine_id=m.id and s.status='paid' and s.created_at>=now()-interval '60 days') order by i.quantity desc limit 20)x),
    'expiry',(select coalesce(jsonb_agg(x order by x.expiry_date),'[]') from (select m.name,b.batch_number,b.expiry_date,b.quantity from batches b join medicines m on m.id=b.medicine_id where b.quantity>0 and b.expiry_date<=current_date+90 order by b.expiry_date limit 30)x),
    'reorder',(select coalesce(jsonb_agg(x order by x.recommended_quantity desc),'[]') from (select r.*,m.name from reorder_recommendations r join medicines m on m.id=r.medicine_id where r.status='open')x)
  ) into result;
  return result;
end $$;

create or replace function public.set_medicine_location(p_medicine_id uuid,p_location_id uuid,p_preferred boolean default true)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if not exists(select 1 from medicines where id=p_medicine_id) then raise exception 'Medicine not found'; end if;
  if not exists(select 1 from stock_locations where id=p_location_id and active) then raise exception 'Location not found'; end if;
  if p_preferred then update medicine_locations set preferred=false where medicine_id=p_medicine_id; end if;
  insert into medicine_locations(medicine_id,location_id,preferred) values(p_medicine_id,p_location_id,p_preferred)
  on conflict(medicine_id,location_id) do update set preferred=excluded.preferred;
end $$;

create or replace function public.hold_sale(p_hold_reference text,p_cart jsonb,p_prescription_id uuid default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid:=gen_random_uuid();
begin
  if public.current_role()<>'seller' then raise exception 'Seller authorization required'; end if;
  if not exists(select 1 from seller_permissions where user_id=auth.uid() and can_sell) then raise exception 'Seller cannot process sales'; end if;
  if jsonb_array_length(coalesce(p_cart,'[]'::jsonb))=0 then raise exception 'Cart is empty'; end if;
  insert into held_sales(id,seller_id,hold_reference,cart,prescription_id,notes) values(v_id,auth.uid(),trim(p_hold_reference),p_cart,p_prescription_id,nullif(trim(p_notes),''))
  on conflict(seller_id,hold_reference) do update set cart=excluded.cart,prescription_id=excluded.prescription_id,notes=excluded.notes,created_at=now();
  perform public.audit('SALE_HELD','held_sale',v_id::text,jsonb_build_object('reference',p_hold_reference));
  return v_id;
end $$;

create or replace function public.my_held_sales()
returns setof public.held_sales language sql security definer set search_path=public as $$
  select * from public.held_sales where seller_id=auth.uid() order by created_at desc
$$;

create or replace function public.delete_held_sale(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  delete from held_sales where id=p_id and seller_id=auth.uid();
end $$;

-- Split manual payments for cash/other. Stock is deducted only when the sum reaches the sale total.
create or replace function public.add_manual_sale_payment(p_sale_id uuid,p_method text,p_amount numeric,p_reference text default null)
returns numeric language plpgsql security definer set search_path=public as $$
declare s public.sales%rowtype; paid numeric; r record; b public.batches%rowtype; v_sum numeric;
begin
  select * into s from sales where id=p_sale_id for update;
  if not found or s.status<>'pending_payment' then raise exception 'Sale is not awaiting payment'; end if;
  if public.current_role()='seller' and s.seller_id<>auth.uid() then raise exception 'Unauthorized'; end if;
  if p_method not in ('cash','other') or p_amount<=0 then raise exception 'Invalid split payment'; end if;
  select coalesce(sum(amount),0) into paid from payments where sale_id=p_sale_id and status='paid';
  if paid+p_amount>s.total_amount then raise exception 'Payment exceeds outstanding balance'; end if;
  insert into payments(sale_id,method,amount,provider_reference,status,confirmed_at) values(p_sale_id,p_method,p_amount,p_reference,'paid',now());
  v_sum:=paid+p_amount;
  if abs(v_sum-s.total_amount)<=0.01 then
    for r in select * from sale_items where sale_id=p_sale_id for update loop
      if r.batch_id is not null then
        select * into b from batches where id=r.batch_id and expiry_date>=current_date and quantity>=r.quantity for update;
      else
        select * into b from batches where medicine_id=r.medicine_id and expiry_date>=current_date and quantity>=r.quantity order by expiry_date,received_at limit 1 for update;
        if b.id is not null then update sale_items set batch_id=b.id where id=r.id; end if;
      end if;
      if b.id is null then raise exception 'Insufficient unexpired stock while completing payment'; end if;
      update batches set quantity=quantity-r.quantity where id=b.id;
      update inventory set quantity=quantity-r.quantity where medicine_id=r.medicine_id and quantity>=r.quantity;
      if not found then raise exception 'Inventory changed while completing payment'; end if;
      insert into stock_movements(medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details) values(r.medicine_id,b.id,'sale',-r.quantity,'sale',s.id,auth.uid(),jsonb_build_object('split_payment',true));
    end loop;
    update sales set status='paid' where id=s.id;
    perform public.audit('SPLIT_PAYMENT_COMPLETED','sale',s.id::text,jsonb_build_object('amount',v_sum));
  end if;
  return greatest(s.total_amount-v_sum,0);
end $$;

revoke all on function public.admin_create_purchase_order(uuid,text,date,text,jsonb) from public;
revoke all on function public.admin_update_purchase_order_status(uuid,text) from public;
revoke all on function public.admin_record_supplier_payment(uuid,text,numeric,text,text) from public;
revoke all on function public.admin_supplier_balances() from public;
revoke all on function public.generate_reorder_recommendations() from public;
revoke all on function public.admin_inventory_intelligence() from public;
revoke all on function public.set_medicine_location(uuid,uuid,boolean) from public;
revoke all on function public.hold_sale(text,jsonb,uuid,text) from public;
revoke all on function public.my_held_sales() from public;
revoke all on function public.delete_held_sale(uuid) from public;
revoke all on function public.add_manual_sale_payment(uuid,text,numeric,text) from public;
grant execute on function public.admin_create_purchase_order(uuid,text,date,text,jsonb) to authenticated;
grant execute on function public.admin_update_purchase_order_status(uuid,text) to authenticated;
grant execute on function public.admin_record_supplier_payment(uuid,text,numeric,text,text) to authenticated;
grant execute on function public.admin_supplier_balances() to authenticated;
grant execute on function public.generate_reorder_recommendations() to authenticated;
grant execute on function public.admin_inventory_intelligence() to authenticated;
grant execute on function public.set_medicine_location(uuid,uuid,boolean) to authenticated;
grant execute on function public.hold_sale(text,jsonb,uuid,text) to authenticated;
grant execute on function public.my_held_sales() to authenticated;
grant execute on function public.delete_held_sale(uuid) to authenticated;
grant execute on function public.add_manual_sale_payment(uuid,text,numeric,text) to authenticated;
