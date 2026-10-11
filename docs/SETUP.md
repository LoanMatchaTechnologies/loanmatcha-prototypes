# Connect the pilot

1. Create a dedicated Supabase pilot project under the user's account (free plan if available). Owner completes any provider terms/billing prompts. Do not reuse a production borrower database.
2. Apply `supabase/migrations/001_pilot.sql` through the SQL Editor or Supabase migrations. It is a one-time initial migration for an empty pilot project, not a rerunnable seed.
3. In Authentication, disable public signups. Create invited test users for admin, lender, a second lender and partner. Set passwords through the provider's normal secure invite/reset flow, not in source code.
4. In SQL Editor, create organizations and memberships using actual test user UUIDs. Role assignment is owner-only, outside the public app:

```sql
insert into public.lenders(id,name,status) values ('LENDER_ORG_UUID','Demo Bank','pending');
insert into public.partners(id,name) values ('PARTNER_ORG_UUID','Demo Channel');
insert into public.memberships(user_id,role) values ('ADMIN_AUTH_USER_UUID','admin');
insert into public.memberships(user_id,role,lender_id) values ('LENDER_AUTH_USER_UUID','lender','LENDER_ORG_UUID');
insert into public.memberships(user_id,role,partner_id) values ('PARTNER_AUTH_USER_UUID','partner','PARTNER_ORG_UUID');
```

Replace placeholder UUIDs before running. Do not paste authentication passwords/API secrets into chat or commit them.

5. Configure Vercel project `loanmatcha-prototypes` in LM TECH with `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. The latter must be a publishable key or legacy anon key, never a secret/service_role key. Both are intended for browser use; RLS protects data. Use separate pilot databases for Preview/Production if both are enabled.
6. Redeploy the GitHub commit. Open `/pilot`. A configured page shows invited-account sign in; absent configuration shows setup pending.
7. Test: activate lender as admin -> submit allocation as lender -> review + verify sample reference as admin -> partner creates consented synthetic application -> admin qualifies/matches/submits -> lender approves/simulates release -> admin records/reconciles sample payment. Refresh each role to see persisted records.
8. Repeat using the second lender and direct API calls to confirm isolation. Verify DB rows and audit. No real transfers.

## Automated checks

From `tests/pilot`: `npm ci` then `npm test`. Tests use PGlite's PostgreSQL engine with a test-only auth.uid() stub and fake users. They validate SQL execution and RLS/command behavior; they do not establish hosted Supabase provisioning, JWT authentication or concurrency under hosted load. Run a concurrent hosted capacity test before production rollout.

## Dependencies

Runtime: browser fetch, Vercel Node Function, Supabase Auth/PostgREST/PostgreSQL. No runtime npm package is required for the current static pilot. Test-only PGlite is locked under tests/pilot.

Official references: https://supabase.com/docs/guides/database/postgres/row-level-security and https://supabase.com/docs/guides/database/functions .
