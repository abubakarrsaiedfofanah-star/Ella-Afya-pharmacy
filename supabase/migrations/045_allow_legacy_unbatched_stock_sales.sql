-- Keep checkout usable for existing inventory while batch details are entered
-- later. Inventory remains the sale limit; known unexpired batches are reduced
-- first, and any remainder is explicitly recorded as legacy unbatched stock.
-- No expiry date or batch identity is invented.
do $migration$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public.add_manual_sale_payment(uuid,text,numeric,text,numeric)'::regprocedure
  ) into v_definition;
  v_definition:=replace(v_definition,chr(13)||chr(10),chr(10));

  v_old := $old$  v_medicine_name text;$old$;
  v_new := $new$  v_medicine_name text;
  v_inventory_available integer;$new$;
  if position(v_old in v_definition)=0 then
    raise exception 'Payment function signature differs from migration 044; no changes applied';
  end if;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old := $old$      if v_available<r.quantity then
        raise exception 'Insufficient unexpired batch stock for % (available %, requested %). Payment was not recorded.',
          coalesce(v_medicine_name,r.medicine_id::text),v_available,r.quantity;
      end if;$old$;
  v_new := $new$      select quantity into v_inventory_available
      from public.inventory where medicine_id=r.medicine_id for update;
      if coalesce(v_inventory_available,0)<r.quantity then
        raise exception 'Insufficient inventory stock for % (available %, requested %). Payment was not recorded.',
          coalesce(v_medicine_name,r.medicine_id::text),coalesce(v_inventory_available,0),r.quantity;
      end if;$new$;
  if position(v_old in v_definition)=0 then
    raise exception 'Expected batch stock validation was not found; no changes applied';
  end if;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old := $old$      if v_remaining_qty>0 then
        raise exception 'Batch stock changed while completing payment. Payment was not recorded.';
      end if;$old$;
  v_new := $new$      if v_remaining_qty>0 then
        insert into public.stock_movements(
          medicine_id,batch_id,movement_type,quantity,reference_type,reference_id,actor_id,details
        ) values(
          r.medicine_id,null,'sale',-v_remaining_qty,'sale',s.id,auth.uid(),
          jsonb_build_object(
            'legacy_unbatched_stock',true,
            'payment_method',p_method,
            'verification_source',case when p_method='mpesa' then 'seller_attested' else 'manual' end
          )
        );
        v_remaining_qty:=0;
      end if;$new$;
  if position(v_old in v_definition)=0 then
    raise exception 'Expected batch allocation guard was not found; no changes applied';
  end if;
  v_definition:=replace(v_definition,v_old,v_new);

  execute v_definition;
end
$migration$;

notify pgrst,'reload schema';
