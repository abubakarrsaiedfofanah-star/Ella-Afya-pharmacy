create or replace function public.admin_dashboard_analytics()
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  with days as (
    select d::date report_date
    from generate_series(current_date-6,current_date,interval '1 day') d
  ),
  daily as (
    select d.report_date,
      coalesce((select sum(s.total_amount) from public.sales s where s.status='paid' and s.created_at::date=d.report_date),0)::numeric sales,
      coalesce((select sum(si.quantity*m.purchase_price) from public.sale_items si join public.medicines m on m.id=si.medicine_id join public.sales s on s.id=si.sale_id where s.status='paid' and s.created_at::date=d.report_date),0)::numeric cogs
    from days d
  ),
  stock as (
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

revoke all on function public.admin_dashboard_analytics() from public;
grant execute on function public.admin_dashboard_analytics() to authenticated;