-- Security and staff management hardening
create or replace function public.set_seller_active(p_user_id uuid,p_active boolean)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if public.current_role() <> 'admin' then raise exception 'Admin access required'; end if;
 if not exists(select 1 from public.profiles where id=p_user_id and role='seller') then raise exception 'Seller account not found'; end if;
 update public.profiles set active=p_active where id=p_user_id;
 insert into public.audit_logs(actor_id,action,entity,entity_id,details) values(auth.uid(),case when p_active then 'seller_activated' else 'seller_disabled' end,'profiles',p_user_id,jsonb_build_object('active',p_active));
 return true;
end $$;
revoke all on function public.set_seller_active(uuid,boolean) from public;
grant execute on function public.set_seller_active(uuid,boolean) to authenticated;

-- Prevent sellers from changing their own role or activation state through direct profile updates.
drop policy if exists "profiles own update" on public.profiles;
create policy "profiles own limited update" on public.profiles for update using(id=auth.uid() and public.current_role()='seller') with check(id=auth.uid() and role='seller' and active=true);
