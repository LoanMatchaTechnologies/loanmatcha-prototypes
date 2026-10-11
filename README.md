# LoanMatcha Partners Demo

Includes the original Partners Admin and Loan Channeling Workspace prototypes with synthetic data.

## Deploy to Vercel

1. Create a GitHub repository named `loanmatcha-partners-demo`.
2. Upload all files from this folder directly into the repository root, including `vercel.json`.
3. In Vercel, add a new project and import that repository.
4. Select framework preset **Other**. Leave the build command unset and the output directory unset (the project root).
5. Deploy. The home page links to `/admin` and `/workspace`.

No installation, database, environment variables or API keys are required.

## Demo behavior

- Admin: KYL queue, document checks, simulated AML screening, risk review, activation and audit trail.
- Workspace: fund allocations, borrower review, simulated approvals/releases and portfolio.
- All changes are held in page memory and reset when the page reloads.
- The two demos have independent sample data; changes do not sync between them.
- No login is implemented. The sample account name is a display label.
- No messages, screening requests or money transfers are sent.
- Fonts use Google Fonts; a system font is available as fallback.
- The noindex header discourages indexing but does not restrict access.

## Verification

JavaScript initial rendering, listed routes, sample partner activation and borrower approval/release were checked with a simulated DOM. Full visual browser QA and actual Vercel deployment are pending.
