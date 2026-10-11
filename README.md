# LoanMatcha demo

Static demo hosted on Vercel. No real financial transactions or backend authentication.

- `/admin`: lender onboarding
- `/workspace`: lender allocations, decisions and simulated releases
- `/workspace?view=admin`: IVPH allocation review, funding verification, candidate matching and submission

Allocation state is saved in localStorage and shared across Admin and Lender tabs in the same browser. It does not sync across devices. Synthetic sample data only.

New allocation lifecycle: lender submission → admin approval → sample funding-reference verification → candidate matching → admin submission → lender decision → simulated release and portfolio. Admin may request changes or decline before approval. Activity records are included.

## Connected pilot foundation

`/pilot` has a separate authenticated shared-database client. Provisioning is pending until Supabase migrations, invited memberships and Vercel env vars are configured. Read [developer handoff](docs/DEVELOPER_HANDOFF.md) and [setup](docs/SETUP.md). Original demo routes remain independent. No real transfers.
