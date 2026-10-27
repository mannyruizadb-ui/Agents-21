# PlantBoard — project memory

Real-time operations board for **America's Dust Busters (ADB) / Star Linen Service**, a family-owned commercial floor-mat and linen rental laundry. It is at 222 NE 68th St, Miami FL, and has been operating since 1988.
- Managers estimate the dirty work waiting, in wash loads (or baskets converted to loads).
- The owner orders the work queue from their phone.
- Wall screens in the washroom and finishing room show Now / Next / Later.
- The washroom records loads run per item. The finishing manager records finished goods by unit or by pack + loose.
- The app reconciles loads washed with finished goods per item and shift.
- Every shift ends with an automatic output report.

**Mission:** stop running the plant by phone calls.

**Success, measured against a pre-launch baseline:**
- Phone calls made to give direction: −50% by month 1, −70% by month 3.
- Displays online ≥ 98% of shift time.
- ≥ 90% of shift output logged in the app.

Full context lives in these docs. Read the relevant one before non-trivial work; they are deliberately not `@`-imported, to save context:
- `research/PRD.md` — **source of truth.** Features with IDs (A1…H5), schema DDL (§4), API (§5), non-functional requirements (§6), scope (§7), metrics (§8).
- `research/tech-stack.md` — stack choices, costs, MCP servers, integration pain points.
- `research/viability-analysis.md` — build vs. buy, risks, the washer-data findings (§6).
- `research/americas-dust-busters-dossier.md` — company research. **Contains legal history; never quote it in code, commits or public places.**

## Current state (update this section as work progresses)

- **Built:** research and planning docs only. **No application code exists yet.**
- **In progress:** nothing. The next phase is **Foundation (PRD §9, weeks 1–2):**
  - Supabase migrations from PRD §4
  - RLS policies and pgTAP tests per role
  - seed ADB data
  - auth and invites
  - device pairing
- **Waiting on the owner (do not invent values):**
  1. Diamond Chemical's answer on Accu-Flow CloudView export: API, scheduled CSV/email, or none.
  2. Item list **received** (`research/item-catalog.md`, 26 items). Still TBD there: tablecloth, towel and wipe pack sizes; how sheets are counted; colors; baskets per load; pieces per load.
  3. Shift schedule, including whether any shift crosses midnight.
  4. Which languages to enable beyond EN/ES. Creole can be added later as data plus a translation file. Also: voice-input test results on the real phones (iOS installed-app support and Creole recognition are unconfirmed).
  5. Screen locations: Wi-Fi strength and heat at each spot.
  6. Baseline tally of phone calls per shift.
- **Known debt and caveats:**
  - **PRD is v1.2** (2026-10-27). v1.2 adds accessibility (H6), voice-to-text (H7) and extensible per-user languages (H1). v1.1 revised the measurement model: no scale, wash loads as the unit, manager-only finished-goods entry, no operators/PINs/stations. The DDL was test-loaded in Postgres 16 (23 tables; tenant FKs, shift-overlap exclusion and pack/unit rules verified). RLS policies, triggers and views (§4.5–4.7) exist only as specs.
  - Supabase and Netlify prices in tech-stack.md came partly from third-party write-ups. Re-verify before buying.
  - The Accu-Flow CSV format is unknown. **Do not build the parser (F3) without a real sample file.**

## Tech stack (decided; see tech-stack.md for rationale)

| Layer | Choice | Why |
|---|---|---|
| Frontend | React + TypeScript + Vite SPA, installable **PWA** (vite-plugin-pwa) | One codebase for TVs, phones and tablets. No app store. TVs run a browser. |
| UI libraries | TanStack Query, React Router, Tailwind + shadcn/ui, dnd-kit, react-i18next, React Hook Form + Zod, Recharts, date-fns(-tz) | |
| Backend | **Supabase**: Postgres, Auth, Realtime, Storage, Edge Functions (TS/Deno), pg_cron. **No custom server.** | The work is CRUD, live push and permissions. |
| API | PostgREST + Postgres RPC functions + generated TS types. **No tRPC, no GraphQL.** | Type safety without running a server. |
| Hosting | Netlify (Personal $9) or Cloudflare Pages ($0). **Not Vercel Hobby**: non-commercial use only. | |
| CI/CD | GitHub Actions: typecheck, lint, Vitest, Playwright, `supabase db push`, deploy, nightly `pg_dump` to R2 | |
| Monitoring | Sentry (free) + device heartbeats → Resend email | |
| Budget | ≈ $35/mo at MVP. **Production must be on Supabase Pro**, because Free pauses after 7 idle days and has no backups. | |

**Rejected options and why:**
- React Native: no benefit over a PWA here.
- Next.js: no SEO or server rendering needed.
- Firebase: NoSQL makes the shift reports painful.
- MongoDB Atlas: Device Sync and the Data API reached end of life in Sept 2025.
- Python backend: one language (TypeScript) end to end instead.

## Architecture rules (always apply)

- **Multi-tenant from day one:**
  - Every operational row has `org_id` + `plant_id`.
  - Composite FKs (`(plant_id, org_id)`, `(area_id, plant_id)`, …) make cross-tenant references impossible.
  - **RLS is enabled on every table, deny-by-default.**
- **Roles:** `owner`, `manager`, `lead`, `viewer`, plus the device role `display` (read-only, own area). **There are no operator accounts, PINs or station devices** (removed in PRD v1.1). A shared area tablet signs in as a normal `lead` or `manager`.
- **History is append-only. No hard deletes.**
  - `soil_estimates` are never updated.
  - Finished-goods entries are voided, not deleted.
  - Queue items are cancelled, not deleted.
- **Idempotency:** every client-originated insert carries a client-generated `client_id` UUID.
- **Displays never trust Realtime alone.** They refetch the full feed on connect, reconnect, `online`, `visibilitychange` and every 5 min, and always show the data's age.
- **Time:** store UTC (`timestamptz`). Report by `shift_instance_id` and business date, never calendar date. Plant timezone is `America/New_York`.
- **Measurement model (no scale, so never weights or lbs):**
  - **Wash loads** are the common unit.
  - Estimates are in loads or baskets (`baskets_per_load`, per item).
  - Finished goods are integers: `packs × pack_size_used + loose_pieces` = `pieces`, computed by the DB. Unit items use `loose_pieces` only.
  - Pack size is editable per item and can be overridden per entry. Past entries keep their `pack_size_used`.
  - Reconciliation uses the approximate `pieces_per_load`.
  - All conversion goes through the one SQL function `app.to_loads()`. A missing factor gives `null`, never a guess. Approximate values are flagged and shown with "≈".
- **Washer data:** the source is Diamond Chemical's Accu-Flow / CloudView, the chemical supplier's system on the Milnor washers.
  - Everything goes into one `washer_cycles` table, with `source` and `raw` columns.
  - Manual entry is the MVP path.
  - **Never scrape the CloudView portal.**

## Coding conventions

- TypeScript `strict`. No `any` or `@ts-ignore` without a comment explaining why. Prettier defaults with 2-space indent. ESLint must pass.
- **Naming:**
  - React components: `PascalCase.tsx`.
  - Hooks: `useThing.ts`.
  - Other TS modules: `camelCase.ts`.
  - Routes and Edge Function folders: `kebab-case`.
  - SQL: `snake_case`, plural table names, enums and helpers in schema `app`.
  - Migrations: `supabase migration new <verb_noun>`.
- **All user-facing text goes through react-i18next** (`src/locales/<code>.json`, lazy-loaded). **Languages are data**: the `languages` table plus `*_i18n` jsonb maps. Never hard-code a language list or add per-language columns.
- Zod schemas mirror the DB CHECK constraints. **The database is the final validator; never trust the client.**
- `src/types/database.ts` is **generated. Never hand-edit it.** Regenerate after every migration.
- Commits: short imperative sentence ("Add queue reorder RPC"), matching the existing history. One logical change per commit.
- Detailed rules load automatically from `.claude/rules/` when you touch matching files: database, frontend, edge functions.

## Commands (planned; confirm against package.json once it exists, then fix this list)

```
npm run dev | build | typecheck | lint | test (Vitest) | test:e2e (Playwright)
supabase start                     # local stack (Docker)
supabase db reset                  # re-apply migrations + seed.sql locally
supabase test db                   # pgTAP RLS/permission tests
supabase gen types typescript --local > src/types/database.ts
```

## File map (planned layout; nothing outside research/ exists yet)

```
.claude/CLAUDE.md, .claude/rules/   memory + path-scoped rules
research/                           planning docs (PRD, stack, viability, dossier)
src/app/{control,display,pair}/        the 3 surfaces (routes)
src/features/<epic>/                 estimates, queue, production, washroom, reports, admin
src/lib/                             supabase client, i18n, query client, utils
src/locales/{en,es,ht}.json          translations
src/types/database.ts                GENERATED types
supabase/migrations/                 SQL migrations (timestamped)
supabase/functions/<name>/index.ts   Edge Functions (invite-user, pair-device, …)
supabase/tests/                      pgTAP tests, one file per table/role area
supabase/seed.sql                    ADB org, plant, areas, lines, machines, item types
tests/e2e/                           Playwright specs (display at 1920×1080, control at 390×844)
.github/workflows/                   ci.yml, deploy.yml, backup.yml
```

## External services & environment variables (names only; never commit values)

| Service | Purpose | Variables | Docs |
|---|---|---|---|
| Supabase | DB, auth, realtime, functions, storage | client: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` · functions (auto-injected): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` · CI: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD` | https://supabase.com/docs |
| Netlify | Static hosting | CI: `NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID` | https://docs.netlify.com/ |
| Resend | Alert and invite email (custom SMTP) | `RESEND_API_KEY`, `ALERT_FROM_EMAIL` | https://resend.com/docs |
| Sentry | Frontend errors | `VITE_SENTRY_DSN`, CI: `SENTRY_AUTH_TOKEN` | https://docs.sentry.io/platforms/javascript/guides/react/ |
| Cloudflare R2 | Nightly `pg_dump` backups | `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `BACKUP_DATABASE_URL` | https://developers.cloudflare.com/r2/ |
| Diamond Chemical Accu-Flow | Washer load data (pending) | TBD, e.g. `ACCUFLOW_API_KEY`, only if an API exists | via Diamond rep |
| GitHub | Repo `mannyruizadb-ui/Agents-21`, Actions | — | https://docs.github.com/en/actions |

**Secrets rules:**
- The service role key lives only in Edge Functions and CI.
- Only the publishable key ships to the browser.

**MCP servers in this workspace:** Supabase, Netlify, GitHub (and Gmail).
- Point Supabase MCP at **dev / local**, never at production with write access.

## Who we build for (PRD §2)

- **Owner-Operator Dispatcher (primary):**
  - On the phone all day; wants to set priorities in seconds from anywhere.
  - Fears missed rush orders, unproductive overtime, and software that needs babysitting.
- **Plant / finishing manager:** updates estimates and **is the only person who enters finished goods**, so entry speed is critical (≤ 5 taps, ≤ 10 s). Tired of relaying messages between the owner and the floor.
- **Washroom lead and finishing crew:**
  - Gloves on, hot and noisy room, Spanish or Haitian Creole first.
  - The crew only **reads** the wall displays. The lead may record washer loads until Accu-Flow data arrives.

**UX principles:**
- **Accessible to people with disabilities:** WCAG 2.2 AA; works with VoiceOver/TalkBack, iOS Voice Control/Android Voice Access (visible label = accessible name) and OS dictation in every field; per-user settings (text size, contrast, motion, confirm-before-save). **Voice entries are never saved without confirmation.**
- Each user sees their chosen language (switchable from any screen). ≤ 3 taps for any common action.
- Wall displays readable at 6 m: NOW text ≥ 96 px, nothing below 32 px, contrast ≥ 7:1.
- Entry keypads (finished goods, washer loads) have targets ≥ 56 px; numbers and icons over text.
- Never use color alone; always add an icon and text.
- Show data freshness everywhere.
- Offline must never lose an entry.
- **No per-person data is collected.** Screens and reports show shift and area totals only.

## How to work in this repo

- **The user wants pushback.** Question assumptions, back claims with evidence or sources, and say so when an idea is weak. Don't just agree.
- Before coding a feature:
  - Find its ID in the PRD and implement to its acceptance criteria.
  - If the PRD is silent or conflicts with reality, ask. Don't improvise scope.
- **Ask first when:**
  - a change touches tenancy, RLS, roles or the schema of existing tables;
  - you'd add a dependency or a paid service;
  - it would collect any per-person data, or change what productivity data is shown;
  - a value from the "waiting on the owner" list is needed.
- **Prove before pushing:** typecheck, lint, unit tests, `supabase test db` for any SQL change, and Playwright for display or entry UI.
- **Update the "Current state" section** at the end of any session that changes it.

**Never do without explicit approval:**
- Run migrations or write SQL against **production**.
- Disable RLS, or use the service role key in client code.
- Hard-delete operational data.
- Push to `main`, force-push, or rewrite history. Work on the session's feature branch.
- Add paid services or change hosting plans.
- Add per-person tracking of any kind, or use app data for payroll, pay or discipline.
  - Productivity data is operational, not timekeeping.
  - ADB has a 2013 DOL wage-and-hour finding on record, so this needs HR/legal review.
- Scrape vendor portals, contact vendors, or send email or messages on the owner's behalf.
- Commit secrets, or put dossier legal details anywhere public.
