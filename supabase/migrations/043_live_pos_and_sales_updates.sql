-- Publish only rows that the existing staff/admin RLS policies already allow
-- them to read. Realtime delivers catalog and sale changes without polling.
do $$
declare
  v_table text;
begin
  if not exists(select 1 from pg_publication where pubname='supabase_realtime') then
    raise notice 'supabase_realtime publication is unavailable; live updates remain disabled until it is created.';
    return;
  end if;

  foreach v_table in array array['medicines','inventory','batches','sales'] loop
    if to_regclass(format('public.%I',v_table)) is not null
      and not exists(
        select 1 from pg_publication_tables
        where pubname='supabase_realtime' and schemaname='public' and tablename=v_table
      ) then
      execute format('alter publication supabase_realtime add table public.%I',v_table);
    end if;
  end loop;
end $$;

notify pgrst,'reload schema';
