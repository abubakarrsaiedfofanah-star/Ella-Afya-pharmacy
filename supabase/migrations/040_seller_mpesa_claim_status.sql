-- Let sellers see the Admin decision for their submitted manual M-Pesa claims.
create or replace function public.seller_manual_mpesa_claim_status(p_sale_ids uuid[])
returns table(sale_id uuid,sale_number text,claim_status text,reviewed_at timestamptz)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null or public.current_role()<>'seller' then raise exception 'Active Sales authorization required'; end if;
  return query
    select c.sale_id,s.sale_number,c.status,c.reviewed_at
    from public.manual_mpesa_claims c join public.sales s on s.id=c.sale_id
    where c.submitted_by=auth.uid() and c.sale_id=any(coalesce(p_sale_ids,'{}'::uuid[]));
end $$;
revoke all on function public.seller_manual_mpesa_claim_status(uuid[]) from public,anon;
grant execute on function public.seller_manual_mpesa_claim_status(uuid[]) to authenticated;

-- Never let a seller bypass the Admin decision and directly mark a typed code paid.
revoke all on function public.verify_manual_mpesa_payment(uuid,numeric,text) from public,anon,authenticated;

notify pgrst,'reload schema';
