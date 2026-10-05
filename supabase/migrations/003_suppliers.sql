create table if not exists public.suppliers(id uuid primary key default gen_random_uuid(),name text not null,phone text,email text,address text,active boolean not null default true,created_at timestamptz not null default now());
alter table public.suppliers enable row level security;
drop policy if exists "staff read suppliers" on public.suppliers; create policy "staff read suppliers" on public.suppliers for select using(public.current_role() in ('admin','seller'));
drop policy if exists "admin manage suppliers" on public.suppliers; create policy "admin manage suppliers" on public.suppliers for all using(public.current_role()='admin') with check(public.current_role()='admin');
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$ begin insert into public.profiles(id,full_name,role,active) values(new.id,coalesce(new.raw_user_meta_data->>'full_name','Seller'),'seller',true) on conflict(id) do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
