-- Keep purchase costs private while allowing Admin catalogue writes through
-- narrow, role-checked functions instead of direct REST table upserts.
create or replace function public.admin_import_medicines(p_medicines jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_item jsonb;
  v_id uuid;
  v_ids jsonb:='[]'::jsonb;
begin
  if auth.uid() is null or public.current_role()<>'admin' then
    raise exception 'Admin authorization required';
  end if;
  if p_medicines is null or jsonb_typeof(p_medicines) is distinct from 'array' then
    raise exception 'Medicine import must be an array';
  end if;
  if jsonb_array_length(p_medicines)>5000 then
    raise exception 'Import up to 5,000 medicines at a time';
  end if;

  for v_item in select value from jsonb_array_elements(p_medicines)
  loop
    if nullif(btrim(v_item->>'name'),'') is null then
      raise exception 'Every imported medicine needs a name';
    end if;

    v_id:=coalesce(nullif(v_item->>'id','')::uuid,gen_random_uuid());
    insert into public.medicines(
      id,name,generic_name,brand,manufacturer,barcode,strength,dosage_form,unit,
      purchase_price,selling_price,min_stock,reorder_level,prescription_required,
      controlled_medicine,active
    ) values (
      v_id,btrim(v_item->>'name'),nullif(v_item->>'generic_name',''),
      nullif(v_item->>'brand',''),nullif(v_item->>'manufacturer',''),
      nullif(v_item->>'barcode',''),nullif(v_item->>'strength',''),
      nullif(v_item->>'dosage_form',''),coalesce(nullif(v_item->>'unit',''),'unit'),
      coalesce(nullif(v_item->>'purchase_price','')::numeric,0),
      coalesce(nullif(v_item->>'selling_price','')::numeric,0),
      coalesce(nullif(v_item->>'min_stock','')::integer,0),
      coalesce(nullif(v_item->>'reorder_level','')::integer,0),
      coalesce(nullif(v_item->>'prescription_required','')::boolean,false),
      coalesce(nullif(v_item->>'controlled_medicine','')::boolean,false),true
    )
    on conflict(id) do update set
      name=excluded.name,generic_name=excluded.generic_name,brand=excluded.brand,
      manufacturer=excluded.manufacturer,barcode=excluded.barcode,
      strength=excluded.strength,dosage_form=excluded.dosage_form,unit=excluded.unit,
      purchase_price=excluded.purchase_price,selling_price=excluded.selling_price,
      min_stock=excluded.min_stock,reorder_level=excluded.reorder_level,
      prescription_required=excluded.prescription_required,
      controlled_medicine=excluded.controlled_medicine,active=true,updated_at=now();

    v_ids:=v_ids||jsonb_build_array(v_id);
  end loop;
  return v_ids;
end;
$$;

create or replace function public.admin_update_medicine_prices(
  p_medicine_id uuid,p_purchase_price numeric,p_selling_price numeric
)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or public.current_role()<>'admin' then
    raise exception 'Admin authorization required';
  end if;
  if p_purchase_price is null or p_purchase_price<0
     or p_selling_price is null or p_selling_price<0 then
    raise exception 'Prices must be valid non-negative amounts';
  end if;
  update public.medicines
    set purchase_price=p_purchase_price,selling_price=p_selling_price,updated_at=now()
    where id=p_medicine_id;
  if not found then raise exception 'Medicine not found'; end if;
end;
$$;

revoke all on function public.admin_import_medicines(jsonb) from public,anon;
grant execute on function public.admin_import_medicines(jsonb) to authenticated;
revoke all on function public.admin_update_medicine_prices(uuid,numeric,numeric) from public,anon;
grant execute on function public.admin_update_medicine_prices(uuid,numeric,numeric) to authenticated;

notify pgrst,'reload schema';
