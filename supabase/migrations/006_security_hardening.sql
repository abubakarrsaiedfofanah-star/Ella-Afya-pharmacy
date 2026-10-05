-- Remove direct seller mutation paths that could bypass transactional validation.
drop policy if exists "seller create own sales" on public.sales;
drop policy if exists "seller add sale items" on public.sale_items;
drop policy if exists "staff create prescriptions" on public.prescriptions;
drop policy if exists "staff prescription items insert" on public.prescription_items;
drop policy if exists "seller open shift" on public.shift_sessions;
drop policy if exists "seller request approvals" on public.approvals;

-- Sellers should not be able to mutate payment records directly.
drop policy if exists "seller own payment read" on public.payments;
create policy "seller own payment read" on public.payments for select using(public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid()));

-- Transactional tables have no seller UPDATE/DELETE policies; sensitive state transitions are performed by SECURITY DEFINER functions.

revoke all on function public.request_action(text,uuid,text) from public;
grant execute on function public.request_action(text,uuid,text) to authenticated;
