# Build Roadmap: PlantBoard MVP

*Prepared 2026-10-30 in the architect role, from [`PRD.md`](./PRD.md) v1.2, [`skills.md`](./skills.md), [`agents.md`](./agents.md), [`tech-stack.md`](./tech-stack.md), [`viability-analysis.md`](./viability-analysis.md) and [`.claude/CLAUDE.md`](../.claude/CLAUDE.md).*

**Bottom line:**
- **About 10 weeks to full MVP launch, with a real-floor pilot in week 6.**
- That's 3 weeks longer than the PRD §9 estimate (7 weeks). The PRD figure predates v1.1/v1.2, which added manager-only pack/loose entry, extensible languages, accessibility and voice. It also predates the pilot, which this roadmap treats as mandatory.
- **The order changes too:** the dispatch loop (phone → wall screen) ships to the floor **before** output capture. Dispatch attacks the north-star metric (phone calls), and capture is blocked on owner inputs that haven't arrived.

---

## 1. MVP definition

### 1.1 The absolute smallest thing that delivers value

> **"Dispatch slice":** the owner updates estimates and reorders the queue on a phone, and the washroom and finishing TVs show Now / Next / Later within 2 seconds, in Spanish and English.

- **Why this slice.** The north-star metric is *direction phone calls per shift* (PRD §8). Every call today exists because priorities live in the owner's head. This slice moves them onto a screen.
- **What it needs:** estimates (B1–B2), the queue (C1–C4), displays (D1–D2), pairing (A7), auth and setup (A1, A3, A4, A6), and EN/ES (H1).
- **What it doesn't need:** packs, conversions, washer data or reports.
- **It can go on the floor in week 6** (Milestone 3), even if pack sizes and Diamond's answer are still missing.

### 1.2 The MVP (what "launch" means)

| Area | In MVP | PRD IDs |
|---|---|---|
| Setup & access | Org/plant seed; item types with counting units, packs, conversions; areas/lines/machines; invites & roles; shifts (DST-safe); display pairing | A1, A2, A3, A4, A6, A7 |
| Soil estimates | Enter/update in loads or baskets; history & freshness | B1, B2 |
| Queue | Create, drag-reorder, RUSH, start/done/cancel | C1–C4 |
| Displays | Now/Next/Later; connection & data-age states | D1, D2 |
| Finished goods | Manager entry by unit or packs + loose; running totals; offline; void/correct | E1–E4 |
| Washroom | Manual load entry; formula → item mapping | F1, F2 |
| Reporting | Shift report with reconciliation (loads washed vs. ≈ loads finished) | G1 |
| Platform | EN + ES per user; audit log; PWA; analytics events + "+1 call" tally; accessibility baseline (WCAG 2.2 AA, screen readers, voice control, OS dictation) | H1, H2, H4, H5, H6, H7 (P0 part only) |

### 1.3 Explicitly deferred to post-MVP

| Deferred | Why | PRD |
|---|---|---|
| Stale-estimate and display-offline **email** alerts, notifications | The in-screen freshness and offline states (B2, D2) cover the pilot; email is polish | B3, D4, H3 |
| Suggested queue, queue templates | Owner ordering *is* the value; automation comes after trust | C5, C6 |
| Broadcast messages, display scoreboard | Nice to have; not needed to stop phone calls | D3, D5 |
| Crew hours, productivity, calibration, CSV export, trends | Need weeks of real data first | A5, G2–G5 |
| Batch timing, downtime | P2 | E5, E6 |
| Accu-Flow CSV import and automated feed | **Blocked on Diamond Chemical**; manual entry works meanwhile | F3, F4 |
| In-app voice entry and spoken display announcements | P1/P2. **OS dictation already works in every field at MVP.** iOS installed-app support is unconfirmed | H7 (P1, P2) |
| Haitian Creole | Extensible design ships at MVP; the Creole content waits for translation + AI review + owner go-ahead | H1 |
| Owner MFA | P1 security hardening (magic link at MVP) | §6.2 #5 |
| Org/plant admin UI, SaaS, billing | Not a goal (viability analysis) | §7 |

---

## 2. Milestones

| # | Milestone | Duration | Weeks | Gate |
|---|---|---|---|---|
| M0 | Sprint Zero: tooling, environments, agents | 1 week | 1 | Owner approvals for dev project and hosting |
| M1 | Foundation: data, access, pairing | 2 weeks | 2–3 | Shift schedule (for seed) |
| M2 | Dispatch loop | 2 weeks | 4–5 | Hardware ordered |
| M3 | Washroom pilot on the real floor | 1 week | 6 | Prod approved; baseline tally done |
| M4 | Capture & reconciliation | 2 weeks | 7–8 | **Pack sizes from owner** |
| M5 | Launch hardening & go-live | 1–2 weeks | 9–10 | All launch checklist items |

### M0: Sprint Zero (tooling, environments, agents)

- **Duration:** 1 week.
- **Deliverables:** §3 checklist complete:
  - repo scaffold;
  - CI green;
  - local Supabase stack running migrations + pgTAP;
  - RLS guard test;
  - auth scaffolding;
  - Foundation agents + hooks created;
  - dev project and hosting provisioned (after owner approval).
- **Agent assignments:**

  | Deliverable | Owner agent | Reviewer |
  |---|---|---|
  | App scaffold, lint/format/test tooling | frontend-engineer (meta in M0) | architect |
  | Local Supabase, init migration, RLS guard test | db-engineer | security-reviewer |
  | CI workflow, session-start hook | release-engineer | architect |
  | Auth scaffolding (client, magic-link screen, guard) | frontend-engineer + edge-engineer | security-reviewer |
  | Agents, protocol rule, hooks | meta | architect |
  | Docs and memory | docs-keeper | — |

- **Dependencies:** none for local work. **Owner approval** to create the Supabase dev project and the Netlify (or Cloudflare) site.
- **Success criteria:**
  - `npm run lint && npm run typecheck && npm test && npm run build` pass locally and in CI.
  - `supabase db reset && supabase test db` passes locally and in CI.
  - A new session lists the Foundation agents (`/agents`).
  - The production guard hook blocks `supabase db push`.

### M1: Foundation (data, access, pairing)

- **Duration:** 2 weeks.
- **Deliverables:**
  1. All PRD §4 tables, enums, triggers (§4.5), the `app.to_loads()` function and views (§4.6), RLS (§4.7) and indexes (§4.8), as migrations.
  2. pgTAP tests asserting the §4.7 matrix for owner, manager, lead, viewer, display and anon, **including cross-tenant denial**, plus CHECK rejections (pack/unit rules, no weight units, languages).
  3. Shift-instance generation with **DST tests** (spring-forward and fall-back night shifts).
  4. Seed from `research/item-catalog.md`. TBD values stay `null`; nothing is invented.
  5. Auth:
     - magic-link login;
     - `invite-user` / `revoke-user` Edge Functions;
     - Custom Access Token Hook (claims);
     - Resend custom SMTP on the dev project.
  6. Display pairing:
     - `create_pairing_code` RPC;
     - `pair-device` / `revoke-device` functions with rate limiting;
     - the `/pair` screen.
  7. Generated types committed.
- **Agent assignments:**

  | Deliverable | Owner agent |
  |---|---|
  | 1–4, 7 | db-engineer |
  | 5–6 (server side) | edge-engineer |
  | 5–6 (client side) | frontend-engineer, display-engineer |
  | Every RLS/RPC/function change | security-reviewer |
  | Pairing e2e, DST cases | qa-engineer |
  | Plan + final review | architect |

- **Dependencies:**
  - M0 complete.
  - **Shift schedule from owner** for the real seed. Tests use fixtures meanwhile.
  - Resend account (free tier), with owner approval.
- **Success criteria:**
  - 100% of public tables have RLS: the guard test passes.
  - Every §4.7 cell has a passing pgTAP assertion.
  - Supabase advisors show 0 security errors.
  - A TV browser pairs in ≤ 2 minutes and survives a reboot.
  - Revocation takes effect in ≤ 60 s.
  - The owner receives an invite and signs in.

### M2: Dispatch loop

- **Duration:** 2 weeks.
- **Deliverables:**
  1. **Control app:**
     - estimates (B1–B2) with load equivalents and freshness;
     - queue create, reorder (drag + buttons), RUSH, status (C1–C4);
     - version-conflict handling;
     - language switcher and accessibility settings (H1, H6);
     - "+1 call" tally;
     - `app_events` (H5).
  2. **Wall display:**
     - Now/Next/Later (D1) with 1–2 languages;
     - reconnect, stale and offline states (D2);
     - wake lock;
     - nightly reload.
  3. Realtime sync with refetch on reconnect.
  4. PWA install and update flow (H4).
  5. EN + ES locale files, AI-reviewed. Creole infrastructure ready, content off.
  6. Accessibility baseline: axe clean, 200% text, VoiceOver/TalkBack and Voice Control/Voice Access pass on the control app.
- **Agent assignments:**

  | Deliverable | Owner agent |
  |---|---|
  | 1, 3, 4 | frontend-engineer |
  | 2 | display-engineer |
  | 5, 6 | a11y-i18n-specialist |
  | Supporting RPC tweaks | db-engineer |
  | Two-browser latency e2e, 72 h soak | qa-engineer |
  | Review | architect |

- **Dependencies:**
  - M1 (schema, auth, pairing).
  - **TV hardware ordered** (2–3 screens + Android kiosk boxes). Shipping time overlaps M2.
- **Success criteria:**
  - **Phone → display p95 ≤ 2 s** across 100 changes (measured).
  - The display recovers from a 10-minute Wi-Fi outage without manual action.
  - 72-hour soak with no memory growth over 50 MB.
  - All C1–C4, B1–B2 and D1–D2 acceptance criteria are tested.
  - 0 serious or critical axe violations.

### M3: Washroom pilot (real floor, real shifts)

- **Duration:** 1 week of live use (installation on day 1).
- **Deliverables:**
  1. **Production environment.** Owner-approved paid items: Supabase Pro (~$25/mo) and Netlify Personal (~$9) or Cloudflare Pages ($0).
  2. First `/release` to production.
  3. Displays installed: washroom + finishing, kiosk runbook followed, paired.
  4. Owner and managers onboarded; Spanish quick-reference card.
  5. Daily check-in during the pilot: what confused people, what broke.
  6. **Pilot report:** calls per shift vs. baseline, display uptime, latency samples, crew feedback (the 3-question pulse), and the fix list for M4/M5.
- **Agent assignments:**

  | Deliverable | Owner agent |
  |---|---|
  | 1–3 | release-engineer (owner types `/release`) |
  | Gates the release | security-reviewer |
  | 4 | docs-keeper + a11y-i18n-specialist (cards) |
  | 6 | plant-data-analyst (first real data) + meta |
  | Fixes | builder agents via orchestrator |

- **Dependencies:**
  - M2.
  - **Baseline phone-call tally ≥ 1 week before the pilot** (PRD §8.2 launch gate).
  - Wi-Fi survey at the screen spots.
  - Hardware delivered.
  - Owner approval of paid hosting.
- **Success criteria (PRD §8.3 launch-week targets):**
  - Direction calls down ≥ 30% vs. baseline.
  - Displays online ≥ 95% of shift time.
  - p95 latency ≤ 3 s on plant Wi-Fi.
  - 0 lost entries.
  - Crew pulse "screen is clear" ≥ 60%.
- **If calls drop < 25%,** stop feature work and fix process or adoption first (PRD §8.4).

### M4: Capture & reconciliation

- **Duration:** 2 weeks.
- **Deliverables:**
  1. **Item setup UI (A2):** counting unit, pack size, baskets per load, pieces per load (approximate).
  2. **Finished-goods entry (E1–E4):**
     - packs + loose with live total, or unit count;
     - per-entry pack override;
     - loose ≥ pack warning;
     - 10 s Undo (adjustable);
     - running totals;
     - end-of-shift review;
     - offline queue with zero loss and zero duplicates;
     - void/correct.
  3. **Washer load entry (F1)** and formula → item mapping (F2).
  4. **Shift report (G1):** washroom loads, finished goods, reconciliation with "≈" and "no conversion yet", queue and soil start/end.
  5. "Shift complete" confirmation event.
- **Agent assignments:**

  | Deliverable | Owner agent |
  |---|---|
  | 2–3 server side (`record_finished_goods`, `void_finished_goods`, `upsert_washer_quick_totals`, `get_shift_report`, views) | db-engineer |
  | Review | security-reviewer |
  | 1–5 UI | frontend-engineer |
  | Strings, keypad a11y | a11y-i18n-specialist |
  | Offline e2e, entry-time measurement | qa-engineer |
  | Review | architect |

- **Dependencies:**
  - M2.
  - **Pack sizes** for tablecloths, kitchen towels and wipes, and **how sheets are counted** (from owner).
  - Pilot learnings from M3.
- **Success criteria:**
  - Median finished-goods entry ≤ 10 s, ≤ 5 taps (measured in the pilot).
  - 0 lost or duplicated entries in an offline test (500 entries, 8 h).
  - The report reconciles a known fixture shift exactly.
  - All E1–E4, F1–F2, G1 and A2 acceptance criteria are tested.

### M5: Launch hardening & go-live

- **Duration:** 1–2 weeks.
- **Deliverables:**
  - The §5 launch checklist, fully checked;
  - restore drill passed;
  - crew data notice approved and delivered;
  - runbooks;
  - monitoring live;
  - full launch on all shifts;
  - month-1 success review scheduled.
- **Agent assignments:**

  | Deliverable | Owner agent |
  |---|---|
  | Checklist, release, backups, monitoring | release-engineer |
  | Full audit | security-reviewer |
  | Device pass | a11y-i18n-specialist |
  | Performance and regression suite | qa-engineer |
  | Runbooks, CLAUDE.md | docs-keeper |
  | Final architecture review | architect |
  | Owner sign-off | meta |

- **Dependencies:** M4; HR/legal review of the crew notice.
- **Success criteria:** every §5 item checked with evidence; owner sign-off; first week at full launch meets the PRD §8.3 launch-week targets.

### Critical path

```
owner approvals (dev project, hosting) ─► M0 ─► M1 ─► M2 ─► M3 pilot ─► M4 ─► M5
                     shift schedule ──────┘       ▲      ▲            ▲
          hardware order (start in M1) ───────────┘      │            │
          baseline call tally (≥1 week before M3) ───────┘            │
                     pack sizes / sheet counting ─────────────────────┘
```

**The owner's inputs are on the critical path more than the code is.** Each week of delay on the items above delays launch by roughly a week.

---

## 3. Sprint Zero checklist

**Status key:**
- ✅ done in this session
- 🟡 done locally; needs an owner action to finish
- 🔲 not started
- 👤 owner action

### Repository setup

- ✅ Research and planning docs; project memory; path-scoped rules
- ✅ App scaffold: Vite + React + TypeScript (strict), folder layout per CLAUDE.md file map
- ✅ ESLint + Prettier + EditorConfig; `npm run lint | typecheck | test | build`
- ✅ Vitest configured with a first passing test (`localize()` fallback, the language-data helper)
- ✅ `.gitignore`, `.env.example` (names only), `.nvmrc`
- ✅ Foundation agents in `.claude/agents/`: orchestrator, architect, db-engineer, security-reviewer, qa-engineer, docs-keeper. Meta protocol in `.claude/rules/agent-protocol.md`
- ✅ Hooks: production guard, read-only SQL guard, docs-only paths, generated-types protection
- 👤 GitHub branch protection on `main` (require CI) *(repo settings; owner)*

### CI/CD pipeline

- 🟡 `.github/workflows/ci.yml` written: install → lint → typecheck → unit tests → build → local Postgres → `db reset` → `test db`. **First run happens on the first PR.**
- 🔲 `deploy.yml` (M3, after hosting approval)
- 🔲 `backup.yml` (M3, needs R2 credentials)
- 🔲 Cloud-session SessionStart hook (installs dependencies)

### Development environment

- ✅ Node 22 (`.nvmrc`), Supabase CLI via `npx supabase`
- 🟡 Local Supabase stack: Docker starts here (manually), but pulling Supabase images failed with **"Data limit exceeded"** from the registry (2026-10-30). Migrations and pgTAP are therefore **not yet run here**; CI (GitHub runners) is the first real run. See R4.
- 🔲 Playwright configured (M2, with the first UI)

### Database provisioning

- ✅ `supabase init`; `config.toml` committed
- ✅ Init migration: `app` schema, `pgcrypto`, `btree_gist`
- ✅ **RLS guard test** (pgTAP): fails if any table in `public` lacks RLS. It protects every future migration.
- 👤 **Supabase project: none connected yet.** The owner's org "America's Dust Busters" is on **Pro** and has two projects in use ("ADB Project": live inventory data; "Fleet Repair Log"). Both already have a `profiles` table that would collide. **Recommendation:** a new dedicated `plantboard-dev` project in the same org. On Pro, each extra project adds compute cost (≈ $10/mo Micro; confirm in the dashboard), so it needs owner approval. Then set `SUPABASE_PROJECT_REF` / `SUPABASE_ACCESS_TOKEN` as GitHub secrets.
- 👤 Production project on **Supabase Pro** (paid, ~$25/mo). **Approval needed before M3**, not now.

### Authentication scaffolding

- ✅ `src/lib/supabase.ts` (single client, publishable key only, env-validated)
- ✅ Magic-link sign-in screen + auth guard + sign-out (EN/ES strings)
- 🔲 Custom Access Token Hook (M1, needs `memberships` table)
- 👤 Resend account + custom SMTP for dev Auth emails (M1)

---

## 4. Risk register

L = likelihood, I = impact (H/M/L).

| # | Risk | Milestone | L | I | Mitigation | Owner |
|---|---|---|---|---|---|---|
| R1 | **Owner inputs arrive late**: shift schedule, pack sizes, sheet counting, baseline tally | M1, M3, M4 | H | H | Critical path shown in §2. Fixtures let code proceed. Dispatch ships before capture, so capture inputs don't block the pilot. Meta batches asks weekly | meta |
| R2 | RLS or tenancy mistake exposes or blocks data | M1+ | M | H | RLS guard test; pgTAP per role per table; security-reviewer on every SQL/function change; advisors in CI | security-reviewer |
| R3 | DST or overnight-shift bugs in reports | M1, M4 | M | M | DST fixtures (Mar/Nov) in pgTAP; `AT TIME ZONE` only; business-date attribution | db-engineer, qa |
| R4 | Local Supabase not available in cloud sessions: no Docker daemon by default, and image pulls hit a registry "Data limit exceeded" (2026-10-30) | All | H | M | CI runs the full stack on GitHub runners. Locally, use a developer machine. In cloud sessions, rely on CI results for SQL | release-engineer |
| R5 | Plant Wi-Fi or heat kills displays | M3 | M | H | Survey before install; wired AP if needed; mount outside the wet zone or use enclosures; offline UI; 1 spare box | owner + release-engineer |
| R6 | Crew ignores screens and keeps calling | M3 | M | H | Pilot measures it; owner commits to "if it's not on the screen, it's not the priority"; Spanish quick card; kill/pivot rule (PRD §8.4) | owner, meta |
| R7 | Manager entry becomes a bottleneck (only source of finishing output) | M4 | M | H | ≤ 5 taps, presets, running totals, offline; measure seconds per entry; optional shared finishing tablet | frontend-engineer |
| R8 | Realtime latency > 2 s on plant network | M2–M3 | L | M | Measure in M2 and on site; refetch fallback; reduce payloads | qa, display-engineer |
| R9 | AI-only translation review misses errors (esp. Creole) | M2, post-MVP | M | M | Separate review agent; flag low-confidence strings; recommended crew spot-check; Creole off until reviewed | a11y-i18n-specialist |
| R10 | iOS blocks in-app voice; Creole speech unsupported | post-MVP | H | L | MVP relies only on OS dictation; in-app voice is post-MVP and feature-detected | a11y-i18n-specialist |
| R11 | Diamond provides no export | post-MVP | M | M | Manual entry is the MVP path; parser only from a real sample | edge-engineer |
| R12 | Agent costs or loops (many subagents per feature) | All | M | M | Meta does small work inline; ≤ 3 parallel; depth 2; stop after 2 partials | meta |
| R13 | Scope creep into deferred items | All | M | M | Architect blocks non-MVP scope; deferrals listed in §1.3 | architect |
| R14 | Paid-service pricing differs from research | M3 | L | L | Re-verify on vendor pages before approval; ~$35/mo budget | release-engineer |
| R15 | Single point of knowledge (owner + AI) | All | M | M | CLAUDE.md "Current state", runbooks, ADRs kept current by docs-keeper | docs-keeper |

---

## 5. Launch checklist (M5 gate)

Every item needs **evidence**: a link, command output or document. "Looks fine" doesn't count.

### Security review

- [ ] security-reviewer full audit: PASS, 0 critical/high open
- [ ] Supabase advisors on **prod**: 0 security errors; performance warnings triaged
- [ ] Every public table has RLS (guard test green on prod schema)
- [ ] pgTAP role matrix passes, including cross-tenant denial
- [ ] No service-role key in client bundle (grep the build output)
- [ ] Pairing rate limit and revocation verified (≤ 60 s)
- [ ] Secrets only in GitHub, Netlify and Supabase stores; secret scanning on
- [ ] No per-person data in schema or UI (architect + security sign-off)
- [ ] Crew data notice approved by HR/legal and delivered in EN/ES

### Performance benchmarks (PRD §6.1)

- [ ] Phone → display p95 ≤ 2 s (100 samples, plant Wi-Fi)
- [ ] Display cold load ≤ 3 s on the actual TV box
- [ ] Phone cold load ≤ 3 s on 4G; initial JS ≤ 250 KB gzipped
- [ ] Finished-goods entry median ≤ 10 s
- [ ] Shift report ≤ 1.5 s for a 12-hour shift
- [ ] 72 h display soak: memory growth < 50 MB
- [ ] Offline: 500 entries over 8 h, 0 lost, 0 duplicated

### User testing completed

- [ ] Pilot (M3) report reviewed; fix list closed or deferred with owner OK
- [ ] Owner, every manager, and the washroom lead each completed their core flow unaided
- [ ] Accessibility device pass: VoiceOver, TalkBack, iOS Voice Control, Android Voice Access, 200% text
- [ ] OS dictation works in every input on the managers' actual phones
- [ ] Spanish UI reviewed (AI pass) + crew spot-check of display strings (recommended)
- [ ] Crew pulse ≥ 60% "screen is clear"

### Operations & documentation ready

- [ ] Restore drill passed (nightly backup restored to a scratch project)
- [ ] Sentry live; display heartbeat visible; uptime check on
- [ ] Runbooks: display setup (Spanish), pairing, restore, "screen offline" quick fix
- [ ] Quick-reference cards: owner, manager, washroom lead (EN/ES)
- [ ] CLAUDE.md "Current state" updated; commands and file map match reality
- [ ] Baseline call tally on file (for the month-1 review)
- [ ] Owner sign-off recorded
