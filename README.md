# Pharmacy Management System

A modular pharmacy POS, inventory, prescription, purchasing, payments and audit system built with HTML/CSS/JavaScript + Supabase + Vercel.

## Accounts
Only two account types exist:
- **Admin** — inventory, purchasing, reports, sellers, approvals, audits and financial control.
- **Seller** — shifts, prescription intake, POS and receipt history.

There are **no buyer/customer accounts**.

## Architecture
- Frontend: separate HTML/CSS/JS modules per feature.
- Database: Supabase PostgreSQL + RLS.
- Privileged transactions: SECURITY DEFINER PostgreSQL RPCs.
- M-Pesa: Supabase Edge Functions; Daraja credentials never go into browser JavaScript.
- Hosting: Vercel for frontend, Supabase for database/functions.

## New transaction layer
Run migrations in this exact order:

1. `001_initial_schema.sql`
2. `002_business_logic.sql`
3. `003_suppliers.sql`
4. `004_receipts_and_security.sql`
5. `005_pharmacy_transactions.sql`
6. `006_security_hardening.sql`

### Prescription controls
- Medicine-by-medicine prescription quantities.
- Dosage/instruction capture.
- Admin verification/rejection.
- Prescription-required medicines cannot be sold without a verified prescription.
- Prescription quantity balance is checked server-side.
- Dispensing can use a selected unexpired batch or FEFO selection.

### Batch and expiry controls
- Every received stock line has batch number and expiry date.
- Expired batches cannot be dispensed or sold.
- POS can explicitly select a batch or let the server use FEFO (earliest expiry first).
- Stock movements record receives, sales and refunds.

### Purchasing / receiving
Admin uses **Stock Receiving** to record supplier, invoice, batch, expiry, quantity and unit cost. The server transaction updates the batch and inventory together and records a stock movement.

### Approvals
Seller-sensitive actions such as refund/cancellation are requested through the approval workflow. Admin decides them. Approved refunds restore the sold quantity and, where available, the exact sold batch.

### Financial reporting
Admin reports include daily sales, paid amounts, cash, M-Pesa, other payments and refunds for a selected date range.

## M-Pesa / Daraja
The project includes:
- `supabase/functions/mpesa-stk` — server-side STK Push initiation.
- `supabase/functions/payment-callback` — public STK and C2B callback URL (named without restricted Daraja URL keywords).

Safaricom Daraja is asynchronous and uses callback URLs for payment notifications. See the official Daraja documentation before production onboarding.

Required Supabase Edge Function secrets:

```text
MPESA_ENV=sandbox
MPESA_CONSUMER_KEY=...
MPESA_CONSUMER_SECRET=...
MPESA_SHORTCODE=247247
MPESA_PASSKEY=...
MPESA_CALLBACK_URL=https://YOUR-PROJECT.supabase.co/functions/v1/payment-callback
MPESA_CALLBACK_SECRET=<at least 32 random bytes>
MPESA_TRANSACTION_TYPE=CustomerPayBillOnline
```

The STK function appends `MPESA_CALLBACK_SECRET` to `MPESA_CALLBACK_URL`. C2B URL registration uses the same callback secret and separate `stage=validation` and `stage=confirmation` URLs. Register the URLs with `npm run mpesa:register-c2b` after deploying the callback function and setting the Daraja credentials in the shell environment. In production, URL registration is a one-time Daraja operation; verify the shortcode and callback URL before setting `MPESA_PRODUCTION_REGISTRATION_CONFIRMED=YES`. C2B validation is optional and Safaricom must enable it for the PayBill. STK requires whole-shilling totals; decimal sale totals must use another payment method.

Without Daraja API access, the cashier can accept M-PESA by entering the transaction code and amount on the POS after checking the payment in the M-PESA message or statement. The database rejects reused codes and any amount that does not exactly equal the sale total. It records the staff verifier and timestamp, then marks the sale paid, deducts inventory, and audits the action in one transaction. This is a staff attestation; only a Daraja callback can independently verify a receipt with Safaricom.

The POS shows PayBill `247247` and account `427459`. Daraja C2B confirmations can also be received in the admin **Transactions → Unmatched PayBill payments** list and manually matched to a sale when using the callback path. The `verification_source` field distinguishes staff-verified payments from Daraja STK/C2B payments, so API verification can be introduced without changing the payment record model.

Run migrations `021_sale_customer_details.sql` through `024_manual_mpesa_verification.sql` after migration 020. The pharmacy settings page has PayBill and account fields. Daraja callbacks require the deployed `payment-callback` function, Supabase function secrets, and Safaricom URL registration. C2B validation is optional and Safaricom must activate it for the PayBill.

## Frontend configuration
Copy:

`frontend/shared/js/config.example.js` → `frontend/shared/js/config.js`

and fill in the Supabase project URL and public anon key.

For this GitHub repository, set Vercel's **Root Directory** to `.` (the repository root containing `package.json` and `vercel.json`). In **Project Settings → Environment Variables**, add `SUPABASE_URL` using the Supabase Project URL and `SUPABASE_ANON_KEY` using the project's public anon/publishable key. Apply both to Production (and Preview/Development if used), then redeploy. The build injects these public browser settings; the anon key is public by design and all access must remain protected by Supabase RLS. Never add a service-role key to these variables or frontend files. The build intentionally stops when either value is missing or still a placeholder.

Never put `SUPABASE_SERVICE_ROLE_KEY`, M-Pesa consumer secret, passkey or other server secrets in frontend files.

## Deployment
1. Create the Supabase project.
2. Run migrations 001 through 024 in order.
3. Configure Supabase Auth.
4. Create the first admin profile securely.
5. Manual M-PESA receipt verification works without Daraja. Deploy the Edge Functions only when enabling online/API payments.
6. For Daraja API payments, add the M-Pesa secrets in Supabase Edge Function secrets.
7. For Daraja C2B notifications, register the C2B callback URLs using `npm run mpesa:register-c2b`.
8. Deploy the frontend to Vercel.
9. Copy `config.example.js` to `config.js` and set the public Supabase values.

## Security model
The browser is not trusted with stock or money decisions. Seller direct insert policies for sales, sale items, prescriptions and shifts are removed in migration 006. Sensitive transitions go through server-side transactions that validate:
- role and ownership
- stock availability
- batch and expiry
- prescription balance
- payment amount
- M-Pesa receipt/reference
- duplicate callback handling
- audit events

## Current limitations
- Live Daraja credentials and production short-code configuration must be supplied by the pharmacy/business owner.
- Safaricom production onboarding and callback registration are external to this repository.
- The included M-Pesa functions are production-oriented but should first be tested against Daraja sandbox data before go-live.

## Operations Upgrade

Migration `007_operations_upgrade.sql` adds barcode/SKU support, manufacturer and controlled-medicine flags, medicine price history, expense tracking, stock-adjustment approvals, dashboard summaries, seller daily summaries, expiry/out-of-stock alerts, and net cash-flow reporting.

### Recommended production controls
- Use server-side RPCs/Edge Functions for all money and stock state changes.
- Keep Safaricom credentials only in Supabase Edge Function secrets.
- Review expired and near-expiry batches daily.
- Reconcile seller shifts before closing each business day.
- Keep an audit trail for price changes, stock adjustments, refunds and approvals.

## Advanced Admin GUI
The admin control center now provides a responsive management dashboard with live financial visibility: confirmed money received, M-Pesa, cash, other payments, refunds, expenses, net cash flow, 7-day payment trends, seller collections, and operational alerts.

Run migrations in order through `008_admin_financial_dashboard.sql` after the existing migrations. The dashboard uses the `admin_financial_overview()` server-side RPC, so sellers cannot access the administrator financial overview.

## Admin Command Center and POS Refresh
Apply `supabase/migrations/018_admin_command_center_analytics.sql` after migration 017. It exposes seven days of paid sales and gross profit, plus stock-risk counts, through an administrator-only RPC. Gross profit uses the medicine's current purchase price as its cost basis; it is an operational estimate, not historical lot-level margin accounting.

The admin dashboard adds sales/profit/stock-risk chart modes, Ctrl+K page and action search, and a notification drawer. Mobile portals include a bottom navigation bar. The seller POS adds touch quantity controls, explicit payment amount entry, held-sale references, and a printable payment-confirmation preview. All sale creation, M-Pesa initiation, manual payments, and held-sale operations continue to use the existing secured Supabase RPCs and Edge Function.

## Advanced CSV & reconciliation (Migration 009)
Run `supabase/migrations/009_csv_reporting_and_advanced_ops.sql` after migration 008.

Both portals now include role-scoped CSV export:
- Admin: sales, payments, inventory and expenses by date range.
- Seller: own sales, payments, shifts and adjustment requests by date range.
- Seller shift reconciliation calculates expected cash from the current server-side shift.
- CSV generation is client-side only after a role-filtered server RPC returns permitted records.

Additional UI upgrades include mobile navigation, responsive export controls, theme toggle and operational reconciliation tools.

## Authentication and Security Upgrade

- `/auth/` is the secure staff login.
- `/auth/register/` is invitation-controlled staff registration. New self-registered staff remain inactive until an administrator activates them.
- `/auth/reset/` provides password recovery and password update.
- Admins can create and activate seller accounts from `/admin/pages/users/`.
- New migration: `010_security_and_staff_management.sql`.
- Deploy `supabase/functions/admin-create-user` with `SUPABASE_SERVICE_ROLE_KEY` configured only as an Edge Function secret.
- Set a high-entropy `STAFF_REGISTRATION_KEY` Edge Function secret (at least 32 random bytes) if self-registration is desired. Keep it private and rotate it periodically.
- Set `ALLOWED_ORIGIN` to the exact production frontend origin. CORS is browser isolation, not an authorization boundary; registration is independently gated by an active admin session or the registration key.
- Registration requires 12–128 characters with uppercase, lowercase, a number and a symbol; the Edge Function validates this independently of the browser. Configure Supabase Auth to enforce the same policy for password resets and authenticated password updates.
- `admin-create-user` has gateway JWT verification disabled to support key-authorized public registration; the function validates bearer tokens and admin roles itself before privileged account creation.
- Never put a Supabase service-role key in frontend code.

## Advanced Operations Upgrade
Migration `011_advanced_security_operations.sql` adds admin operations analytics (gross profit, COGS, average sale, pending payments, expiry value, top medicines, security activity) and seller operational snapshots. Admin security center supports TOTP authenticator MFA enrollment and password changes. Protected routes use no-store and noindex headers, and authenticated portals enforce a 30-minute idle-session timeout with a warning.

## Production Security & Operations (Migration 012)
- Admin MFA is mandatory before Admin portal access.
- Device/session registrations are tracked and can be revoked by Admin.
- Pharmacy settings control receipt identity, Till/PayBill details and alert thresholds.
- End-of-day reconciliation compares recorded collections, refunds and expenses against counted cash.
- Barcode scanning is supported in POS through keyboard-wedge scanners.
- Receipt pages support browser printing and print-specific CSS.
- Migration 012 is the current production security/operations migration.
- Daily database backup workflow is included at `.github/workflows/daily-backup.yml`; configure the GitHub Actions secret `SUPABASE_DB_URL` with a protected database connection string.

## Advanced controls (migration 013)
Migration `013_advanced_controls_notifications.sql` adds:
- per-seller permissions and transaction/discount limits;
- operational notification center for low stock, expiry, expired stock and pending approvals;
- secure stock-count sessions with system-vs-counted variance;
- server-side permission administration and audit logging.

Run migration 013 after migration 012. Seller permissions are enforced through server-side functions and should be used together with the existing RLS and approval workflow.

## Local GUI preview

The project includes a zero-dependency Node development server. Configure `frontend/shared/js/config.js` with your Supabase URL and public anon key, then run:

```bash
npm run dev
```

Open `http://localhost:3000`. The server maps `/auth`, `/admin`, `/seller`, `/verify`, and `/shared` to the frontend folders so the same URLs used by Vercel work locally.

## Error-fix pass — October 2026
- Fixed missing shared authentication exports used by Admin/Seller pages (`signOut`, password change, MFA helpers).
- Removed duplicate dashboard navigation/theme handlers that conflicted with the shared responsive UI layer.
- Verified all frontend JavaScript files with `node --check`.
- Verified relative JavaScript imports resolve to existing files.
- Verified key application routes return HTTP 200 through the local development server.
- Keep Supabase credentials in `frontend/shared/js/config.js`; never expose service-role or M-Pesa secrets in frontend code.

## Security hardening applied

Migration `015_security_hardening_final.sql` adds the final hardening layer:
- browser clients cannot directly update/delete audit logs, payments, sales or sale items;
- audit logs are append-only;
- security-alert resolution is performed through an audited admin RPC;
- an admin security scan detects multiple active sessions, unusual refund/cancellation activity, large cash variances and expired stock;
- seller-permission changes are audited at the database boundary;
- the frontend maintains a device-session heartbeat and signs out after 20 minutes of inactivity, with a 2-minute warning;
- the login screen adds a short client-side cooldown after repeated failures. Supabase Auth server-side rate limits remain the authoritative brute-force control.

### Production security checklist
1. Run migrations `001` through `015` in order.
2. Enable and configure Supabase Auth email/password security and MFA/TOTP for administrators.
3. Configure Supabase Auth rate limits/CAPTCHA protections in the Supabase dashboard where available.
4. Keep the Supabase service-role key and M-Pesa credentials out of the frontend and Git repository.
5. Configure `SUPABASE_URL` and the public anon key only in `frontend/shared/js/config.js` for the browser client.
6. Configure `SUPABASE_DB_URL` as a GitHub Actions secret for database backups.
7. Test a backup restore before production launch.
8. Review the Admin Security Center regularly and run the security scan after reconciliation.
9. Use HTTPS in production; the Vercel configuration includes HSTS and baseline security headers.

## Advanced Operations Upgrade (Migrations 016–017)

After migrations 001–015, run:

- `016_advanced_pharmacy_operations.sql`
- `017_operational_workflows.sql`

Added capabilities include:
- Purchase orders and supplier ledger/balances
- Purchase-order receiving and stock integration
- Reorder recommendations and inventory intelligence
- Fast/slow/dead-stock analysis
- Expiry exposure monitoring
- Stock locations and medicine shelf mapping foundation
- Seller held sales with resume/delete workflow
- Split cash/other payments for a sale
- Stock quarantine and controlled release/disposal/return workflow
- Recall notices and resolution
- Branch and branch-membership foundation
- Supplier performance analytics
- Advanced Operations, Purchasing and Intelligence admin screens
- Responsive POS hold/resume and split-payment interaction

Production reminders:
- Keep Supabase service-role and M-Pesa secrets server-side.
- Configure Auth rate limits/MFA/CAPTCHA as appropriate in Supabase.
- Test database restore before relying on backups.
- Review pharmacy/legal requirements for prescription and controlled-medicine workflows before production use.
