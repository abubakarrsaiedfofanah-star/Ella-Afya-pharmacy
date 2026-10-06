-- Allow Admin to save a pay-period calculation before disbursing installments.
create or replace function public.admin_calculate_staff_payroll(
  p_staff_id uuid,p_pay_month date,p_base_pay numeric,p_additions numeric default 0,p_deductions numeric default 0
)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_period public.payroll_periods%rowtype;
  v_paid numeric(12,2):=0;
  v_staff text;
  v_saved boolean:=false;
  v_currency text:='KES';
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_staff_id is null or p_pay_month is null or extract(day from p_pay_month)<>1 then raise exception 'Choose a valid staff member and pay month'; end if;
  select full_name into v_staff from public.profiles where id=p_staff_id and role='seller';
  if not found then raise exception 'Choose a valid staff account'; end if;
  if p_base_pay is null or p_additions is null or p_deductions is null or least(p_base_pay,p_additions,p_deductions)<0 then raise exception 'Pay amounts cannot be negative'; end if;
  if p_base_pay<>round(p_base_pay,2) or p_additions<>round(p_additions,2) or p_deductions<>round(p_deductions,2) then raise exception 'Pay amounts must use two decimal places'; end if;
  if p_base_pay+p_additions<p_deductions then raise exception 'Deductions cannot exceed gross pay'; end if;
  select * into v_period from public.payroll_periods where staff_id=p_staff_id and pay_month=p_pay_month;
  if found then
    v_saved:=true;
    select coalesce(sum(amount),0)::numeric(12,2) into v_paid from public.payroll_payments where payroll_period_id=v_period.id;
  else
    select coalesce(currency,'KES') into v_currency from public.pharmacy_settings where id=true;
    v_period.staff_name:=v_staff; v_period.base_pay:=p_base_pay; v_period.additions:=p_additions; v_period.deductions:=p_deductions;
    v_period.gross_pay:=p_base_pay+p_additions; v_period.net_pay:=p_base_pay+p_additions-p_deductions;
    v_period.pay_month:=p_pay_month; v_period.currency_code:=coalesce(v_currency,'KES');
  end if;
  return jsonb_build_object('period_id',v_period.id,'period_saved',v_saved,'staff_name',v_period.staff_name,'pay_month',v_period.pay_month,
    'base_pay',v_period.base_pay,'additions',v_period.additions,'deductions',v_period.deductions,'gross_pay',v_period.gross_pay,
    'net_pay',v_period.net_pay,'paid',v_paid,'balance',greatest(v_period.net_pay-v_paid,0),'currency_code',coalesce(v_period.currency_code,'KES'));
end $$;
revoke all on function public.admin_calculate_staff_payroll(uuid,date,numeric,numeric,numeric) from public,anon;
grant execute on function public.admin_calculate_staff_payroll(uuid,date,numeric,numeric,numeric) to authenticated;

create or replace function public.admin_save_staff_payroll_period(
  p_staff_id uuid,p_pay_month date,p_base_pay numeric,p_additions numeric default 0,p_deductions numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_period public.payroll_periods%rowtype;
  v_staff text;
  v_currency text;
  v_paid numeric(12,2):=0;
  v_action text;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  if p_staff_id is null or p_pay_month is null or extract(day from p_pay_month)<>1 then raise exception 'Choose a valid staff member and pay month'; end if;
  select full_name into v_staff from public.profiles where id=p_staff_id and role='seller';
  if not found then raise exception 'Choose a valid staff account'; end if;
  if p_base_pay is null or p_additions is null or p_deductions is null or least(p_base_pay,p_additions,p_deductions)<0 then raise exception 'Pay amounts cannot be negative'; end if;
  if p_base_pay<>round(p_base_pay,2) or p_additions<>round(p_additions,2) or p_deductions<>round(p_deductions,2) then raise exception 'Pay amounts must use two decimal places'; end if;
  if p_base_pay+p_additions<p_deductions then raise exception 'Deductions cannot exceed gross pay'; end if;
  select coalesce(currency,'KES') into v_currency from public.pharmacy_settings where id=true;

  insert into public.payroll_periods(staff_id,staff_name,pay_month,base_pay,additions,deductions,currency_code)
  values(p_staff_id,v_staff,p_pay_month,p_base_pay,p_additions,p_deductions,coalesce(v_currency,'KES'))
  on conflict(staff_id,pay_month) do nothing;
  select * into v_period from public.payroll_periods where staff_id=p_staff_id and pay_month=p_pay_month for update;
  select coalesce(sum(amount),0)::numeric(12,2) into v_paid from public.payroll_payments where payroll_period_id=v_period.id;

  if v_paid>0 and (v_period.base_pay<>p_base_pay or v_period.additions<>p_additions or v_period.deductions<>p_deductions) then
    raise exception 'This pay calculation is locked because a payment has already been recorded';
  end if;
  if v_period.base_pay=p_base_pay and v_period.additions=p_additions and v_period.deductions=p_deductions then
    v_action:='STAFF_PAYROLL_PERIOD_CONFIRMED';
  else
    update public.payroll_periods set staff_name=v_staff,base_pay=p_base_pay,additions=p_additions,deductions=p_deductions where id=v_period.id returning * into v_period;
    v_action:='STAFF_PAYROLL_PERIOD_UPDATED';
  end if;
  perform public.audit(v_action,'payroll_period',v_period.id::text,jsonb_build_object('staff_id',p_staff_id,'pay_month',p_pay_month,'gross_pay',v_period.gross_pay,'net_pay',v_period.net_pay,'amount_paid',v_paid,'balance',v_period.net_pay-v_paid));
  return jsonb_build_object('period_id',v_period.id,'period_saved',true,'staff_name',v_period.staff_name,'pay_month',v_period.pay_month,
    'base_pay',v_period.base_pay,'additions',v_period.additions,'deductions',v_period.deductions,'gross_pay',v_period.gross_pay,
    'net_pay',v_period.net_pay,'paid',v_paid,'balance',greatest(v_period.net_pay-v_paid,0),'currency_code',v_period.currency_code);
end $$;
revoke all on function public.admin_save_staff_payroll_period(uuid,date,numeric,numeric,numeric) from public,anon;
grant execute on function public.admin_save_staff_payroll_period(uuid,date,numeric,numeric,numeric) to authenticated;

-- Reprinted installment receipts show the balance immediately after that
-- payment, rather than a later payment made in the same pay period.
create or replace function public.admin_payroll_history(
  p_month date default null,p_staff_id uuid default null,p_search text default null,p_limit integer default 100,p_offset integer default 0
)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_search text:=trim(coalesce(p_search,'')); v_result jsonb;
begin
  if auth.uid() is null or public.current_role()<>'admin' then raise exception 'Admin authorization required'; end if;
  with filtered as (
    select pp.*,pr.base_pay,pr.additions,pr.deductions,pr.gross_pay,pr.net_pay,pr.id as period_id,
      (select coalesce(sum(paid.amount),0) from public.payroll_payments paid
       where paid.payroll_period_id=pr.id and (paid.paid_at<pp.paid_at or (paid.paid_at=pp.paid_at and paid.id<=pp.id)))::numeric(12,2) period_paid
    from public.payroll_payments pp left join public.payroll_periods pr on pr.id=pp.payroll_period_id
    where (p_month is null or pp.pay_month=p_month) and (p_staff_id is null or pp.staff_id=p_staff_id)
      and (v_search='' or concat_ws(' ',pp.payroll_number,pp.staff_name,pp.payment_reference,pp.notes) ilike '%'||replace(replace(v_search,'%','\%'),'_','\_')||'%')
  ), page_rows as (
    select * from filtered order by pay_month desc,paid_at desc,id desc
    limit greatest(1,least(coalesce(p_limit,100),100)) offset greatest(0,least(coalesce(p_offset,0),1000000))
  )
  select jsonb_build_object(
    'rows',(select coalesce(jsonb_agg(to_jsonb(r) order by r.pay_month desc,r.paid_at desc,r.id desc),'[]'::jsonb) from page_rows r),
    'payment_count',(select count(*) from filtered),'staff_count',(select count(distinct staff_id) from filtered),
    'totals_by_currency',(select coalesce(jsonb_agg(jsonb_build_object('currency',c.currency_code,'amount',c.total) order by c.currency_code),'[]'::jsonb)
      from (select currency_code,sum(amount)::numeric(12,2) total from filtered group by currency_code) c)
  ) into v_result;
  return v_result;
end $$;
revoke all on function public.admin_payroll_history(date,uuid,text,integer,integer) from public,anon;
grant execute on function public.admin_payroll_history(date,uuid,text,integer,integer) to authenticated;

notify pgrst,'reload schema';
