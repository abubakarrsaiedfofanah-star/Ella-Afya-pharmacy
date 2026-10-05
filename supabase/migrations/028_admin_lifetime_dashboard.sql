-- Admin-only lifetime collections, estimated profitability and best sellers.
-- Profit estimates use current medicine purchase prices and recorded expenses.
create or replace function public.admin_lifetime_dashboard()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  with settled_sales as (
    select id,total_amount,status
    from public.sales
    where status in ('paid','refund_requested','refunded')
  ),
  sales_summary as (
    select count(*)::bigint sales_count,
           coalesce(sum(total_amount),0)::numeric gross_sales
    from settled_sales
  ),
  payment_summary as (
    select coalesce(sum(amount) filter(where status='paid'),0)::numeric net_collections,
           coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunds
    from public.payments
  ),
  cost_summary as (
    select coalesce(sum(si.quantity*m.purchase_price),0)::numeric cogs,
           count(distinct m.id) filter(where coalesce(m.purchase_price,0)<=0)::bigint medicines_without_cost
    from public.sale_items si
    join settled_sales s on s.id=si.sale_id
    join public.medicines m on m.id=si.medicine_id
  ),
  expense_summary as (
    select coalesce(sum(amount),0)::numeric expenses
    from public.expenses
  ),
  best_sellers as (
    select coalesce(jsonb_agg(jsonb_build_object('name',x.name,'qty',x.qty,'revenue',x.revenue)
                              order by x.qty desc,x.revenue desc),'[]'::jsonb) items
    from (
      select m.name,sum(si.quantity)::bigint qty,coalesce(sum(si.total),0)::numeric revenue
      from public.sale_items si
      join public.sales s on s.id=si.sale_id
      join public.medicines m on m.id=si.medicine_id
      where s.status in ('paid','refund_requested')
      group by m.id,m.name
      order by qty desc,revenue desc
      limit 5
    ) x
  )
  select jsonb_build_object(
    'lifetime',jsonb_build_object(
      'sales_count',(select sales_count from sales_summary),
      'gross_sales',(select gross_sales from sales_summary),
      'net_collections',(select net_collections from payment_summary),
      'refunds',(select refunds from payment_summary),
      'cogs',(select cogs from cost_summary),
      'expenses',(select expenses from expense_summary),
      'gross_profit',(select gross_sales from sales_summary)-(select cogs from cost_summary),
      'net_profit',(select gross_sales from sales_summary)-(select refunds from payment_summary)
        -(select cogs from cost_summary)-(select expenses from expense_summary),
      'medicines_without_cost',(select medicines_without_cost from cost_summary)
    ),
    'top_medicines',(select items from best_sellers)
  )
  where public.current_role()='admin';
$$;

revoke all on function public.admin_lifetime_dashboard() from public,anon;
grant execute on function public.admin_lifetime_dashboard() to authenticated;
