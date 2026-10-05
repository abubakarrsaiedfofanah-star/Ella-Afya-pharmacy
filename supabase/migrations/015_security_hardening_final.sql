-- Final security hardening layer.
-- Sensitive financial/audit state transitions must happen through trusted RPCs.

-- Prevent browser clients from directly rewriting or deleting financial/audit records.
revoke update, delete on table public.audit_logs from anon, authenticated;
revoke update, delete on table public.payments from anon, authenticated;
revoke update, delete on table public.sales from anon, authenticated;
revoke update, delete on table public.sale_items from anon, authenticated;

-- Audit records are append-only.
create or replace function public.block_audit_mutation()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  raise exception 'Audit records are immutable';
end $$;
drop trigger if exists trg_audit_immutable on public.audit_logs;
create trigger trg_audit_immutable before update or delete on public.audit_logs
for each row execute function public.block_audit_mutation();

-- Resolve security alerts through a server-side audited action.
create or replace function public.resolve_security_alert(p_alert_id uuid,p_note text default null)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if public.current_role() <> 'admin' then raise exception 'Administrator access required'; end if;
  update public.security_alerts
     set resolved=true,resolved_by=auth.uid(),resolved_at=now(),details=details || jsonb_build_object('resolution_note',nullif(left(trim(coalesce(p_note,'')),500),''))
   where id=p_alert_id and resolved=false;
  if not found then return false; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'SECURITY_ALERT_RESOLVED','security_alert',p_alert_id::text,jsonb_build_object('note',nullif(left(trim(coalesce(p_note,'')),500),'')));
  return true;
end $$;
revoke all on function public.resolve_security_alert(uuid,text) from public;
grant execute on function public.resolve_security_alert(uuid,text) to authenticated;

-- Run a deterministic security scan from trusted database state.
-- Alerts are de-duplicated for 24 hours to avoid notification flooding.
create or replace function public.admin_run_security_scan()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_created integer := 0;
  r record;
begin
  if public.current_role() <> 'admin' then raise exception 'Administrator access required'; end if;

  -- Multiple active sessions for one user.
  for r in
    select user_id,count(*) active_sessions
    from public.device_sessions
    where revoked_at is null and last_seen_at >= now()-interval '30 days'
    group by user_id having count(*) >= 3
  loop
    if not exists(select 1 from public.security_alerts where user_id=r.user_id and alert_type='multiple_active_sessions' and resolved=false and created_at>=now()-interval '24 hours') then
      insert into public.security_alerts(user_id,alert_type,severity,title,details)
      values(r.user_id,'multiple_active_sessions','high','Multiple active device sessions',jsonb_build_object('active_sessions',r.active_sessions));
      v_created := v_created + 1;
    end if;
  end loop;

  -- Repeated cancellation/refund requests in a short period.
  for r in
    select requested_by,count(*) request_count
    from public.approvals
    where created_at>=now()-interval '24 hours' and action_type in ('refund','cancel_sale')
    group by requested_by having count(*) >= 5
  loop
    if not exists(select 1 from public.security_alerts where user_id=r.requested_by and alert_type='high_refund_activity' and resolved=false and created_at>=now()-interval '24 hours') then
      insert into public.security_alerts(user_id,alert_type,severity,title,details)
      values(r.requested_by,'high_refund_activity','high','Unusually high refund/cancellation activity',jsonb_build_object('requests_last_24h',r.request_count));
      v_created := v_created + 1;
    end if;
  end loop;

  -- Large cash variances from closed daily reconciliations.
  for r in
    select closed_by,variance,business_date
    from public.daily_reconciliations
    where closed_at>=now()-interval '7 days' and abs(variance)>=1000
  loop
    if not exists(select 1 from public.security_alerts where user_id=r.closed_by and alert_type='cash_variance' and resolved=false and created_at>=now()-interval '24 hours' and details->>'business_date'=r.business_date::text) then
      insert into public.security_alerts(user_id,alert_type,severity,title,details)
      values(r.closed_by,'cash_variance',case when abs(r.variance)>=5000 then 'critical' else 'high' end,'Cash reconciliation variance detected',jsonb_build_object('business_date',r.business_date,'variance',r.variance));
      v_created := v_created + 1;
    end if;
  end loop;

  -- Expired stock still carrying quantity is operationally critical.
  if exists(select 1 from public.batches where quantity>0 and expiry_date<current_date) then
    if not exists(select 1 from public.security_alerts where alert_type='expired_stock' and resolved=false and created_at>=now()-interval '24 hours') then
      insert into public.security_alerts(alert_type,severity,title,details)
      values('expired_stock','critical','Expired stock remains in inventory',jsonb_build_object('batch_count',(select count(*) from public.batches where quantity>0 and expiry_date<current_date)));
      v_created := v_created + 1;
    end if;
  end if;

  return jsonb_build_object('created',v_created,'open_alerts',(select count(*) from public.security_alerts where resolved=false));
end $$;
revoke all on function public.admin_run_security_scan() from public;
grant execute on function public.admin_run_security_scan() to authenticated;

-- Log permission changes at the database boundary as well.
create or replace function public.audit_permission_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='UPDATE' and (old.* is distinct from new.*) then
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(auth.uid(),'SELLER_PERMISSION_CHANGED','seller_permissions',new.user_id::text,
           jsonb_build_object('can_sell',new.can_sell,'can_process_prescriptions',new.can_process_prescriptions,
           'can_request_refund',new.can_request_refund,'can_request_cancellation',new.can_request_cancellation,
           'can_request_stock_adjustment',new.can_request_stock_adjustment,'max_discount_percent',new.max_discount_percent,
           'max_transaction_amount',new.max_transaction_amount));
  end if;
  return new;
end $$;
drop trigger if exists trg_audit_permission_change on public.seller_permissions;
create trigger trg_audit_permission_change after update on public.seller_permissions
for each row execute function public.audit_permission_change();
