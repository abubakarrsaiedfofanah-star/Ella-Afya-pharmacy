-- Advanced security + management analytics

create or replace function public.admin_operations_snapshot()
returns jsonb
language sql stable security definer set search_path=public
as $$
  with paid_sales as (
    select s.id,s.seller_id,s.total_amount,s.created_at
    from public.sales s where s.status='paid'
  ),
  cogs as (
    select coalesce(sum(si.quantity * m.purchase_price),0)::numeric value
    from public.sale_items si join public.medicines m on m.id=si.medicine_id
    join public.sales s on s.id=si.sale_id where s.status='paid' and s.created_at::date=current_date
  ),
  paid as (
    select coalesce(sum(amount) filter(where status='paid'),0)::numeric value,
           coalesce(sum(amount) filter(where status='pending'),0)::numeric pending,
           coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunded
    from public.payments where created_at::date=current_date
  ),
  sales as (
    select count(*)::bigint count,coalesce(sum(total_amount),0)::numeric total
    from paid_sales where created_at::date=current_date
  ),
  expiry as (
    select count(*)::bigint batches,coalesce(sum(b.quantity*m.selling_price),0)::numeric retail_value
    from public.batches b join public.medicines m on m.id=b.medicine_id
    where b.quantity>0 and b.expiry_date between current_date and current_date+30
  ),
  top_meds as (
    select coalesce(jsonb_agg(jsonb_build_object('name',x.name,'qty',x.qty,'revenue',x.revenue) order by x.revenue desc),'[]'::jsonb) data
    from (select m.name,sum(si.quantity)::bigint qty,coalesce(sum(si.total),0)::numeric revenue
          from public.sale_items si join public.sales s on s.id=si.sale_id join public.medicines m on m.id=si.medicine_id
          where s.status='paid' and s.created_at::date=current_date group by m.name order by revenue desc limit 5) x
  ),
  security as (
    select
      (select count(*) from public.profiles where role='seller' and not active)::bigint inactive_sellers,
      (select count(*) from public.audit_logs where created_at >= now()-interval '24 hours')::bigint audit_24h,
      (select count(*) from public.approvals where status='pending')::bigint pending_approvals,
      (select count(*) from public.stock_adjustment_requests where status='pending')::bigint pending_adjustments
  )
  select jsonb_build_object(
    'today',jsonb_build_object(
      'sales_count',(select count from sales),'sales_total',(select total from sales),
      'paid',(select value from paid),'pending_payments',(select pending from paid),'refunded',(select refunded from paid),
      'cogs',(select value from cogs),'gross_profit',(select total from sales)-(select value from cogs),
      'avg_sale',case when (select count from sales)>0 then (select total from sales)/(select count from sales) else 0 end
    ),
    'expiry',jsonb_build_object('batches',(select batches from expiry),'retail_value',(select retail_value from expiry)),
    'top_medicines',(select data from top_meds),
    'security',(select to_jsonb(security) from security)
  ) where public.current_role()='admin';
$$;

create or replace function public.seller_operations_snapshot()
returns jsonb
language sql stable security definer set search_path=public
as $$
  with me as (select auth.uid() uid),
  sales as (
    select count(*)::bigint count,coalesce(sum(total_amount),0)::numeric total
    from public.sales where seller_id=(select uid from me) and status='paid' and created_at::date=current_date
  ),
  payments as (
    select coalesce(sum(p.amount) filter(where p.status='paid' and p.method='cash'),0)::numeric cash,
           coalesce(sum(p.amount) filter(where p.status='paid' and p.method='mpesa'),0)::numeric mpesa,
           coalesce(sum(p.amount) filter(where p.status='paid' and p.method='other'),0)::numeric other
    from public.payments p join public.sales s on s.id=p.sale_id
    where s.seller_id=(select uid from me) and p.created_at::date=current_date
  ),
  shift as (
    select opening_cash,closing_cash,status,opened_at,closed_at from public.shift_sessions
    where seller_id=(select uid from me) order by opened_at desc limit 1
  )
  select jsonb_build_object(
    'sales_count',(select count from sales),'sales_total',(select total from sales),
    'cash',(select cash from payments),'mpesa',(select mpesa from payments),'other',(select other from payments),
    'shift',(select coalesce(row_to_json(shift),'{}'::json) from shift),
    'pending_own_approvals',(select count(*) from public.approvals where requested_by=(select uid from me) and status='pending'),
    'pending_own_adjustments',(select count(*) from public.stock_adjustment_requests where requested_by=(select uid from me) and status='pending')
  ) where public.current_role()='seller';
$$;

revoke all on function public.admin_operations_snapshot() from public;
revoke all on function public.seller_operations_snapshot() from public;
grant execute on function public.admin_operations_snapshot() to authenticated;
grant execute on function public.seller_operations_snapshot() to authenticated;

-- Prevent anonymous or client-side exposure of operational analytics.
