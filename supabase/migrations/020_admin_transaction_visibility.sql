create or replace function public.notify_admin_sale_event()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_seller text;
  v_action text;
  v_title text;
  v_message text;
  v_severity text:='info';
begin
  if tg_op='UPDATE' then
    if new.status is distinct from old.status then
      if new.status not in ('cancelled','refunded') then return new; end if;
    elsif new.total_amount is distinct from old.total_amount and new.total_amount>0 then
      null;
    else
      return new;
    end if;
  end if;
  if new.total_amount<=0 then return new; end if;

  select coalesce(full_name,'Seller') into v_seller
  from public.profiles where id=new.seller_id;

  v_action:=case
    when new.status='cancelled' then 'SALE_CANCELLED'
    when new.status='refunded' then 'SALE_REFUNDED'
    else 'SALE_OPENED'
  end;
  v_title:=case
    when new.status='cancelled' then 'Sale cancelled'
    when new.status='refunded' then 'Sale refunded'
    else 'New sale opened'
  end;
  if new.status in ('cancelled','refunded') then v_severity:='warning'; end if;
  v_message:=format('%s · KSh %s · %s',new.sale_number,to_char(new.total_amount,'FM999,999,999,990.00'),v_seller);

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),v_action,'sale',new.id::text,jsonb_build_object(
    'sale_number',new.sale_number,
    'seller_id',new.seller_id,
    'seller_name',v_seller,
    'amount',new.total_amount,
    'status',new.status
  ));

  insert into public.operational_notifications(notification_type,severity,title,message,entity_type,entity_id,metadata)
  values('transaction',v_severity,v_title,v_message,'sale',new.id::text,jsonb_build_object(
    'event',v_action,
    'sale_number',new.sale_number,
    'seller_id',new.seller_id,
    'seller_name',v_seller,
    'amount',new.total_amount,
    'sale_status',new.status
  ));
  return new;
end;
$$;

create or replace function public.notify_admin_payment_event()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_sale_number text;
  v_seller_id uuid;
  v_seller text;
  v_action text;
  v_title text;
  v_severity text:='info';
begin
  if tg_op='UPDATE' and new.status is not distinct from old.status then return new; end if;

  select s.sale_number,s.seller_id,coalesce(pr.full_name,'Seller')
  into v_sale_number,v_seller_id,v_seller
  from public.sales s
  join public.profiles pr on pr.id=s.seller_id
  where s.id=new.sale_id;

  v_action:='PAYMENT_'||upper(new.status::text);
  v_title:=case new.status
    when 'pending' then 'Payment started'
    when 'paid' then 'Payment received'
    when 'failed' then 'Payment failed'
    when 'refunded' then 'Payment refunded'
    else 'Payment updated'
  end;
  if new.status in ('failed','refunded') then v_severity:='warning'; end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),v_action,'payment',new.id::text,jsonb_build_object(
    'sale_id',new.sale_id,
    'sale_number',v_sale_number,
    'seller_id',v_seller_id,
    'seller_name',v_seller,
    'amount',new.amount,
    'method',new.method,
    'status',new.status,
    'provider_reference',new.provider_reference,
    'mpesa_receipt',new.mpesa_receipt
  ));

  insert into public.operational_notifications(notification_type,severity,title,message,entity_type,entity_id,metadata)
  values(
    'transaction',
    v_severity,
    v_title,
    format('%s · KSh %s · %s · %s',coalesce(v_sale_number,'Sale'),to_char(new.amount,'FM999,999,999,990.00'),upper(new.method),v_seller),
    'payment',
    new.id::text,
    jsonb_build_object(
      'event',v_action,
      'payment_id',new.id,
      'sale_id',new.sale_id,
      'sale_number',v_sale_number,
      'seller_id',v_seller_id,
      'seller_name',v_seller,
      'amount',new.amount,
      'method',new.method,
      'payment_status',new.status,
      'provider_reference',new.provider_reference,
      'mpesa_receipt',new.mpesa_receipt
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_admin_sale_visibility on public.sales;
create trigger trg_admin_sale_visibility
after insert or update of status,total_amount on public.sales
for each row execute function public.notify_admin_sale_event();

drop trigger if exists trg_admin_payment_visibility on public.payments;
create trigger trg_admin_payment_visibility
after insert or update of status on public.payments
for each row execute function public.notify_admin_payment_event();

create or replace function public.notify_admin_audit_event()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_severity text:='info';
  v_title text;
  v_message text;
begin
  if new.action in (
    'SALE_CREATED',
    'SALE_OPENED',
    'SALE_CANCELLED',
    'SALE_REFUNDED',
    'PAYMENT_CONFIRMED',
    'MPESA_PAYMENT_PREPARED',
    'PAYMENT_PENDING',
    'PAYMENT_PAID',
    'PAYMENT_FAILED',
    'PAYMENT_REFUNDED',
    'STOCK_DEDUCTED',
    'SPLIT_PAYMENT_COMPLETED'
  ) then
    return new;
  end if;

  if new.action ilike '%RESOLVED%' then
    v_severity:='info';
  elsif new.action ilike '%SECURITY%' or new.action ilike '%REVOKE%' then
    v_severity:='critical';
  elsif new.action ilike '%FAILED%'
     or new.action ilike '%REJECTED%'
     or new.action ilike '%REFUND%'
     or new.action ilike '%CANCEL%'
     or new.action ilike '%DISABLED%'
     or new.action ilike '%QUARANTINE%' then
    v_severity:='warning';
  end if;

  v_title:=initcap(replace(lower(new.action),'_',' '));
  v_message:=format('%s · %s',replace(new.entity_type,'_',' '),coalesce(new.entity_id,'record'));

  insert into public.operational_notifications(
    notification_type,severity,title,message,entity_type,entity_id,metadata
  ) values (
    'business_activity',v_severity,v_title,v_message,new.entity_type,new.entity_id,
    jsonb_build_object('action',new.action,'actor_id',new.actor_id,'audit_id',new.id)
  );
  return new;
end;
$$;

drop trigger if exists trg_admin_audit_visibility on public.audit_logs;
create trigger trg_admin_audit_visibility
after insert on public.audit_logs
for each row execute function public.notify_admin_audit_event();

create or replace function public.notify_admin_security_alert()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  insert into public.operational_notifications(
    notification_type,severity,title,message,entity_type,entity_id,metadata
  ) values (
    'security',
    case when new.severity in ('high','critical') then 'critical'
         when new.severity='medium' then 'warning'
         else 'info' end,
    new.title,
    format('%s · %s',replace(new.alert_type,'_',' '),coalesce(new.user_id::text,'business-wide')),
    'security_alert',
    new.id::text,
    jsonb_build_object('alert_type',new.alert_type,'severity',new.severity,'user_id',new.user_id,'details',new.details)
  );
  return new;
end;
$$;

drop trigger if exists trg_admin_security_alert_visibility on public.security_alerts;
create trigger trg_admin_security_alert_visibility
after insert on public.security_alerts
for each row execute function public.notify_admin_security_alert();

create or replace function public.audit_admin_master_data_change()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_before jsonb:='{}'::jsonb;
  v_after jsonb:=to_jsonb(new);
  v_changes jsonb;
  v_entity_id text;
  v_label text;
  v_action text;
begin
  if tg_op='UPDATE' then
    v_before:=to_jsonb(old);
    select coalesce(jsonb_object_agg(current_value.key,current_value.value),'{}'::jsonb)
    into v_changes
    from jsonb_each(v_after) as current_value(key,value)
    where v_before->current_value.key is distinct from current_value.value
      and current_value.key not in ('updated_at','updated_by')
      and not (tg_table_name='medicines' and current_value.key in ('selling_price','purchase_price'));
    if v_changes='{}'::jsonb then return new; end if;
  else
    v_changes:=v_after-'created_at'-'updated_at'-'updated_by';
  end if;

  v_entity_id:=coalesce(v_after->>'id',v_after->>'name','settings');
  v_label:=coalesce(v_after->>'name',v_after->>'pharmacy_name',v_entity_id);
  v_action:=case
    when tg_op='INSERT' then upper(tg_table_name)||'_CREATED'
    else upper(tg_table_name)||'_UPDATED'
  end;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),v_action,tg_table_name,v_entity_id,jsonb_build_object('label',v_label,'changes',v_changes));
  return new;
end;
$$;

drop trigger if exists trg_audit_medicine_master_data on public.medicines;
create trigger trg_audit_medicine_master_data
after insert or update on public.medicines
for each row execute function public.audit_admin_master_data_change();

drop trigger if exists trg_audit_supplier_master_data on public.suppliers;
create trigger trg_audit_supplier_master_data
after insert or update on public.suppliers
for each row execute function public.audit_admin_master_data_change();

drop trigger if exists trg_audit_pharmacy_settings on public.pharmacy_settings;
create trigger trg_audit_pharmacy_settings
after update on public.pharmacy_settings
for each row execute function public.audit_admin_master_data_change();

revoke all on function public.notify_admin_sale_event() from public,anon,authenticated;
revoke all on function public.notify_admin_payment_event() from public,anon,authenticated;
revoke all on function public.notify_admin_audit_event() from public,anon,authenticated;
revoke all on function public.notify_admin_security_alert() from public,anon,authenticated;
revoke all on function public.audit_admin_master_data_change() from public,anon,authenticated;

create or replace function public.admin_transaction_feed(
  p_limit integer default 200,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns table(
  payment_id uuid,
  sale_id uuid,
  sale_number text,
  seller_name text,
  amount numeric,
  method text,
  status text,
  provider_reference text,
  mpesa_receipt text,
  created_at timestamptz,
  confirmed_at timestamptz
)
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
begin
  if public.current_role()<>'admin' then
    raise exception 'Admin access required';
  end if;

  return query
  select p.id,p.sale_id,s.sale_number,coalesce(pr.full_name,'Seller'),p.amount,p.method,p.status::text,
         p.provider_reference,p.mpesa_receipt,p.created_at,p.confirmed_at
  from public.payments p
  join public.sales s on s.id=p.sale_id
  join public.profiles pr on pr.id=s.seller_id
  where p_before_created_at is null
     or (p.created_at,p.id)<(p_before_created_at,p_before_id)
  order by p.created_at desc,p.id desc
  limit greatest(1,least(coalesce(p_limit,200),500));
end;
$$;

revoke all on function public.admin_transaction_feed(integer,timestamptz,uuid) from public,anon;
grant execute on function public.admin_transaction_feed(integer,timestamptz,uuid) to authenticated;

create or replace function public.admin_activity_feed(
  p_limit integer default 50,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null
)
returns table(
  id uuid,
  severity text,
  title text,
  message text,
  notification_type text,
  entity_type text,
  entity_id text,
  metadata jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
begin
  if public.current_role()<>'admin' then
    raise exception 'Admin access required';
  end if;

  return query
  select n.id,n.severity,n.title,n.message,n.notification_type,n.entity_type,n.entity_id,n.metadata,n.read_at,n.created_at
  from public.operational_notifications n
  where p_before_created_at is null or (n.created_at,n.id)<(p_before_created_at,p_before_id)
  order by n.created_at desc,n.id desc
  limit greatest(1,least(coalesce(p_limit,50),200));
end;
$$;

revoke all on function public.admin_activity_feed(integer,timestamptz,uuid) from public,anon;
grant execute on function public.admin_activity_feed(integer,timestamptz,uuid) to authenticated;

create index if not exists idx_operational_notifications_history
on public.operational_notifications(created_at desc,id desc);