-- Keep Seller dashboard aggregates in Postgres instead of downloading every
-- sale and payment recorded today into the browser.
create or replace function public.seller_daily_summary(p_seller_id uuid default auth.uid())
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  with bounds as (
    select (current_date::timestamp at time zone 'Africa/Nairobi') day_start,
           ((current_date + 1)::timestamp at time zone 'Africa/Nairobi') day_end
  )
  select jsonb_build_object(
    'sales_count',(select count(*) from public.sales s cross join bounds b where s.seller_id=p_seller_id and s.status in ('paid','refund_requested','refunded') and s.created_at>=b.day_start and s.created_at<b.day_end),
    'sales_total',(select coalesce(sum(s.total_amount),0) from public.sales s cross join bounds b where s.seller_id=p_seller_id and s.status in ('paid','refund_requested','refunded') and s.created_at>=b.day_start and s.created_at<b.day_end),
    'pending_count',(select count(*) from public.sales s cross join bounds b where s.seller_id=p_seller_id and s.status='pending_payment' and s.created_at>=b.day_start and s.created_at<b.day_end),
    'pending_amount',(select coalesce(sum(s.total_amount),0) from public.sales s cross join bounds b where s.seller_id=p_seller_id and s.status='pending_payment' and s.created_at>=b.day_start and s.created_at<b.day_end),
    'payments_total',(select coalesce(sum(p.amount),0) from public.payments p join public.sales s on s.id=p.sale_id cross join bounds b where s.seller_id=p_seller_id and p.status='paid' and p.created_at>=b.day_start and p.created_at<b.day_end),
    'refunded_total',(select coalesce(sum(p.amount),0) from public.payments p join public.sales s on s.id=p.sale_id cross join bounds b where s.seller_id=p_seller_id and p.status='refunded' and p.created_at>=b.day_start and p.created_at<b.day_end),
    'open_shift',(select count(*) from public.shift_sessions where seller_id=p_seller_id and status='open')
  ) where public.current_role() in ('seller','admin') and (public.current_role()='admin' or p_seller_id=auth.uid());
$$;
revoke all on function public.seller_daily_summary(uuid) from public,anon;
grant execute on function public.seller_daily_summary(uuid) to authenticated;
notify pgrst,'reload schema';
