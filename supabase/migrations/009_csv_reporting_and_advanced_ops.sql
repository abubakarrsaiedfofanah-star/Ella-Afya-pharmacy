-- Advanced reporting/export layer for Admin and Seller portals.
-- All exports are generated from server-side, role-filtered queries.

create or replace function public.admin_csv_export(p_from date default current_date, p_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_from date := coalesce(p_from,current_date);
  v_to date := coalesce(p_to,current_date);
  v_result jsonb;
begin
  if public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if v_from>v_to then raise exception 'Start date cannot be after end date'; end if;
  if v_to-v_from>366 then raise exception 'Export range cannot exceed 366 days'; end if;

  select jsonb_build_object(
    'sales', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number, p.full_name seller, s.total_amount, s.status, s.created_at,
             coalesce(sum(pay.amount) filter(where pay.status='paid'),0)::numeric paid_amount
      from public.sales s
      left join public.profiles p on p.id=s.seller_id
      left join public.payments pay on pay.sale_id=s.id
      where s.created_at::date between v_from and v_to
      group by s.id,s.sale_number,p.full_name,s.total_amount,s.status,s.created_at
    ) x),'[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number,pay.method,pay.amount,pay.status,pay.provider_reference,pay.created_at,p.full_name seller
      from public.payments pay join public.sales s on s.id=pay.sale_id left join public.profiles p on p.id=s.seller_id
      where pay.created_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'inventory', coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from (
      select m.name,m.generic_name,m.brand,m.barcode,m.strength,m.dosage_form,i.quantity,m.selling_price,m.purchase_price,m.active
      from public.medicines m join public.inventory i on i.medicine_id=m.id
    ) x),'[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(x) order by x.expense_date desc,x.created_at desc) from (
      select expense_number,category,description,amount,payment_method,reference,expense_date,created_at
      from public.expenses where expense_date between v_from and v_to
    ) x),'[]'::jsonb),
    'from',v_from,'to',v_to
  ) into v_result;
  return v_result;
end $$;

create or replace function public.seller_csv_export(p_from date default current_date, p_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_from date := coalesce(p_from,current_date);
  v_to date := coalesce(p_to,current_date);
  v_result jsonb;
begin
  if public.current_role()<>'seller' then raise exception 'Seller authorization required'; end if;
  if v_from>v_to then raise exception 'Start date cannot be after end date'; end if;
  if v_to-v_from>366 then raise exception 'Export range cannot exceed 366 days'; end if;

  select jsonb_build_object(
    'sales', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number,s.total_amount,s.status,s.created_at,
             coalesce(sum(pay.amount) filter(where pay.status='paid'),0)::numeric paid_amount
      from public.sales s left join public.payments pay on pay.sale_id=s.id
      where s.seller_id=auth.uid() and s.created_at::date between v_from and v_to
      group by s.id,s.sale_number,s.total_amount,s.status,s.created_at
    ) x),'[]'::jsonb),
    'payments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select s.sale_number,pay.method,pay.amount,pay.status,pay.provider_reference,pay.created_at
      from public.payments pay join public.sales s on s.id=pay.sale_id
      where s.seller_id=auth.uid() and pay.created_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(x) order by x.opened_at desc) from (
      select opening_cash,closing_cash,status,opened_at,closed_at
      from public.shift_sessions where seller_id=auth.uid() and opened_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select m.name,a.quantity_change,a.reason,a.status,a.created_at,a.decided_at
      from public.stock_adjustment_requests a join public.medicines m on m.id=a.medicine_id
      where a.requested_by=auth.uid() and a.created_at::date between v_from and v_to
    ) x),'[]'::jsonb),
    'from',v_from,'to',v_to
  ) into v_result;
  return v_result;
end $$;

create or replace function public.seller_reconciliation(p_shift_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_id uuid:=p_shift_id; v_result jsonb;
begin
  if public.current_role()<>'seller' then raise exception 'Seller authorization required'; end if;
  if v_id is null then select id into v_id from public.shift_sessions where seller_id=auth.uid() and status='open' order by opened_at desc limit 1; end if;
  if v_id is null then return jsonb_build_object('shift',null,'sales_total',0,'cash',0,'mpesa',0,'other',0,'expected_cash',0); end if;
  select jsonb_build_object(
    'shift',to_jsonb(sh),
    'sales_total',coalesce((select sum(s.total_amount) from public.sales s where s.seller_id=auth.uid() and s.status='paid' and s.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'cash',coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='cash' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'mpesa',coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='mpesa' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'other',coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='other' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0),
    'expected_cash',sh.opening_cash+coalesce((select sum(p.amount) from public.payments p join public.sales s on s.id=p.sale_id where s.seller_id=auth.uid() and p.status='paid' and p.method='cash' and p.created_at between sh.opened_at and coalesce(sh.closed_at,now())),0)
  ) into v_result from public.shift_sessions sh where sh.id=v_id and sh.seller_id=auth.uid();
  return coalesce(v_result,jsonb_build_object('shift',null,'sales_total',0,'cash',0,'mpesa',0,'other',0,'expected_cash',0));
end $$;

revoke all on function public.admin_csv_export(date,date) from public;
revoke all on function public.seller_csv_export(date,date) from public;
revoke all on function public.seller_reconciliation(uuid) from public;
grant execute on function public.admin_csv_export(date,date) to authenticated;
grant execute on function public.seller_csv_export(date,date) to authenticated;
grant execute on function public.seller_reconciliation(uuid) to authenticated;
