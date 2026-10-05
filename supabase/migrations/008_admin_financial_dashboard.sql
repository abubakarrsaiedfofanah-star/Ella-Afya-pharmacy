-- Advanced admin financial dashboard and management metrics
create or replace function public.admin_financial_overview()
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  with today_sales as (
    select count(*)::bigint count, coalesce(sum(total_amount),0)::numeric total
    from public.sales where status='paid' and created_at::date=current_date
  ),
  today_payments as (
    select
      coalesce(sum(amount) filter(where status='paid'),0)::numeric paid,
      coalesce(sum(amount) filter(where status='paid' and method='cash'),0)::numeric cash,
      coalesce(sum(amount) filter(where status='paid' and method='mpesa'),0)::numeric mpesa,
      coalesce(sum(amount) filter(where status='paid' and method='other'),0)::numeric other,
      coalesce(sum(amount) filter(where status='refunded'),0)::numeric refunded
    from public.payments where created_at::date=current_date
  ),
  today_expenses as (
    select coalesce(sum(amount),0)::numeric total from public.expenses where expense_date=current_date
  ),
  week as (
    select d::date report_date,
      coalesce((select sum(s.total_amount) from public.sales s where s.status='paid' and s.created_at::date=d::date),0)::numeric sales,
      coalesce((select sum(p.amount) from public.payments p where p.status='paid' and p.created_at::date=d::date),0)::numeric payments,
      coalesce((select sum(e.amount) from public.expenses e where e.expense_date=d::date),0)::numeric expenses
    from generate_series(current_date-6,current_date,interval '1 day') d
  ),
  sellers as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'seller_id',x.seller_id,'seller_name',x.seller_name,'sales_count',x.sales_count,'sales_total',x.sales_total
    ) order by x.sales_total desc),'[]'::jsonb) data
    from (
      select s.seller_id, coalesce(p.full_name,'Seller') seller_name, count(*)::bigint sales_count, coalesce(sum(s.total_amount),0)::numeric sales_total
      from public.sales s left join public.profiles p on p.id=s.seller_id
      where s.status='paid' and s.created_at::date=current_date
      group by s.seller_id,p.full_name
    ) x
  )
  select jsonb_build_object(
    'today',jsonb_build_object(
      'sales_count',(select count from today_sales),
      'sales_total',(select total from today_sales),
      'paid',(select paid from today_payments),
      'cash',(select cash from today_payments),
      'mpesa',(select mpesa from today_payments),
      'other',(select other from today_payments),
      'refunded',(select refunded from today_payments),
      'expenses',(select total from today_expenses),
      'net',(select paid from today_payments)-(select refunded from today_payments)-(select total from today_expenses)
    ),
    'week',(select coalesce(jsonb_agg(jsonb_build_object('date',report_date,'sales',sales,'payments',payments,'expenses',expenses) order by report_date),'[]'::jsonb) from week),
    'sellers',(select data from sellers)
  ) where public.current_role()='admin';
$$;

revoke all on function public.admin_financial_overview() from public;
grant execute on function public.admin_financial_overview() to authenticated;
