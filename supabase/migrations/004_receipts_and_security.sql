-- Public receipt verification contains only minimal non-sensitive transaction data.
create or replace view public.receipt_verification as
select s.sale_number, s.total_amount, s.status, s.created_at
from public.sales s
where s.status in ('paid','refunded','cancelled');

-- Sellers can read only their own shift history; admins can read all.
drop policy if exists "seller own shifts" on public.shift_sessions;
create policy "seller own shifts" on public.shift_sessions for select using(public.current_role()='admin' or (public.current_role()='seller' and seller_id=auth.uid()));

-- Sellers can never mutate audit logs. Audit records are written only by trusted functions/admin operations.
drop policy if exists "seller audit insert" on public.audit_logs;
drop policy if exists "admin audit insert" on public.audit_logs;
create policy "admin audit insert" on public.audit_logs for insert with check(public.current_role()='admin');

-- Prevent clients from directly changing payment status or historical sale state.
drop policy if exists "admin all payments" on public.payments;
create policy "admin read payments" on public.payments for select using(public.current_role()='admin' or (public.current_role()='seller' and exists(select 1 from public.sales s where s.id=sale_id and s.seller_id=auth.uid())));
