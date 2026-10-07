-- Publish payment inserts/updates so Admin sales tables refresh as soon as a
-- seller records a payment, including partial payments on an open sale.
do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
    and to_regclass('public.payments') is not null
    and not exists(
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='payments'
    ) then
    alter publication supabase_realtime add table public.payments;
  end if;
end $$;

notify pgrst,'reload schema';
