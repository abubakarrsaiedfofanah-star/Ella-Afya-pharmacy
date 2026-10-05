-- Advanced controls: fine-grained seller permissions, operational notifications,
-- fraud signals and secure stock-count workflow.

create table if not exists public.seller_permissions(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  can_sell boolean not null default true,
  can_process_prescriptions boolean not null default true,
  can_request_refund boolean not null default true,
  can_request_cancellation boolean not null default true,
  can_request_stock_adjustment boolean not null default true,
  can_view_own_reports boolean not null default true,
  max_discount_percent numeric(5,2) not null default 0 check(max_discount_percent between 0 and 100),
  max_transaction_amount numeric(12,2),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.operational_notifications(
  id uuid primary key default gen_random_uuid(),
  notification_type text not null,
  severity text not null default 'info' check(severity in ('info','warning','critical')),
  title text not null,
  message text not null,
  entity_type text,
  entity_id text,
  target_user_id uuid references public.profiles(id) on delete cascade,
  metadata jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_operational_notifications_target on public.operational_notifications(target_user_id,read_at,created_at desc);
create index if not exists idx_operational_notifications_open on public.operational_notifications(resolved_at,created_at desc);

create table if not exists public.stock_counts(
  id uuid primary key default gen_random_uuid(),
  count_number text unique not null,
  status text not null default 'draft' check(status in ('draft','submitted','approved','rejected')),
  notes text,
  counted_by uuid not null references public.profiles(id),
  reviewed_by uuid references public.profiles(id),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.stock_count_items(
  id uuid primary key default gen_random_uuid(),
  stock_count_id uuid not null references public.stock_counts(id) on delete cascade,
  medicine_id uuid not null references public.medicines(id),
  batch_id uuid references public.batches(id),
  system_quantity integer not null,
  counted_quantity integer not null check(counted_quantity>=0),
  variance integer generated always as (counted_quantity-system_quantity) stored,
  unique(stock_count_id,medicine_id,batch_id)
);
create index if not exists idx_stock_counts_status on public.stock_counts(status,created_at desc);

alter table public.seller_permissions enable row level security;
alter table public.operational_notifications enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_count_items enable row level security;

create policy "seller own permissions" on public.seller_permissions for select using(user_id=auth.uid() or public.current_role()='admin');
create policy "admin manage permissions" on public.seller_permissions for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "admin notifications" on public.operational_notifications for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "own notifications" on public.operational_notifications for select using(target_user_id=auth.uid());
create policy "admin stock counts" on public.stock_counts for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "staff own stock counts" on public.stock_counts for select using(counted_by=auth.uid() or public.current_role()='admin');
create policy "admin stock count items" on public.stock_count_items for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "staff own stock count items" on public.stock_count_items for select using(exists(select 1 from public.stock_counts c where c.id=stock_count_id and c.counted_by=auth.uid()));

create or replace function public.ensure_seller_permissions()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.role='seller' then
    insert into public.seller_permissions(user_id) values(new.id) on conflict(user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists trg_ensure_seller_permissions on public.profiles;
create trigger trg_ensure_seller_permissions after insert or update of role on public.profiles for each row execute function public.ensure_seller_permissions();
insert into public.seller_permissions(user_id)
select id from public.profiles where role='seller' on conflict(user_id) do nothing;

create or replace function public.get_my_seller_permissions()
returns jsonb language sql stable security definer set search_path=public as $$
select coalesce(to_jsonb(p),'{}'::jsonb) from public.seller_permissions p where p.user_id=auth.uid() and public.current_role()='seller';
$$;

create or replace function public.admin_set_seller_permissions(
  p_user_id uuid,
  p_can_sell boolean,
  p_can_process_prescriptions boolean,
  p_can_request_refund boolean,
  p_can_request_cancellation boolean,
  p_can_request_stock_adjustment boolean,
  p_can_view_own_reports boolean,
  p_max_discount_percent numeric,
  p_max_transaction_amount numeric default null
)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from public.profiles where id=p_user_id and role='seller') then raise exception 'Seller account not found'; end if;
  if p_max_discount_percent<0 or p_max_discount_percent>100 then raise exception 'Invalid discount limit'; end if;
  if p_max_transaction_amount is not null and p_max_transaction_amount<=0 then raise exception 'Invalid transaction limit'; end if;
  insert into public.seller_permissions(user_id,can_sell,can_process_prescriptions,can_request_refund,can_request_cancellation,can_request_stock_adjustment,can_view_own_reports,max_discount_percent,max_transaction_amount,updated_by,updated_at)
  values(p_user_id,p_can_sell,p_can_process_prescriptions,p_can_request_refund,p_can_request_cancellation,p_can_request_stock_adjustment,p_can_view_own_reports,p_max_discount_percent,p_max_transaction_amount,auth.uid(),now())
  on conflict(user_id) do update set can_sell=excluded.can_sell,can_process_prescriptions=excluded.can_process_prescriptions,can_request_refund=excluded.can_request_refund,can_request_cancellation=excluded.can_request_cancellation,can_request_stock_adjustment=excluded.can_request_stock_adjustment,can_view_own_reports=excluded.can_view_own_reports,max_discount_percent=excluded.max_discount_percent,max_transaction_amount=excluded.max_transaction_amount,updated_by=auth.uid(),updated_at=now();
  perform public.audit('SELLER_PERMISSIONS_UPDATED','profile',p_user_id::text,jsonb_build_object('max_discount_percent',p_max_discount_percent,'max_transaction_amount',p_max_transaction_amount));
  return true;
end $$;

create or replace function public.admin_create_notification(
  p_type text,p_severity text,p_title text,p_message text,p_entity_type text default null,p_entity_id text default null,p_target_user_id uuid default null,p_metadata jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  insert into public.operational_notifications(notification_type,severity,title,message,entity_type,entity_id,target_user_id,metadata)
  values(left(p_type,80),p_severity,left(p_title,180),left(p_message,1000),p_entity_type,p_entity_id,p_target_user_id,coalesce(p_metadata,'{}'::jsonb)) returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_notification_snapshot()
returns jsonb language sql stable security definer set search_path=public as $$
with low as (select count(*)::bigint n from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity<=m.reorder_level and m.active),
expiry as (select count(*)::bigint n from public.batches where quantity>0 and expiry_date between current_date and current_date+30),
expired as (select count(*)::bigint n from public.batches where quantity>0 and expiry_date<current_date),
refunds as (select count(*)::bigint n from public.approvals where status='pending' and action_type in ('refund','cancel_sale')),
adj as (select count(*)::bigint n from public.stock_adjustment_requests where status='pending'),
alerts as (select count(*)::bigint n from public.security_alerts where resolved=false)
select jsonb_build_object('low_stock',(select n from low),'expiring_batches',(select n from expiry),'expired_batches',(select n from expired),'pending_refunds',(select n from refunds),'pending_adjustments',(select n from adj),'open_security_alerts',(select n from alerts),'unread_notifications',(select count(*) from public.operational_notifications where target_user_id is null and read_at is null and resolved_at is null)) where public.current_role()='admin';
$$;

create or replace function public.admin_create_stock_count(p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  insert into public.stock_counts(count_number,notes,counted_by) values('SC-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-MS'),p_notes,auth.uid()) returning id into v_id;
  insert into public.stock_count_items(stock_count_id,medicine_id,batch_id,system_quantity,counted_quantity)
  select v_id,m.id,b.id,b.quantity,b.quantity from public.batches b join public.medicines m on m.id=b.medicine_id where b.quantity>0;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'CREATE_STOCK_COUNT','stock_count',v_id::text);
  return v_id;
end $$;

create or replace function public.admin_submit_stock_count(p_stock_count_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  update public.stock_counts set status='submitted',submitted_at=now() where id=p_stock_count_id and status='draft';
  if not found then raise exception 'Stock count is not editable'; end if;
  select jsonb_build_object('count_number',c.count_number,'items',count(i.*),'variance_units',coalesce(sum(i.variance),0)) into v from public.stock_counts c left join public.stock_count_items i on i.stock_count_id=c.id where c.id=p_stock_count_id group by c.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'SUBMIT_STOCK_COUNT','stock_count',p_stock_count_id::text,v);
  return v;
end $$;

-- Generate operational signals without allowing sellers to create their own alerts.
create or replace function public.generate_operational_notifications()
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer:=0; v_low integer; v_expiring integer; v_expired integer; v_pending integer;
begin
  if public.current_role()!='admin' then raise exception 'Administrator access required'; end if;
  select count(*) into v_low from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity<=m.reorder_level and m.active;
  select count(*) into v_expiring from public.batches where quantity>0 and expiry_date between current_date and current_date+30;
  select count(*) into v_expired from public.batches where quantity>0 and expiry_date<current_date;
  select count(*) into v_pending from public.approvals where status='pending';
  if v_low>0 and not exists(select 1 from public.operational_notifications where notification_type='low_stock' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('low_stock','warning','Low stock requires attention',v_low||' medicine records are at or below their reorder level.',jsonb_build_object('count',v_low)); v_count:=v_count+1;
  end if;
  if v_expiring>0 and not exists(select 1 from public.operational_notifications where notification_type='expiry' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('expiry','warning','Stock nearing expiry',v_expiring||' batches expire within 30 days.',jsonb_build_object('count',v_expiring)); v_count:=v_count+1;
  end if;
  if v_expired>0 and not exists(select 1 from public.operational_notifications where notification_type='expired_stock' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('expired_stock','critical','Expired stock detected',v_expired||' batches still have quantity after expiry and must not be dispensed.',jsonb_build_object('count',v_expired)); v_count:=v_count+1;
  end if;
  if v_pending>0 and not exists(select 1 from public.operational_notifications where notification_type='approvals' and created_at::date=current_date and resolved_at is null) then
    insert into public.operational_notifications(notification_type,severity,title,message,metadata) values('approvals','info','Approvals are waiting',v_pending||' seller action requests are waiting for admin review.',jsonb_build_object('count',v_pending)); v_count:=v_count+1;
  end if;
  return v_count;
end $$;

revoke all on function public.get_my_seller_permissions() from public;
revoke all on function public.admin_set_seller_permissions(uuid,boolean,boolean,boolean,boolean,boolean,boolean,numeric,numeric) from public;
revoke all on function public.admin_create_notification(text,text,text,text,text,text,uuid,jsonb) from public;
revoke all on function public.admin_notification_snapshot() from public;
revoke all on function public.admin_create_stock_count(text) from public;
revoke all on function public.admin_submit_stock_count(uuid) from public;
revoke all on function public.generate_operational_notifications() from public;
grant execute on function public.get_my_seller_permissions() to authenticated;
grant execute on function public.admin_set_seller_permissions(uuid,boolean,boolean,boolean,boolean,boolean,boolean,numeric,numeric) to authenticated;
grant execute on function public.admin_create_notification(text,text,text,text,text,text,uuid,jsonb) to authenticated;
grant execute on function public.admin_notification_snapshot() to authenticated;
grant execute on function public.admin_create_stock_count(text) to authenticated;
grant execute on function public.admin_submit_stock_count(uuid) to authenticated;
grant execute on function public.generate_operational_notifications() to authenticated;
