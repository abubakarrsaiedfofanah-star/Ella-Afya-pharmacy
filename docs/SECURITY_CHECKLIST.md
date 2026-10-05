# Pharmacy Management System — Production Security Checklist

## Authentication
- [ ] Supabase Auth email/password enabled
- [ ] Password policy enforced on registration: 12–128 characters, uppercase, lowercase, number and symbol
- [ ] Password policy verified through direct Edge Function requests, not only browser validation
- [ ] Supabase Auth password policy configured to match for password reset and authenticated password updates
- [ ] Admin TOTP MFA enrolled and required
- [ ] Seller accounts activated by an administrator
- [ ] Supabase Auth rate limits configured and tested for password sign-in and recovery
- [ ] `ALLOWED_ORIGIN` set to the exact production frontend origin for account creation
- [ ] CAPTCHA/risk controls configured if enabled for the project

## Authorization
- [ ] RLS enabled on every application table
- [ ] Admin-only financial reports verified
- [ ] Seller data limited to own operational records
- [ ] Seller permissions tested with direct RPC/API calls
- [ ] Refund/cancellation/stock adjustment approval tested

## Financial integrity
- [ ] Direct browser UPDATE/DELETE on payments/sales/sale_items denied
- [ ] Audit log UPDATE/DELETE denied
- [ ] Migration 020 applied; admin receives audit and notification events for sale/payment and audited business/security activity
- [ ] Admin transaction feed pagination reviewed against records beyond the first page
- [ ] Payment confirmation tested for exact amount
- [ ] M-Pesa callback secret configured (at least 32 random bytes) and forged callback without it rejected
- [ ] M-Pesa decimal-total sale rejected before STK request; duplicate pending request rejected
- [ ] Duplicate M-Pesa callback tested
- [ ] Cash reconciliation variance tested
- [ ] Refund and cancellation flows audited

## Session/device security
- [ ] Device session registration tested
- [ ] Revoked device session rejected
- [ ] Heartbeat updates last_seen_at
- [ ] 20-minute inactivity timeout tested
- [ ] Admin security scan tested

## Data protection
- [ ] Backups configured
- [ ] Restore test completed
- [ ] M-Pesa secrets stored only in server-side secrets
- [ ] Service-role key never shipped to browser
- [ ] Public receipt verification exposes no patient/private data

## Deployment
- [ ] HTTPS enabled
- [ ] Security headers verified
- [ ] Production Supabase project selected
- [ ] Migration 015 applied after 014
- [ ] Final manual permission test completed for both roles
