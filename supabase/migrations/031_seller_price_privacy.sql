-- Hide medicine purchase costs from seller database sessions. Admins read
-- purchase costs through the protected catalogue view instead.
revoke select on public.medicines from anon, authenticated;

do $$
declare
  visible_columns text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into visible_columns
  from pg_attribute a
  where a.attrelid = 'public.medicines'::regclass
    and a.attnum > 0
    and not a.attisdropped
    and a.attname <> 'purchase_price';

  execute format('grant select (%s) on public.medicines to authenticated', visible_columns);
end;
$$;

create or replace view public.admin_medicine_purchase_catalog
with (security_barrier = true)
as
select id, name, active, purchase_price
from public.medicines
where public.current_role() = 'admin';

revoke all on public.admin_medicine_purchase_catalog from public, anon;
grant select on public.admin_medicine_purchase_catalog to authenticated;
