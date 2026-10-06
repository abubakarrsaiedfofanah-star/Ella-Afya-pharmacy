-- Keep archived medicines and their history while allowing a fresh active row
-- to reuse the same barcode after the catalogue has been cleared.
drop index if exists public.uq_medicines_barcode;

create unique index uq_medicines_barcode
  on public.medicines(barcode)
  where active and barcode is not null and trim(barcode)<>'';
