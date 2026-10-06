-- Preserve purchase cost at the point a medicine is sold. Older rows are
-- intentionally left null so reports can identify their estimated costs.
alter table public.sale_items
  add column if not exists purchase_cost numeric(12,2);

-- Keep the new cost snapshot private: Sellers may read their own sale lines,
-- but the REST API must not expose the acquisition cost column.
revoke select on public.sale_items from public,anon,authenticated;
do $$
declare visible_columns text;
begin
  select string_agg(format('%I',a.attname),', ' order by a.attnum)
    into visible_columns
  from pg_attribute a
  where a.attrelid='public.sale_items'::regclass
    and a.attnum>0 and not a.attisdropped and a.attname<>'purchase_cost';
  execute format('grant select (%s) on public.sale_items to authenticated',visible_columns);
end;
$$;

create or replace function public.capture_sale_item_purchase_cost()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if tg_op='INSERT' then
    select m.purchase_price into new.purchase_cost
    from public.medicines m where m.id=new.medicine_id;
    if not found then raise exception 'Medicine unavailable'; end if;
  elsif new.purchase_cost is distinct from old.purchase_cost then
    raise exception 'Sale purchase cost is immutable';
  end if;
  return new;
end;
$$;
revoke all on function public.capture_sale_item_purchase_cost() from public,anon,authenticated;
drop trigger if exists trg_capture_sale_item_purchase_cost on public.sale_items;
create trigger trg_capture_sale_item_purchase_cost
before insert or update of purchase_cost on public.sale_items
for each row execute function public.capture_sale_item_purchase_cost();

-- Replace current catalogue costs with the actual sale-time snapshot when it
-- exists. Legacy sales with no snapshot remain estimates using current cost.
create or replace function public.admin_dashboard_analytics()
returns jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  with days as (
    select d::date report_date from generate_series(current_date-6,current_date,interval '1 day') d
  ), daily as (
    select d.report_date,
      coalesce((select sum(s.total_amount) from public.sales s where s.status='paid' and s.created_at::date=d.report_date),0)::numeric sales,
      coalesce((select sum(si.quantity*coalesce(si.purchase_cost,m.purchase_price))
        from public.sale_items si join public.medicines m on m.id=si.medicine_id
        join public.sales s on s.id=si.sale_id where s.status='paid' and s.created_at::date=d.report_date),0)::numeric cogs
    from days d
  ), stock as (
    select
      (select count(*) from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity<=m.reorder_level and m.active)::bigint low_stock,
      (select count(*) from public.inventory i join public.medicines m on m.id=i.medicine_id where i.quantity=0 and m.active)::bigint out_of_stock,
      (select count(*) from public.batches where quantity>0 and expiry_date between current_date and current_date+30)::bigint expiring_batches,
      (select count(*) from public.batches where quantity>0 and expiry_date<current_date)::bigint expired_batches
  )
  select jsonb_build_object(
    'week',(select coalesce(jsonb_agg(jsonb_build_object('date',report_date,'sales',sales,'gross_profit',sales-cogs) order by report_date),'[]'::jsonb) from daily),
    'stock',(select to_jsonb(stock) from stock)
  ) where public.current_role()='admin';
$$;
revoke all on function public.admin_dashboard_analytics() from public,anon;
grant execute on function public.admin_dashboard_analytics() to authenticated;

create or replace function public.admin_operations_snapshot()
returns jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  with paid_sales as (
    select s.id,s.seller_id,s.total_amount,s.created_at from public.sales s where s.status='paid'
  ), cogs as (
    select coalesce(sum(si.quantity*coalesce(si.purchase_cost,m.purchase_price)),0)::numeric value
    from public.sale_items si join public.medicines m on m.id=si.medicine_id
    join public.sales s on s.id=si.sale_id where s.status='paid' and s.created_at::date=current_date
  ), paid as (
    select coalesce(sum(amount) filter(where status='paid'),0)::numeric value,
      coalesce(sum(amount) filter(where status='pending'),0)::numeric pending,
      coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunded
    from public.payments where created_at::date=current_date
  ), sales as (
    select count(*)::bigint count,coalesce(sum(total_amount),0)::numeric total
    from paid_sales where created_at::date=current_date
  ), expiry as (
    select count(*)::bigint batches,coalesce(sum(b.quantity*m.selling_price),0)::numeric retail_value
    from public.batches b join public.medicines m on m.id=b.medicine_id
    where b.quantity>0 and b.expiry_date between current_date and current_date+30
  ), top_meds as (
    select coalesce(jsonb_agg(jsonb_build_object('name',x.name,'qty',x.qty,'revenue',x.revenue) order by x.revenue desc),'[]'::jsonb) data
    from (select m.name,sum(si.quantity)::bigint qty,coalesce(sum(si.total),0)::numeric revenue
      from public.sale_items si join public.sales s on s.id=si.sale_id join public.medicines m on m.id=si.medicine_id
      where s.status='paid' and s.created_at::date=current_date group by m.name order by revenue desc limit 5) x
  ), security as (
    select (select count(*) from public.profiles where role='seller' and not active)::bigint inactive_sellers,
      (select count(*) from public.audit_logs where created_at>=now()-interval '24 hours')::bigint audit_24h,
      (select count(*) from public.approvals where status='pending')::bigint pending_approvals,
      (select count(*) from public.stock_adjustment_requests where status='pending')::bigint pending_adjustments
  )
  select jsonb_build_object(
    'today',jsonb_build_object('sales_count',(select count from sales),'sales_total',(select total from sales),
      'paid',(select value from paid),'pending_payments',(select pending from paid),'refunded',(select refunded from paid),
      'cogs',(select value from cogs),'gross_profit',(select total from sales)-(select value from cogs),
      'avg_sale',case when (select count from sales)>0 then (select total from sales)/(select count from sales) else 0 end),
    'expiry',jsonb_build_object('batches',(select batches from expiry),'retail_value',(select retail_value from expiry)),
    'top_medicines',(select data from top_meds),'security',(select to_jsonb(security) from security)
  ) where public.current_role()='admin';
$$;
revoke all on function public.admin_operations_snapshot() from public,anon;
grant execute on function public.admin_operations_snapshot() to authenticated;

-- Include staff payroll in all-time net profit and keep estimates visible.
create or replace function public.admin_lifetime_dashboard()
returns jsonb
language sql stable security definer set search_path=public,pg_temp
as $$
  with settled_sales as (
    select id,total_amount,status from public.sales where status in ('paid','refund_requested','refunded')
  ), sales_summary as (
    select count(*)::bigint sales_count,coalesce(sum(total_amount),0)::numeric gross_sales from settled_sales
  ), payment_summary as (
    select coalesce(sum(amount) filter(where status='paid'),0)::numeric net_collections,
      coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunds from public.payments
  ), cost_summary as (
    select coalesce(sum(si.quantity*coalesce(si.purchase_cost,m.purchase_price)),0)::numeric cogs,
      count(distinct m.id) filter(where coalesce(m.purchase_price,0)<=0)::bigint medicines_without_cost,
      count(*) filter(where si.purchase_cost is null)::bigint estimated_cost_lines
    from public.sale_items si join settled_sales s on s.id=si.sale_id join public.medicines m on m.id=si.medicine_id
  ), expense_summary as (
    select coalesce(sum(amount),0)::numeric expenses from public.expenses
  ), payroll_summary as (
    select coalesce(sum(amount),0)::numeric payroll from public.payroll_payments
  ), best_sellers as (
    select coalesce(jsonb_agg(jsonb_build_object('name',x.name,'qty',x.qty,'revenue',x.revenue) order by x.qty desc,x.revenue desc),'[]'::jsonb) items
    from (select m.name,sum(si.quantity)::bigint qty,coalesce(sum(si.total),0)::numeric revenue
      from public.sale_items si join public.sales s on s.id=si.sale_id join public.medicines m on m.id=si.medicine_id
      where s.status in ('paid','refund_requested') group by m.id,m.name order by qty desc,revenue desc limit 5) x
  )
  select jsonb_build_object(
    'lifetime',jsonb_build_object(
      'sales_count',(select sales_count from sales_summary),'gross_sales',(select gross_sales from sales_summary),
      'net_collections',(select net_collections from payment_summary),'refunds',(select refunds from payment_summary),
      'cogs',(select cogs from cost_summary),'expenses',(select expenses from expense_summary),
      'payroll',(select payroll from payroll_summary),
      'gross_profit',(select gross_sales from sales_summary)-(select cogs from cost_summary),
      'net_profit',(select gross_sales from sales_summary)-(select refunds from payment_summary)
        -(select cogs from cost_summary)-(select expenses from expense_summary)-(select payroll from payroll_summary),
      'medicines_without_cost',(select medicines_without_cost from cost_summary),
      'estimated_cost_lines',(select estimated_cost_lines from cost_summary)
    ),'top_medicines',(select items from best_sellers)
  ) where public.current_role()='admin';
$$;
revoke all on function public.admin_lifetime_dashboard() from public,anon;
grant execute on function public.admin_lifetime_dashboard() to authenticated;

notify pgrst,'reload schema';
