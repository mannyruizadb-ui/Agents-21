# Tech Stack Recommendation: ADB Plant Operations App

*Prepared 2026-10-20. Builds on [`viability-analysis.md`](./viability-analysis.md). Pricing was checked against public sources in October 2026. Prices change, so re-verify on the vendor pages linked below before you commit.*

---

## TL;DR

| Layer | Pick | One-line reason |
|---|---|---|
| Frontend | **React + TypeScript + Vite, shipped as a PWA** (not React Native) | One codebase runs on the TVs, phones and station tablets, with no app store |
| Backend | **Supabase (Postgres + Realtime + Auth + Edge Functions in TypeScript)**, no separate server | Almost all the logic is CRUD + live updates + permissions, which Supabase does out of the box |
| API | **Supabase auto-generated REST + Postgres RPC functions**, with generated TS types | No server to run; type safety without tRPC |
| Database | **Supabase Postgres** | Relational data, SQL for productivity reports, built-in realtime |
| Hosting | **Netlify** (Personal $9, or Free), with Cloudflare Pages as the $0 fallback | Static SPA, MCP server already connected |
| CI/CD | **GitHub Actions** + Supabase CLI migrations | Free tier is enough; migrations live in the repo |
| Monitoring | **Sentry** (free) + display heartbeats | Know when a TV goes dark before the crew does |
| **MVP cost** | **≈ $35/month** | Under the $50 budget |

### Three places I'm pushing back on the brief

1. **React Native isn't needed. A PWA is the better choice here.**
   - The TVs run a browser, not an app store.
   - Phones and tablets can install a PWA to the home screen, and iOS has supported web push for installed PWAs since 16.4.
   - React Native adds app-store review, two build pipelines and a separate TV story, and buys nothing this app needs.
   - Revisit only if you later need native hardware access: Bluetooth scales, NFC/RFID readers, barcode scanning beyond the camera.
2. **"1k and 10k users" don't apply to an internal tool.**
   - ADB has maybe 20–50 users and 3–6 screens.
   - Those tiers only make sense if this becomes software you sell to other laundries, which the viability analysis rated a weak bet.
   - I've still priced them (§4), framed as a SaaS scenario.
3. **"Until we have revenue" isn't the right lens either.**
   - An internal tool pays off in owner and supervisor time, not revenue.
   - At ~$35/mo, hosting is a rounding error.
   - The real costs are **display hardware (one-time, ~$1.5–3k)** and **build time**. Budget for those.

---

## 1. Frontend

### Framework: React 18/19 + TypeScript + Vite (single-page app, installable PWA)

- **Why React:** It's your preference, has the largest ecosystem, and Claude Code is strongest in it.
- **Why Vite over Next.js:**
  - There's no SEO need, no public pages and no server rendering.
  - A static SPA is the cheapest, simplest thing to host and is easy to run on a TV browser.
  - Next.js adds a server runtime you'd pay for and maintain without benefit.
- **One app, three surfaces (routes):**
  - `/control` — **owner/manager phone.** Reorder the queue, update estimates, see live output.
  - `/display/:area` — **wall TVs.** Read-only, huge type, auto-reconnect, no interaction.
  - `/station/:id` — **station tablets.** Big buttons to log production, start/stop timers.

### Key libraries

| Need | Library | Docs |
|---|---|---|
| Build tool | Vite | https://vite.dev/guide/ |
| UI framework | React | https://react.dev/ |
| Routing | React Router | https://reactrouter.com/ |
| Server state, caching, offline mutations | TanStack Query | https://tanstack.com/query/latest/docs |
| Small client UI state | Zustand (only if needed) | https://zustand.docs.pmnd.rs/ |
| Database client + realtime | supabase-js | https://supabase.com/docs/reference/javascript/introduction |
| Drag-to-reorder queue on phone | dnd-kit | https://docs.dndkit.com/ |
| Styling / components | Tailwind CSS + shadcn/ui | https://tailwindcss.com/docs · https://ui.shadcn.com/docs |
| Forms + validation | React Hook Form + Zod | https://react-hook-form.com/ · https://zod.dev/ |
| **English / Spanish / Haitian Creole** | react-i18next | https://react.i18next.com/ |
| PWA (install, offline shell, updates) | vite-plugin-pwa | https://vite-pwa-org.netlify.app/ |
| Charts (output / PPOH reports) | Recharts | https://recharts.org/ |
| Dates and shift math | date-fns (+ date-fns-tz) | https://date-fns.org/ |
| Keep TVs awake | Screen Wake Lock API | https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API |

### State management

- **Server state lives in TanStack Query**: queue, estimates, production logs.
- **Supabase Realtime events invalidate or patch the query cache**, so every screen updates within about a second of a change on your phone.
- **Local UI state** (selected tab, modal open) uses plain `useState`; add Zustand only if it gets tangled.
- **No Redux.** This app doesn't have the complexity to justify it.
- **Station tablets get offline-tolerant writes** through TanStack Query's persisted mutations: if Wi-Fi drops mid-shift, entries queue locally and sync later.
- **Displays don't need offline writes.** They need **reconnect-and-refetch** on `online` / `visibilitychange`, plus a visible "last updated" timestamp so stale data is obvious.

### TV hardware note

- Avoid the stock Fire TV browser.
- Use an **Android TV box or mini-PC running a kiosk browser.**
  - [Fully Kiosk Browser](https://www.fully-kiosk.com/) is about a one-time license per device.
  - It auto-launches the URL, reloads on crash, and blocks the screensaver.
- Or use a ChromeOS/Chromium kiosk on a mini-PC.

---

## 2. Backend

### Runtime and framework: Supabase as the backend; TypeScript (Deno) Edge Functions for custom jobs

**Node/TypeScript vs. Python: pick TypeScript.**
- One language end to end: React, Edge Functions, generated DB types.
- First-class Supabase SDK.
- Edge Functions are TypeScript-native.

Python would only win if:
- the washer vendor ships a Python-only SDK, or
- you later do heavy statistical analysis.

Even then, add a small Python job beside the stack rather than switching.

**No standalone Express/Fastify server at MVP.** What needs code beyond CRUD:

| Job | Where it runs |
|---|---|
| Reorder queue atomically, update estimate + write history | Postgres function (RPC) |
| Who can see or edit what | Row Level Security policies |
| Washer data import (API poll, or parse emailed/uploaded CSV) | Edge Function, scheduled with `pg_cron` |
| End-of-shift rollups (pieces/hour, PPOH) | SQL view / materialized view, refreshed by `pg_cron` |
| Alerts ("display offline 10 min", "estimate stale 4h") | `pg_cron` + Edge Function → email |

Docs:
- Edge Functions: https://supabase.com/docs/guides/functions
- pg_cron: https://supabase.com/docs/guides/database/extensions/pg_cron
- Database functions: https://supabase.com/docs/guides/database/functions

### API architecture: Supabase REST (PostgREST) + RPC. Not GraphQL, not tRPC.

- **REST via PostgREST** is generated automatically from the schema. It handles reads and simple writes. https://supabase.com/docs/guides/api
- **RPC (Postgres functions)** handles anything multi-step or that must be atomic (e.g., `move_queue_item`, `update_estimate`).
- **Type safety:** `supabase gen types typescript` produces types from the live schema, which gives most of tRPC's benefit with no server. https://supabase.com/docs/guides/api/rest/generating-types
- **Why not tRPC:** it requires running your own Node server, which defeats the point of Supabase.
- **Why not GraphQL:** Supabase has pg_graphql, but this app's queries are simple and REST + realtime covers them.

### Authentication: Supabase Auth with roles

https://supabase.com/docs/guides/auth

| Who | How they sign in | Permissions (enforced by RLS) |
|---|---|---|
| **Owner / managers** | Email magic link or email + password. Avoid SMS OTP to skip Twilio costs. | Full control of queue and estimates; reports |
| **Wall displays** | One account per screen. Paired once by entering a short code on the TV; long-lived session | **Read-only**, limited to its area |
| **Station tablets** | One shared account per station. The operator taps their name + 4-digit PIN to attribute entries | Insert production logs for that station only |

- Roles live in a `profiles` table and are added to the JWT with a [Custom Access Token Hook](https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook), so RLS can check them cheaply.
- **The operator PIN is for attribution, not security.** Keep it simple.
- Per the viability analysis, **this data must not be your payroll or timekeeping record.**

---

## 3. Database

### Primary: Supabase Postgres

**Why not Firebase or MongoDB Atlas?**

| Option | Verdict |
|---|---|
| **Supabase** | ✅ Relational data fits naturally (items ↔ estimates ↔ queue ↔ output ↔ washer cycles). PPOH and shift reports are plain SQL. Realtime and auth are built in. It's standard Postgres, so you can leave if needed. |
| Firebase (Firestore) | ❌ Excellent realtime, but NoSQL makes cross-entity reporting ("pieces per operator hour by item, by shift, vs. washer loads") painful: denormalization or exports to BigQuery. |
| MongoDB Atlas | ❌ MongoDB **deprecated Atlas Device Sync and the Data API (end of life Sept 2025)**, so there's no first-party realtime-to-browser path. You'd build your own websocket server. |

### Schema approach

**Design decisions:**
- **Normalized tables, append-only history for anything estimated or measured.**
- **Every table carries `plant_id`.** It's cheap now and makes multi-plant or SaaS possible later without a rewrite.
- **Store timestamps in UTC with an explicit `shift_id`**, so the night shift crossing midnight doesn't break the reports.

**Core tables (sketch):**

```
plants(id, name, timezone)
areas(id, plant_id, name)                     -- washroom, finishing/ironer, folding
stations(id, area_id, name, type)             -- ironer 1, folder 2, washer bank
machines(id, area_id, vendor, model, external_id)  -- washers/dryers for integration

item_types(id, plant_id, name, category,      -- "3x5 mat", "white napkin", "chef coat"
           lbs_per_basket, lbs_per_load,      -- UNIT CONVERSIONS: the hard business input
           pieces_per_lb)

soil_estimates(id, item_type_id, qty, unit,   -- append-only; latest row = current estimate
               entered_by, entered_at, note)
  view current_soil_estimates                 -- latest per item_type, with age

queue_items(id, area_id, item_type_id, qty, unit,
            position NUMERIC,                 -- fractional index → cheap drag-reorder
            status, assigned_station_id,
            created_by, updated_at)

shifts(id, plant_id, name, starts_at, ends_at)
operators(id, plant_id, display_name, pin_hash, active)

production_logs(id, station_id, operator_id, shift_id, item_type_id,
                qty, unit, started_at, ended_at, source)   -- 'tablet' | 'manual'

washer_cycles(id, machine_id, program, started_at, ended_at,
              weight_lbs, item_type_id NULL, source, raw JSONB)  -- keep vendor payload

display_heartbeats(display_id, last_seen_at)
audit_log(id, actor, action, entity, entity_id, before JSONB, after JSONB, at)
```

**Derived views:**
- `shift_output` (pieces and lbs per station per shift)
- `ppoh` (pounds per operator hour)
- `soil_vs_processed` (estimate vs. actual)

### Secondary data stores: none at MVP

| Store | Needed? | Why |
|---|---|---|
| Cache (Redis) | No | Data is tiny; Realtime pushes changes; TanStack Query caches on the client |
| Search | No | A few hundred item types; Postgres `ILIKE` / full-text is plenty |
| File storage | Small | **Supabase Storage** for raw washer export files (an audit trail of what was imported). https://supabase.com/docs/guides/storage |
| Analytics warehouse | Not until SaaS | Postgres views handle a single plant for years |

### Backup and migration strategy

**Migrations:**
- Use the **Supabase CLI** with SQL migrations checked into `supabase/migrations/`.
- Develop locally with `supabase start` (Docker), and push with `supabase db push` from CI.
- https://supabase.com/docs/guides/local-development · https://supabase.com/docs/guides/deployment/database-migrations

**Backups, layer 1: Supabase Pro daily backups (7-day retention).** https://supabase.com/docs/guides/platform/backups
- Point-in-time recovery is a paid add-on and **isn't worth it at MVP.**

**Backups, layer 2 (belt and braces): a nightly GitHub Action that runs `pg_dump` to a private bucket.**
- Use Cloudflare R2 (10 GB free) or Backblaze B2. https://developers.cloudflare.com/r2/
- This gives you backups that outlive any vendor problem.
- **Test a restore once** before go-live.

**Don't run production on Supabase Free.**
- Free projects **pause after 7 days of inactivity** and have no daily backups.
- A plant shutdown week or holiday could leave the screens dark on Monday.

---

## 4. Infrastructure and hosting

### Deployment platform: Netlify (recommended) or Cloudflare Pages ($0 alternative). Not Vercel Hobby.

| Option | Verdict |
|---|---|
| **Netlify** | ✅ Static SPA hosting, deploy previews, and an **official MCP server already connected in this workspace**. Credit-based plans: Free (300 credits/mo), **Personal $9 (1,000 credits)**, Pro $20 (unlimited seats). Production deploys cost credits (~15 each), so **Free allows only about 20 prod deploys a month**. Personal is the comfortable choice during active development. https://docs.netlify.com/ · [pricing changelog](https://www.netlify.com/changelog/2026-04-14-pricing-updates-april-2026/) |
| Cloudflare Pages | ✅ Free tier with generous builds and unlimited static bandwidth; a Cloudflare MCP server exists. Pick this if you want $0 hosting. https://developers.cloudflare.com/pages/ |
| Vercel | ❌ **Hobby is non-commercial use only.** An internal tool for ADB counts as commercial, so you'd need Pro at $20/user. https://vercel.com/docs/plans/hobby |

### CI/CD: GitHub Actions

Docs: https://docs.github.com/en/actions

**On every pull request:**
- typecheck, lint, unit tests (Vitest)
- Playwright end-to-end smoke tests against a local Supabase
- Netlify deploy preview

**On merge to `main`:**
1. `supabase db push` (migrations)
2. regenerate types
3. Netlify production deploy

**Nightly:** `pg_dump` backup to R2.

The free tier is about 2,000 Actions minutes a month for private repos, which is plenty.

Docs: Vitest https://vitest.dev/ · Playwright https://playwright.dev/docs/intro

### Monitoring

- **Sentry** (free Developer tier) for frontend errors. https://docs.sentry.io/platforms/javascript/guides/react/
- **Display heartbeats:**
  - Each TV writes `last_seen_at` every 60s.
  - `pg_cron` emails you if a screen goes silent for 10+ minutes, using **Resend** (free tier). https://resend.com/docs

### Estimated monthly costs

| Item | MVP (ADB only, ~30 users, ~5 screens) | "1k users" (SaaS, ~25–40 plants) | "10k users" (SaaS, ~250+ plants) |
|---|---|---|---|
| Supabase | $25 (Pro; includes Micro compute) | ~$40–60 (Pro + Small/Medium compute) | ~$150–300 (larger compute + Realtime connection overage) |
| Netlify | $9 (or $0 on Free / Cloudflare Pages) | $20 (Pro) | $20–60 (Pro + extra credits) |
| Sentry | $0 | $0–26 | $26–80 |
| Email (Resend) | $0 | $0–20 | $20–35 |
| Backups (R2) | $0 | $0–2 | ~$5 |
| Domain | ~$1 | ~$1 | ~$1 |
| **Total** | **≈ $35/mo** | **≈ $60–130/mo** | **≈ $220–480/mo** |
| One-time: TVs + kiosk boxes + mounts/enclosures | ~$1.5–3k | per plant | per plant |

**Caveats on these numbers:**
- They come from third-party pricing write-ups and vendor pages as of mid/late 2026. [Supabase pricing guide](https://www.jetadmin.io/blog/supabase-pricing-2026-guide-to-plans-limits-and-real-world-costs/), [Supabase free-tier limits](https://automationatlas.io/answers/supabase-free-tier-limits-2026/). Confirm at https://supabase.com/pricing and https://www.netlify.com/pricing/.
- I could not confirm the exact Pro Realtime concurrent-connection quota (Free is 200). At ADB scale it's irrelevant. At the 10k tier it's the cost line to watch.
- **The SaaS columns also assume real work not shown here:** multi-tenant RLS hardening, billing (Stripe), onboarding and support.

---

## 5. MCP server availability

| Component | MCP server | Status in this workspace | Docs |
|---|---|---|---|
| **Supabase** | Official Supabase MCP | **Connected** | https://supabase.com/docs/guides/getting-started/mcp |
| **Netlify** | Official Netlify MCP | **Connected** | https://docs.netlify.com/welcome/build-with-ai/netlify-mcp-server/ |
| **GitHub** | Official GitHub MCP | **Connected** (scoped to this repo) | https://github.com/github/github-mcp-server |
| Playwright (browser testing) | Official Microsoft Playwright MCP | Available to add; Chromium is preinstalled in cloud sessions | https://github.com/microsoft/playwright-mcp |
| Sentry | Official Sentry MCP | Available to add | https://docs.sentry.io/product/sentry-mcp/ |
| Cloudflare (if Pages/R2) | Official Cloudflare MCP servers | Available to add | https://developers.cloudflare.com/agents/model-context-protocol/ |
| Gmail | Gmail MCP | **Connected** (dev use only, see below) | — |
| Firebase / MongoDB (not recommended) | Both have official MCP servers | — | https://firebase.google.com/docs/cli/mcp-server · https://github.com/mongodb-js/mongodb-mcp-server |

### What this enables in practice

**Supabase MCP** — Claude Code can:
- create and apply migrations
- run SQL to inspect real data ("what did ironer 2 produce last night?")
- generate TypeScript types
- read logs and the security/performance advisors, which catch missing RLS policies
- deploy Edge Functions

That's the whole backend loop without leaving the session.

**Netlify MCP** — Claude Code can:
- create the site
- set environment variables
- deploy
- read deploy and function logs when something breaks

**GitHub MCP** — Claude Code can:
- open pull requests
- read CI failures and fix them
- respond to review comments

**Playwright MCP** — Claude Code can open the `/display/washroom` view at TV resolution, screenshot it, and verify that live updates actually arrive. That's useful because the displays are the product.

**Sentry MCP** — Claude Code can pull a production error with its stack trace straight into a fix.

**Gmail MCP**
- If the washer vendor's export arrives as an **emailed report**, Claude can read samples during development to build the parser.
- **Production should not depend on your personal Gmail.** Use a dedicated inbound address or upload flow.

**Safety rule:**
- **Point Supabase MCP at a development project and use read-only mode against production.**
- Letting an AI agent run write SQL on the live plant database is how you lose a night's production logs.
- Supabase's MCP docs explicitly recommend this setup.

---

## 6. Integration map

```
                ┌──────────────────────────┐
  Owner phone ──►  /control  (React PWA)   │──┐
  (managers)    └──────────────────────────┘  │  supabase-js
                ┌──────────────────────────┐  │  (REST + RPC + Realtime websocket)
 Station tablet►│  /station/:id (PWA,       │──┤
  (operators)   │  offline-queued writes)   │  │
                └──────────────────────────┘  │
                ┌──────────────────────────┐  │
  Wall TVs ◄────│  /display/:area (kiosk,   │◄─┤  realtime push: queue + estimates
  (kiosk box)   │  read-only, heartbeat)    │  │
                └──────────────────────────┘  ▼
        static files from Netlify CDN   ┌─────────────────────────────────────┐
                                        │ SUPABASE                            │
                                        │  Auth (roles in JWT)                │
                                        │  Postgres + RLS + RPC functions     │
                                        │  Realtime (postgres changes)        │
                                        │  pg_cron ── rollups, staleness,     │
                                        │             heartbeat alerts        │
                                        │  Edge Functions (TS):               │
                                        │    • washer import ◄────────────────┼── Washer vendor:
                                        │    • alert email ──► Resend ──► you │   API poll  OR
                                        │  Storage: raw import files          │   emailed/uploaded CSV
                                        └─────────────────────────────────────┘   OR manual entry
                                                     │
              GitHub Actions ── migrations, deploys, nightly pg_dump ──► Cloudflare R2
              Sentry ◄── frontend errors
```

### Potential integration pain points (and mitigations)

1. **Washer data source: now identified as Diamond Chemical's Accu-Flow / CloudView on Milnor washers (see the viability analysis, §6).**
   - The data comes from the **chemical supplier's dispensing system**, not from Milnor. Diamond controls access.
   - No public API or export documentation was found.
   - Isolate it behind one `washer_cycles` table and one import function, with `source` and `raw` columns.
   - Whether data arrives by API, a scheduled CSV or emailed report, or a manual form, the rest of the app doesn't change.
   - **Build manual entry first.** Automate once Diamond confirms what it can export.
2. **Realtime on TVs over flaky Wi-Fi.**
   - Websockets drop silently.
   - On reconnect, `online`, or `visibilitychange`: refetch everything and show the age of the data.
   - Add heartbeat alerting.
   - Test by unplugging the access point.
3. **Night shift crossing midnight.**
   - Attribute everything by `shift_id`, not calendar date.
   - Store UTC and render in the plant's timezone (America/New_York).
4. **Unit conversions.**
   - Reports are only as good as `lbs_per_basket` / `lbs_per_load` / `pieces_per_lb`.
   - Make them editable with history, and show "estimated" vs. "measured" clearly.
5. **RLS mistakes.**
   - A missing policy can expose or block data.
   - Run the Supabase advisors (via MCP) in CI and before each release, and write a test per role.
6. **Offline writes at stations.**
   - Queued mutations can replay out of order or twice.
   - Give each log a client-generated UUID (idempotent insert).
7. **Kiosk browser quirks.**
   - Sleep timers, memory leaks over multi-day uptime, auto-updates.
   - Use a kiosk browser with scheduled daily reload.
   - Lock the TV's power-saving settings.
8. **Netlify credits on Free.**
   - Frequent deploys burn credits.
   - Use Personal ($9) during build-out, or Cloudflare Pages.
9. **Supabase Free pausing.** Production on Pro from day one (§3).
10. **iOS PWA limitations.** Push works only after "Add to Home Screen" on iOS 16.4+. Fine for managers; just document the install step.

---

## Decision checklist before building

- [ ] Washer brand, model and app confirmed; export method known (drives Edge Function design)
- [ ] Unit conversion table agreed for each item type
- [ ] Screen locations surveyed for Wi-Fi strength and heat/humidity; hardware chosen
- [ ] Languages confirmed (EN / ES / HT)
- [ ] Separate Supabase **dev** and **prod** environments set up, with MCP pointed at dev
  - Dev runs locally (`supabase start`) or in a project under a separate Free org.
  - An extra project inside the Pro org adds compute cost, roughly $10/mo.
- [ ] Hosting chosen: Netlify Personal or Cloudflare Pages
