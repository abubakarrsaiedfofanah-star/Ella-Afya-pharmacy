-- Batch identifiers, quantities and expiry dates are visible to Admin only.
-- Sellers use public inventory counts and the payment RPC allocates stock.
drop policy if exists "staff read batches" on public.batches;

notify pgrst,'reload schema';
