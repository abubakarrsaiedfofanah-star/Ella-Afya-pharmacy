# Architecture

## Frontend modules
Each major area has its own HTML/CSS/JS entry points:
- auth
- admin
- seller
- inventory
- prescriptions
- POS
- payments
- suppliers
- reports
- security

Shared authentication/database helpers live under `frontend/shared`.

## Backend
Supabase PostgreSQL is the source of truth. RLS separates Admin and Seller capabilities.

Sensitive operations such as payment confirmation, stock deduction, refunds, cancellation, price changes and approval workflows should be implemented as transactional Supabase Edge Functions/RPCs. Never expose the Supabase service-role key in browser JavaScript.

## Accounts
Only `admin` and `seller`. No customer authentication exists.

## Deployment
Vercel hosts the frontend. Supabase hosts database/auth/storage/functions.
