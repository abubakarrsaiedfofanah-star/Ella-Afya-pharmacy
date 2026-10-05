-- Add a role sentinel so authorization checks never receive NULL for an
-- unauthenticated, missing-profile, or inactive account.
-- Run this migration separately and let it commit before applying 027.
alter type public.user_role add value if not exists 'inactive';
