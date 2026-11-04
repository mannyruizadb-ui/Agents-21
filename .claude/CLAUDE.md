# PlantBoard — project memory

Real-time operations board for **America's Dust Busters (ADB) / Star Linen Service**, a family-owned commercial floor-mat and linen rental laundry. It is at 222 NE 68th St, Miami FL, and has been operating since 1988.
- Managers estimate the dirty work waiting, in wash loads (or baskets converted to loads).
- The owner orders the work queue from their phone.
- Wall screens in the washroom and finishing room show Now / Next / Later.
- The washroom records loads run per item. The finishing manager records finished goods by unit or by pack + loose.
- Each area gets a shift report; washroom ↔ finishing reconciliation is per business day.
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
- `research/agents.md`: subagent architecture. The 6 Foundation agents are live in `.claude/agents/`; others are added per phase. `research/roadmap.md`: milestones, cost guardrails (§1.4).
- `research/americas-dust-busters-dossier.md` — company research. **Contains legal history; never quote it in code, commits or public places.**

## Current state (update this section as work progresses)

- **Sprint Zero DONE (2026-10-30, `research/roadmap.md` §3):** React 19/Router 8/Vite 8 PWA scaffold, magic-link sign-in, EN/ES locales (ES pending AI review), Supabase init, CI (app + migrations/pgTAP + hook tests), Foundation agents and guard hooks. Local Supabase works when Docker is started; CI always proves SQL.
- **Supabase: "Plant Ops Board"** (ref `ypurifebjiivvltbcufx`, us-east-1). The only cloud project (staging until the pilot), schema + seed uploaded 2026-11-02 via the manual deploy-db workflow (staging until the pilot). Never touch "ADB Project" or "Fleet Repair Log".
- **M1 part 1 DONE (2026-11-01): database foundation**
  - 8 migrations in `supabase/migrations/20261101*`: 26 tables, RLS per role, staff PIN RPCs, pairing codes, DST-safe shift generation, `resolve_entry_shift`, reporting views.
  - `supabase/seed.sql`: ADB plant, items, machines, per-area shifts (updated 2026-11-01, see below).
  - **359 pgTAP tests pass**, locally and in CI.
  - Reviews: architect PASS; security-reviewer PASS after a BLOCK (devices and pairing codes are now RPC-only; no trigger oracles). Deviations are recorded in PRD v1.5.
- **PR #2 (M1 part 1) merged to main by the owner (2026-11-01).**
- **Owner answers 2026-11-01 (built, 432 pgTAP tests pass; security-reviewer PASS WITH NOTES):**
  - Staff admin: owner, plus managers the owner grants (`memberships.can_manage_staff`).
  - Production day runs **12:00 → 12:00** (`plants.production_day_start`, `shift_instances.production_date`). Report views now use `production_date`, `loads_run` and `standard_loads`.
  - Washer 6 (160 lb) has `machines.load_factor` 1.19; washers 1–5 (135 lb) are 1.00.
  - Seed: 48 items (tablecloths per size+color, 14 napkin colors, towels and wipes in packs of 50, sheets in packs of 10) and 10 machines. Sign-ups are OFF.
  - **Wash groups BUILT** (`20261101214357_create_wash_groups.sql`):
    - The washroom works by wash group: estimates, queue, washer cycles and the TVs. Finishing counts items. Reconciliation is per production day per group.
    - 33 groups, 73 items in the seed (green + red napkins wash together); every group has a formula (Scraper, City & Brito, red & blue tablecloths, bone into whites, mechanic towels white/color pack 100, bone + chambray napkins together, butcher coats M/L/XL). Mat pieces per standard load: 16 (3×5), 12 (4×6), 9 (3×10), ≈3.5 (5×7), ≈35 (2×3).
    - History is snapshotted: `finished_goods_entries.wash_group_id`, `washer_cycles.load_factor_used`.
    - **480 pgTAP tests pass.** security-reviewer: BLOCK (cross-tenant error-code oracle) → fixed → PASS WITH NOTES. architect: PASS WITH NOTES.
    - PRD v1.6 rewrite still owed: A2, B, C1/C4, D1/D2, F, G1–G3, §4.4–4.9, §5.3.
  - **Formulas, washer assignment, rewash (2026-11-02; 549 pgTAP tests pass; security-reviewer PASS WITH NOTES):**
    - 6 Milnor formulas with cycle minutes. Each wash group maps to one formula (`wash_groups.wash_formula_id`); one formula covers many groups, so Accu-Flow rows alone can't tell which group ran.
    - The owner can assign a queue item to a washer (`queue_items.assigned_machine_id`; the machine must be in the same area).
    - `washer_cycles.is_rewash`: rewash loads are excluded from `standard_loads` and reconciliation and reported as `rewash_loads`.
    - 2026-11-02 follow-up (566 tests; security PASS WITH NOTES): assignment is washers-only (FK on generated `assigned_machine_kind`). Rewash comes from finishing, so it is set on the queue item (`queue_items.is_rewash`). Managers may move loads off broken washers.
    - M2 notes:
      - the start-load RPC copies `is_rewash` and must look up by id + plant + area with a role guard first (no oracle);
      - the UI hides inactive washers.
    - Washroom patterns and the learning plan are in `research/washroom-patterns.md`. Build no rules before about 3 weeks of tap data.
    - Security carry-forward: M2 must `revoke update` on washer_cycles; corrections are void + re-enter.
  - **Owner's existing inventory app "LinenTrack"** (separate Netlify + Supabase app, labeled "Test DB"):
    - Nightly mat and linen counts, par levels, damage and repair, route-count variance. Don't rebuild inventory in PlantBoard; integrate later.
    - Its item list differs from the seed (Scraper, City, Brito mats; red, blue and bone tablecloths; mechanic towels; …). Waiting on the owner.
    - Its login has security issues (PIN is the account password, lockout only in the browser, user list shown before sign-in). Reported to the owner; its repo isn't in this session.
  - Washroom tapping: the washman taps each washer start, on every shift. **Taps carry no name or PIN** (owner 2026-11-02). The tablet is a washroom station, because washmen overlap and per-washman loads would be per-worker output. Manager corrections use name + PIN.
  - The mat roller (20:00 until the mats are done) is in **finishing**. Goals: learn first; pace actuals ship in M2, goals and alerts about 2 weeks after go-live.
  - **Live:**
    - Netlify site `adb-plantboard` (https://adb-plantboard.netlify.app), linked to `main`, env vars set.
    - PR #3 merged 2026-11-02.
    - **Cloud DB uploaded 2026-11-02** (owner said "upload"; workflow run 2): 19 migrations + seed.
      - Verified: 1 plant, 2 areas, 33 wash groups, 73 items, 6 formulas, 10 machines, 8 shifts, 0 users, 0 tables without RLS.
      - Advisors show by-design items only: RLS with no policy on the RPC-only `staff_sessions` and `alert_events`; definer RPCs callable by authenticated users that check roles inside.
  - **Sign-in (owner decision 2026-11-03): username + password; the owner creates every account. No email is ever sent, and Resend/DNS are off the critical path.** Magic links were dropped because they open in Safari, not the installed iOS app.
    - Usernames map to `<u>@accounts.adbheadquarters.com`; a typed value containing "@" is used as-is (the owner signs in with their Gmail).
    - Edge Function `manage-users` (create / reset / deactivate / list / change_own_password).
    - Forced password change is enforced in the DB (`app.password_ok()` gates has_role/has_org_role/can_manage_staff).
    - 592 pgTAP tests pass; security-reviewer PASS WITH NOTES (2 rounds).
    - Cloud: the owner account (`mannyruiz.adb@gmail.com`) has an org-wide owner membership; `profiles.full_name` = 'Manny Ruiz'.
    - **LIVE 2026-11-03:** PR #4 merged; deploy-db run 3 applied the migration (20 in the cloud, latest 20261103202156) and deployed `manage-users` (ACTIVE, verify_jwt). CORS answers only https://adb-plantboard.netlify.app.
    - The owner set the cloud minimum password length to **6**; I recommended 10. The function still enforces ≥ 10 on change_own_password.
    - The null MX record was skipped. `accounts.adbheadquarters.com` is NXDOMAIN with no wildcard (checked), so mail to it can't be delivered.
    - Carry-forward: the Custom Access Token Hook must keep `app_metadata` in the JWT, or the password gate silently passes.
  - **Displays (PRD D1 v1.6):** screens are configurable data (machine or area layout), so TVs can be added anywhere without code. Launch: washroom TV A = washers 1–3, TV B = washers 4–6, finishing 1 TV. No dryer TV (dryers are 5 steps away). NOW + NEXT only. **The washman taps** each washer start, one tap, PIN once per shift.
  - Security notes to carry forward:
    - snapshot `load_factor` per washer cycle;
    - store `production_date` on off-shift rows in the M2 RPCs;
    - invite-user must gate the `can_manage_staff` and owner role grants;
    - duplicate-PIN errors reveal which PINs are in use (accepted for now; PINs are attribution only).
- **Launch scope (owner 2026-11-03): build the whole app and release it all at once; TVs last.**
  - Day-one screens:
    - queue + washer control (start taps from managers' phones);
    - dirty-work estimates;
    - finished goods (name + PIN);
    - reports: shift report, day report, pace screen.
  - In-app setup: items + wash groups, people + entry staff, washers + formulas, shifts.
  - First users are the owner and managers only. The washroom tablet and TVs come later.
  - Build order: server RPCs + pg_cron → setup screens → queue/washer → estimates → finished goods → reports/pace. Merge in PRs; the owner starts using it when all are done.
- **M2 server side BUILT (2026-11-04; 791 pgTAP tests pass; security-reviewer PASS WITH NOTES):** 8 migrations `20261103212038…212055`.
  - Queue RPCs: create / reorder / update / cancel / set_status / get_queue.
  - Washer taps: `start_washer_load` / `undo_washer_load` / `get_washroom_board` (no PIN).
  - Entries: `record_soil_estimate` and `record_finished_goods` (staff session), `void_finished_goods`.
  - Reports: `get_shift_report` / `get_day_report` / `get_wash_group_pace`. Totals only; crew hours removed pending HR/legal review.
  - Direct operational writes revoked. Setup tables are editable through column grants and history guards; shift edits regenerate instances.
  - pg_cron nightly `generate-shift-instances`; after the cloud deploy, check `cron.job`.
  - Follow-ups:
    - L3: revoke anon table grants.
    - L4: column grants on `shift_crew_hours`, `display_messages` and `shift_instances`.
    - Per-plant `client_id` uniqueness.
    - Throttle queue and estimate writes.
    - Record in PRD v1.6 §4.7 the display read of the washer board and the owner/manager-only estimates.
  - Waiting on the owner: who enters estimates, setting `ships_next_morning` in the cloud.
- **Owner answers 2026-11-04 (not built yet):**
  - **The M2 screens were lost.** They were never committed and the session container was reset. The server side survived (`d496d09`). Rebuild them, and push WIP at every checkpoint from now on.
  - PIN reuse: 10 minutes on a phone, "for now".
  - Offline entries: no second PIN when they finally send ("too much stuff"). Proposed: keep the pending entry plus its PIN on the device until it sends, then wipe it (PINs are attribution only). Needs security-reviewer sign-off.
  - "Entered by <name>": the owner wants it, **on the owner's screens only**. Managers and others never see names. Reports never total by person.
  - Managers should see only what they need, not all the owner's data. This is a role/RLS change: get the owner to confirm a screen-by-screen matrix before building.
  - Pilot: for 2–3 weeks the owner is on site nightly and taps washer starts on their phone or the company tablet. Then a tablet at each of the 6 washers (pick the wash group; the formula follows; one green START) plus a removable tablet in finishing. The owner will pay for the tablets.
  - Open: what estimates are, explained to the owner; the meaning of wash group colors, explained; pace with 3 cards.
- **Owner answers 2026-11-04, round 2 (these supersede round 1 where they conflict):**
  - **Pilot target: Monday 2026-11-09.** The owner is tallying baseline calls this week.
  - The owner's father gets his own account with owner access.
  - **No "entered by" names anywhere, the owner's screens included.** Finished goods are entered by the shift manager only, one person per shift.
  - **Estimates ship from day one.** Denise enters them; train while the owner is on site. The owner wants a clear, well-designed screen, not just +/− buttons.
  - Wash group colors: preset them, yes.
  - **Machine breakdowns:** a "machine down" status, shown on the owner boards. Add **automatic notifications** to selected owners and managers (e.g. "Washer 4 down"). The owner asked for text messages; SMS is a paid service, so get approval first.
  - **Washroom TVs stay** (above the washers; the whole crew sees them). Washer tablets come later, maybe iPads with Guided Access. Build the per-washer station screen now so a tablet only has to open its URL.
  - **Queue: managers can only view it; editing is owner-only.** Today the server lets `{owner,manager}` call create/reorder/update/cancel (`20261103212040`), so a migration must restrict them to owner. Open: may managers still move a load off a broken washer (2026-11-02 decision), and who creates rewash items from finishing?
  - **Owner 2026-11-04, round 3 (queue exceptions, containers, a second customer):**
    - Managers may move a load off a washer that broke down.
    - Shift managers may add **rewash** items at the bottom of the queue (wash group + how full a basket/bin). Every other queue edit is owner-only.
    - **Two containers:** *bins* (tall, 5–6 ft; mostly linen) and *baskets* (half the height, longer; mats, sometimes linen). Loads per full container are estimates, not rules:
      - mats per basket 3.5;
      - kitchen towels per basket 2, per bin 2.5;
      - sheets per bin 2;
      - napkins (all colors) per bin 2;
      - tablecloths per bin 2 (confirm).
      - This needs a per-group factor for each container, so it **is** a schema change (`research/estimate-bins.md`).
    - **AA Linen:** a second customer whose volume varies. Kitchen towels, aprons, mats, napkins and tablecloths arrive, always in bins. Not modeled yet; ask the owner whether it must be tracked separately.
  - **Pace screen: deferred (not for Monday), and owner-only when built.** Its layout and the ship-next-morning groups are still undecided.
  - **Alerts: push notifications approved (free Web Push to the installed app), not SMS.**
  - **Estimates by bin fill** (¼ / ½ / ¾ / full, several bins allowed) × loads per full bin per wash group. No schema change: `unit='basket'`, `baskets_per_load = 1/loads_per_bin`. Numbers are pending in `research/estimate-bins.md` (owner examples: mats 5–6, kitchen towels 2–3, linens ≈ 2).
  - Accu-Flow lags about 10 minutes, so it is for cross-checking reports only, not the live source. The owner offered the CloudView login: still **never scrape the portal**; ask for exported files instead.
- **Next, M1 part 2:**
  - invite-user and pair-device/revoke-device Edge Functions (create the edge-engineer agent first);
  - Custom Access Token Hook, pg_cron schedule, languages data migration for the cloud;
  - `suggested_pieces_per_load` and `shift_productivity` views.
- **Then M2:** staff-session write RPCs, then revoke the direct D8 inserts, then the dispatch-loop UI.
- **Process note:** the orchestrator subagent can't wait on its children in this harness, so meta runs pipelines directly (db-engineer → security-reviewer → architect).
- **Waiting on the owner (do not invent values):**
  1. Diamond Chemical's answer on Accu-Flow CloudView export: API, scheduled CSV/email, or none.
  2. Item list **received** (`research/item-catalog.md`). Still TBD there: napkin colors; baskets per load; pieces per load.
  3. Shift schedule **received** (`research/shift-schedule.md`). Business-day rule: owner rejected 14:00→14:00, alternative pending; still open: holidays. Also owner to do: GitHub ruleset on `main`.
  4. Which languages to enable beyond EN/ES. Creole can be added later as data plus a translation file. Also: voice-input test results on the real phones (iOS installed-app support and Creole recognition are unconfirmed).
  5. Screen locations: Wi-Fi strength and heat at each spot.
  6. Baseline tally of phone calls per shift.
- **Known debt and caveats:**
  - **PRD is v1.5**: v1.5 records the M1 implementation decisions; v1.4 entry staff + PIN (A8); v1.3 per-area shifts and day-level reconciliation; v1.2 accessibility/voice/languages; v1.1 the measurement model (wash loads, manager-only entry). See the PRD revision notes.
  - Supabase and Netlify prices in tech-stack.md came partly from third-party write-ups. Re-verify before buying.
  - The Accu-Flow CSV format is unknown. **Do not build the parser (F3) without a real sample file.**

## Tech stack (decided; see tech-stack.md for rationale)

| Layer | Choice | Why |
|---|---|---|
| Frontend | React + TypeScript + Vite SPA, installable **PWA** (vite-plugin-pwa) | One codebase for TVs, phones and tablets. No app store. TVs run a browser. |
| UI libraries | TanStack Query, React Router, Tailwind + shadcn/ui, dnd-kit, react-i18next, React Hook Form + Zod, Recharts, date-fns(-tz) | |
| Backend | **Supabase**: Postgres, Auth, Realtime, Storage, Edge Functions (TS/Deno), pg_cron. **No custom server.** | The work is CRUD, live push and permissions. |
| API | PostgREST + Postgres RPC functions + generated TS types. **No tRPC, no GraphQL.** | Type safety without running a server. |
| Hosting | **Free tier**: Cloudflare Pages or Netlify Free. **Not Vercel Hobby**: non-commercial use only. | Owner: "extremely cheap" |
| CI/CD | GitHub Actions: typecheck, lint, Vitest, Playwright, `supabase db push`, deploy, nightly `pg_dump` to R2 | |
| Monitoring | Sentry (free) + device heartbeats → Resend email | |
| Budget | **≈ $10/mo new spend** (the Plant Ops Board project; the org's Supabase Pro is already paid). Everything else on free tiers. Hardware: owner buys the TVs (≈ $250–350/screen). See roadmap §1.4. | Any new cost = owner decision |

**Rejected (see tech-stack.md):** React Native (a PWA covers it), Next.js (no SSR/SEO need), Firebase (NoSQL makes reports painful), MongoDB Atlas (Device Sync/Data API EOL 2025), Python backend (one language).

## Architecture rules (always apply)

- **Multi-tenant from day one:**
  - Every operational row has `org_id` + `plant_id`.
  - Composite FKs (`(plant_id, org_id)`, `(area_id, plant_id)`, …) make cross-tenant references impossible.
  - **RLS is enabled on every table, deny-by-default.**
- **Roles:** `owner`, `manager`, `lead`, `viewer`, plus the device role `display` (read-only, own area). A shared area tablet signs in as a normal `lead` or `manager`. **Entry staff (PRD A8):** every data entry is confirmed with name + 4-digit PIN (data-entry people only). It's attribution, not security. Shift attribution follows the person's home shift, with a "next shift" option.
- **History is append-only. No hard deletes.**
  - `soil_estimates` are never updated.
  - Finished-goods entries are voided, not deleted.
  - Queue items are cancelled, not deleted.
- **Idempotency:** every client-originated insert carries a client-generated `client_id` UUID.
- **Displays never trust Realtime alone.** They refetch the full feed on connect, reconnect, `online`, `visibilitychange` and every 5 min, and always show the data's age.
- **Time:** store UTC (`timestamptz`). **Shifts are per area.** Report by `shift_instance_id` and business date, never calendar date. Plant timezone is `America/New_York`.
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

## Commands (real, from package.json)

```
npm run dev | build | typecheck | lint | test        # Vitest; Playwright arrives in M2
npm run db:start | db:reset | db:test | db:types     # Supabase CLI devDependency (needs Docker)
npx supabase migration new <verb_noun> </dev/null    # stdin must be closed or it waits
```

## File map (Sprint Zero created src/, supabase/, .github/; feature folders arrive per milestone)

```
.claude/CLAUDE.md, .claude/rules/   memory + path-scoped rules
research/                           planning docs (PRD, stack, viability, dossier)
src/app/{control,display,pair,auth}/   the 3 surfaces + sign-in (routes in src/router.tsx)
src/features/<epic>/                 estimates, queue, production, washroom, reports, admin
src/lib/                             supabase client, env, i18n, localize (query client lives in src/main.tsx)
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
- **No per-worker output data.** Only *who entered* each row is recorded (A8). Reports never total or rank by person; screens show shift and area totals.

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
