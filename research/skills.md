# Skills Inventory: PlantBoard

*Prepared 2026-10-27 from [`PRD.md`](./PRD.md) **v1.1** (no scale; wash loads as the unit; manager-only finished-goods entry), [`tech-stack.md`](./tech-stack.md) and [`.claude/CLAUDE.md`](../.claude/CLAUDE.md), after reviewing the [Claude Code skills docs](https://code.claude.com/docs/en/skills).*

This lists **every distinct capability** needed to build the PRD (56 entries). Every entry documents all eight requested fields: name, description, input, output, dependencies (libraries, external APIs, other skills), docs, complexity and example invocation, and says how each should be packaged. **Most of them should not become Claude Code skills.** Read §1 before building any.

---

## 1. What a Claude Code skill is, and why that limits this list

These points come from the official docs and should drive what we build:

- **A skill is a folder of instructions, not code that executes.**
  - The folder is `.claude/skills/<name>/SKILL.md`: YAML frontmatter plus markdown, with optional supporting files and scripts.
  - Two kinds of content:
    - **Reference skills** hold conventions or domain knowledge.
    - **Task skills** are step-by-step procedures.
  - An "input/output" for a skill means: what context Claude needs, and what files or results Claude produces by following it.
- **How skills get invoked:**
  - You type `/name args`, or Claude loads the skill automatically when its `description` matches the request.
  - From an agent, it's the `Skill` tool: `Skill(skill: "name", args: "...")`.
  - Arguments arrive as `$ARGUMENTS`, `$0`, `$1`, or named `$arg` values.
- **Useful frontmatter fields:**

  | Field | Effect |
  |---|---|
  | `disable-model-invocation: true` | Only you can run it. Use for side effects like deploys. |
  | `user-invocable: false` | Background knowledge only Claude uses. |
  | `paths:` | Auto-loads only when Claude works on matching files. |
  | `context: fork` | Runs in an isolated subagent. |
  | `allowed-tools` | Pre-approves the tools the skill needs. |

- **Context cost is real, and this is the key constraint:**
  - Skill descriptions sit in context every session. The listing budget is about **1% of the context window**.
  - With too many skills, **descriptions get dropped**, and Claude stops triggering the right one.
  - A full skill body stays in context once invoked.
  - Keep each `SKILL.md` under 500 lines.
- **A project skill named `verify` (or `simplify`) is run by Claude automatically before each commit** (except docs/test-only changes). Our "prove before pushing" rule should be that skill.
- **Rules that must hold every time belong in hooks, not skills.** The docs say so explicitly: skills can be skipped, hooks always run.
- **Bundled and already-installed skills cover a lot already:**
  - Bundled: `/run`, `/verify`, `/run-skill-generator`, `/code-review`, `/security-review`, `/simplify`, `/debug`, `/doctor`.
  - Plus `session-start-hook`, `dataviz`, `engineering:*`, `design:accessibility-review`.
  - **Don't duplicate them.**

### How each capability is packaged

| Packaging | Meaning | Count |
|---|---|---|
| **BUILD** | Write a project skill in `.claude/skills/` | **17** |
| **COVERED** | Folded into one of the BUILD skills (as an argument or a reference file) | 7 |
| **RULE** | Already covered by `.claude/CLAUDE.md` or `.claude/rules/*.md`; extend those instead | 10 |
| **EXISTING** | Use a bundled or installed skill, or an MCP server | 7 |
| **HOOK** | Must always hold, so enforce it with a hook in `.claude/settings.json` (§5 lists the 4 hooks) | 1 |
| **ONE-TIME** | Done once during setup; a skill adds nothing | 9 |
| **DEFER** | Not needed until a P1/P2 feature or an external answer arrives | 5 |
| **Total** | | **56** |

**Recommendation:** build the 17 BUILD skills, in the order in §3, as each phase needs them. Everything else maps to an existing mechanism. More skills than that makes Claude *worse* at picking the right one.

---

## 2. Summary table

| # | Skill | Category | Packaging | Complexity | Phase / PRD features |
|---|---|---|---|---|---|
| DB-01 | `schema-migration` | Database | **BUILD** | Moderate | Foundation · §4 |
| DB-02 | `rls-policies` | Database / Auth | **BUILD** | Complex | Foundation · §4.7 |
| DB-03 | `rls-tests` | Testing | **BUILD** | Complex | Foundation · §4.7, §6.2 |
| DB-04 | `rpc-function` | Database / API | **BUILD** | Moderate | Core · §5.3 |
| DB-05 | `db-triggers` | Database | RULE (in DB-04 reference) | Moderate | §4.5 |
| DB-06 | `reporting-views` | Database | **BUILD** | Complex | Capture · G1–G3, §4.6 |
| DB-07 | `seed-data` | Database | ONE-TIME | Simple | Foundation · A1–A3 |
| DB-08 | `generate-db-types` | Database | HOOK | Simple | every migration |
| DB-09 | `pg-cron-jobs` | Database | RULE | Moderate | A6, B3, D4, retention |
| DB-10 | `plant-data-query` | Database | EXISTING (Supabase MCP) | Simple | ad hoc |
| DB-11 | `backup-restore` | Infra | ONE-TIME + runbook | Moderate | §6.2 #8 |
| DB-12 | `shift-time-logic` | Domain | in DOM-01 | Complex | A6 |
| AUTH-01 | `supabase-auth-setup` | Auth | ONE-TIME | Moderate | A4, §5.6 |
| AUTH-02 | `user-invites-roles` | Auth | in EDGE-01 | Moderate | A4 |
| AUTH-03 | `device-pairing` | Auth | **BUILD** | Complex | A7 |
| AUTH-04 | `item-counting-setup` | Domain / data | in FE-01 + DB-04 | Moderate | A2, G3 |
| AUTH-05 | `owner-mfa` | Auth | DEFER (P1) | Simple | §6.2 #5 |
| EDGE-01 | `edge-function` | API integration | **BUILD** | Moderate | §5.4 |
| EDGE-02 | `washer-import` | API integration | DEFER (needs sample file) | Complex | F3 |
| EDGE-03 | `accuflow-sync` | API integration | DEFER (P2, needs Diamond) | Complex | F4 |
| EDGE-04 | `email-alerts` | API integration | in EDGE-01 | Moderate | B3, D4, H3 |
| EDGE-05 | `inbound-email-ingest` | API integration | DEFER (P2) | Moderate | F4 |
| RT-01 | `realtime-sync` | Frontend / Realtime | **BUILD** | Complex | B1, C1–C4, D1–D2 |
| RT-02 | `queue-ordering` | Frontend / DB | in DB-04 + FE rules | Moderate | C2–C3 |
| FE-01 | `feature-slice` | Frontend | **BUILD** | Moderate | every epic |
| FE-02 | `display-screen` | Frontend | **BUILD** | Complex | D1–D3, D5 |
| FE-03 | `finished-goods-entry-ui` | Frontend | RULE (frontend.md) | Moderate | E1–E4, F1 |
| FE-04 | `control-mobile-ui` | Frontend | RULE (frontend.md) | Moderate | B, C, G |
| FE-05 | `offline-mutations` | Frontend | **BUILD** | Complex | E3 |
| FE-06 | `i18n-strings` | Frontend | **BUILD** | Simple | H1 |
| FE-07 | `pwa-setup` | Frontend | ONE-TIME | Moderate | H4 |
| FE-08 | `forms-validation` | Frontend | RULE | Simple | A2, A5, B1, C1 |
| FE-09 | `report-charts` | Frontend | EXISTING (`dataviz`) | Moderate | G1–G2, G5 |
| FE-10 | `design-tokens` | Frontend | ONE-TIME | Moderate | §6.3 |
| FE-11 | `voice-input` | Frontend / accessibility | in FE-01 + frontend.md | Moderate | H7 |
| TEST-01 | `unit-tests` | Testing | RULE | Simple | all |
| TEST-02 | `e2e-tests` | Testing | **BUILD** | Complex | §6.1, §6.4 |
| TEST-03 | `accessibility-check` | Testing | EXISTING + in TEST-02 | Moderate | §6.3 |
| TEST-04 | `performance-budget` | Testing | ONE-TIME (CI) | Simple | §6.1 |
| TEST-05 | `security-review` | Testing | EXISTING (`/security-review` + Supabase advisors) | Moderate | §6.2 |
| TEST-06 | `verify` | Testing | **BUILD** | Moderate | every commit |
| TEST-07 | `code-review` | Testing | EXISTING (`/code-review`) | Simple | every PR |
| OPS-01 | `ci-pipeline` | Deployment | ONE-TIME | Moderate | §4 tech-stack CI/CD |
| OPS-02 | `release` | Deployment | **BUILD** (manual-only) | Moderate | every release |
| OPS-03 | `cloud-session-setup` | Deployment | EXISTING (`session-start-hook`) | Simple | dev environment |
| OPS-04 | `env-secrets` | Deployment | RULE + HOOK | Simple | §5.6, §6.2 #3 |
| OPS-05 | `monitoring-setup` | Infra / logging | ONE-TIME | Simple | D4, §6.1 |
| OPS-06 | `kiosk-device-setup` | Infra | ONE-TIME (runbook) | Simple | D1, A7 |
| DOC-01 | `update-memory` | Docs | **BUILD** | Simple | every session |
| DOC-02 | `decision-record` | Docs | EXISTING (`engineering:architecture`) | Simple | as needed |
| DOC-03 | `crew-communications` | Docs | DEFER (needs HR/legal) | Moderate | §6.2 #11 |
| DOC-04 | `api-reference` | Docs | RULE (RPC comments) | Simple | §5 |
| ERR-01 | `error-handling` | Error handling | RULE (extend rules) | Moderate | §5.1 |
| ERR-02 | `instrumentation` | Logging / metrics | in FE-01 + DB-06 | Moderate | H5, §8 |
| ERR-03 | `edge-logging` | Logging | RULE (edge-functions.md) | Simple | §5.4 |
| DOM-01 | `laundry-domain` | Domain reference | **BUILD** (Claude-only) | Moderate | glossary, loads/packs/units, reconciliation, shifts |

---

## 3. Build order for the 17 project skills

| Order | Skill | Why now |
|---|---|---|
| 1 | `laundry-domain` (DOM-01) | Every other skill relies on the vocabulary, units and shift logic |
| 2 | `schema-migration` (DB-01) | Foundation phase starts with migrations |
| 3 | `rls-policies` (DB-02) | Same migration as each table |
| 4 | `rls-tests` (DB-03) | Proves tenancy before any UI exists |
| 5 | `rpc-function` (DB-04) | Queue, estimates, sessions, logging |
| 6 | `verify` (TEST-06) | Turns on automatic pre-commit checks as soon as code exists |
| 7 | `edge-function` (EDGE-01) | invite-user, pair-device |
| 8 | `device-pairing` (AUTH-03) | Wall displays depend on it |
| 9 | `feature-slice` (FE-01) | First UI work |
| 10 | `realtime-sync` (RT-01) | Core loop: phone → screen in ≤ 2 s |
| 11 | `display-screen` (FE-02) | The product's most visible surface |
| 12 | `offline-mutations` (FE-05) | The manager is the only source of finishing output, so entries must never be lost |
| 13 | `i18n-strings` (FE-06) | Keep EN/ES in sync from the first string |
| 14 | `e2e-tests`, `reporting-views`, `release`, `update-memory` | Capture phase, launch prep, and ongoing upkeep |

The last row bundles four lower-urgency skills. Ship skills **as the phase needs them**, not all on day one. A skill written before the code exists will be wrong about the code.

---

## 4. Full inventory

> **Common links** used throughout:
> - Supabase docs: https://supabase.com/docs
> - Supabase CLI: https://supabase.com/docs/reference/cli/introduction
> - Postgres docs: https://www.postgresql.org/docs/current/
> - Claude Code skills: https://code.claude.com/docs/en/skills
> - Hooks: https://code.claude.com/docs/en/hooks
>
> **"Skills" under Dependencies** means other entries in this inventory.

### 4.1 Database operations

#### DB-01 · `schema-migration`

**BUILD (task skill) · Moderate**

- **Description:**
  - Creates a Supabase migration for one table (or group of tables) exactly as specified in PRD §4.4.
  - Includes tenant composite FKs, CHECK constraints and FK indexes.
  - **Enables RLS in the same file.**
  - Resets the local DB, regenerates types, and runs the RLS tests.
- **Input:**
  - Table name(s) or a PRD feature ID.
  - PRD §4.3–4.4 and §4.8.
  - The existing `supabase/migrations/`.
  - `.claude/rules/database.md`.
- **Output:**
  - `supabase/migrations/<ts>_<verb_noun>.sql`.
  - Updated `src/types/database.ts`.
  - A test-pass summary, or the failures.
- **Dependencies:**
  - Libraries: Supabase CLI, Docker (local stack), Postgres 15+ (`pgcrypto`, `btree_gist`).
  - Skills: DB-02 `rls-policies`, DB-03 `rls-tests`, DB-08 type-gen hook, DOM-01.
- **Docs:**
  - https://supabase.com/docs/guides/deployment/database-migrations
  - https://supabase.com/docs/guides/local-development
  - https://www.postgresql.org/docs/current/ddl-constraints.html
- **Example:**
  - `/schema-migration queue_items`
  - Agent: `Skill(skill: "schema-migration", args: "finished_goods_entries shift_crew_hours")`
- **Frontmatter:**
  - `arguments: [tables]`
  - `allowed-tools: Bash(supabase migration new *) Bash(supabase db reset) Bash(supabase test db) Bash(supabase gen types *)`

#### DB-02 · `rls-policies`

**BUILD (reference + task) · Complex**

- **Description:**
  - Writes RLS policies that implement the PRD §4.7 role matrix (owner, manager, lead, viewer, display) using `app.has_role()` and `app.my_device()`.
  - Policy calls are wrapped in `(select ...)` so Postgres caches them.
  - Adds tables to the Realtime publication only where the PRD says so.
- **Input:** table name; PRD §4.7 matrix; helper functions; current policies (`pg_policies`).
- **Output:** policy SQL in the table's migration (or a follow-up migration), plus a short matrix of the policies created.
- **Dependencies:**
  - Postgres RLS; Supabase Auth (`auth.uid()`, JWT claims); Custom Access Token Hook.
  - Skills: DB-01, DB-03, AUTH-01.
- **Docs:**
  - https://supabase.com/docs/guides/database/postgres/row-level-security
  - https://supabase.com/docs/guides/database/postgres/row-level-security#rls-performance-recommendations
  - https://www.postgresql.org/docs/current/ddl-rowsecurity.html
  - https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook
- **Example:** `/rls-policies finished_goods_entries`
- **Why it's a skill, not just a rule:**
  - RLS mistakes are the #1 security risk in this design.
  - The matrix and policy patterns are too long for `database.md`.
  - They load only when needed.

#### DB-03 · `rls-tests`

**BUILD (task skill) · Complex**

- **Description:**
  - Generates pgTAP tests asserting each role's allowed and denied operations per table.
  - Negative cases: cross-tenant reads/writes denied; lead/viewer writing finished goods denied; display writes denied; anon denied.
  - Also tests that CHECK constraints reject bad data.
- **Input:** table name; PRD §4.7 and §4.9; seed fixtures for two orgs.
- **Output:** `supabase/tests/<table>.test.sql`; `supabase test db` results.
- **Dependencies:**
  - pgTAP, Supabase CLI test runner.
  - Optional helper: `basejump-supabase_test_helpers` (`tests.create_supabase_user`, `authenticate_as`).
  - Skills: DB-01, DB-02.
- **Docs:**
  - https://supabase.com/docs/guides/database/testing
  - https://pgtap.org/documentation.html
  - https://github.com/usebasejump/supabase-test-helpers
- **Example:**
  - `/rls-tests queue_items`
  - Agent after a migration: `Skill(skill: "rls-tests", args: "queue_items")`

#### DB-04 · `rpc-function`

**BUILD (task skill with reference file) · Moderate**

- **Description:** Writes a Postgres RPC to the house template:
  - `security definer` with `set search_path = ''`;
  - role check first, then argument validation;
  - app error codes from PRD §5.1;
  - `client_id` idempotency, and `p_expected_version` for queue writes;
  - `audit_log` write;
  - a `comment on function`, which serves as the API docs.
- **What it covers:**
  - The PRD §5.3 functions, including `record_finished_goods` (packs + loose vs. unit items, `COUNT_MODE_MISMATCH`, loose ≥ pack warning) and fractional queue reordering (RT-02).
  - A `reference.md` holding the trigger patterns from §4.5 (DB-05).
- **Input:** function name and PRD §5.3 row; related tables; the error-code list.
- **Output:**
  - A migration containing the function.
  - pgTAP tests for success, each error code, and role denial.
  - Regenerated types.
- **Dependencies:**
  - PL/pgSQL; PostgREST RPC.
  - Skills: DB-01, DB-03, DOM-01.
- **Docs:**
  - https://supabase.com/docs/guides/database/functions
  - https://docs.postgrest.org/en/stable/references/api/functions.html
  - https://www.postgresql.org/docs/current/plpgsql.html
- **Example:**
  - `/rpc-function move_queue_item`
  - `/rpc-function record_finished_goods`

#### DB-05 · `db-triggers`

**RULE (reference file inside DB-04) · Moderate**

- **Description:** Patterns for these triggers:
  - `touch_updated_at`
  - `audit`
  - `prevent_mutation` / `prevent_delete`
  - `bump_queue_version` (status transition guard)
  - `set_shift_instance`
  - `resolve_item_from_formula`
  - `throttle_device_writes`
- **Input:** PRD §4.5.
- **Output:** trigger functions plus `create trigger` statements, with tests.
- **Dependencies:** PL/pgSQL. Skills: DB-04.
- **Docs:** https://www.postgresql.org/docs/current/plpgsql-trigger.html
- **Example:** "Add the prevent_delete trigger to washer_cycles." DB-04's reference file is used.

#### DB-06 · `reporting-views`

**BUILD (task skill) · Complex**

- **Description:**
  - Builds the reporting layer: views from PRD §4.6 (`security_invoker`), `app.to_loads()` conversion, the `get_shift_report` RPC, and the `weekly_success_metrics` view (PRD §8.5).
  - Missing conversion factors produce `null` + `partial_conversion`.
  - Includes `daily_reconciliation` (per business date: loads washed vs. ≈ loads finished via `pieces_per_load`; per-shift reconciliation was dropped in PRD v1.3 because area shifts differ) and `suggested_pieces_per_load` (trailing 28 days, ≥ 20 loads).
  - Approximate values carry an `approximate` / `has_conversion` flag. There is no per-person data.
- **Input:** report name; PRD §4.6, §8.3; item conversion factors (from owner); sample data.
- **Output:**
  - A migration with views and functions.
  - pgTAP tests using fixed fixture data with known expected totals.
  - An `EXPLAIN ANALYZE` check against the ≤ 1.5 s target.
- **Dependencies:** Postgres views and aggregates. Skills: DB-01, DB-03, DOM-01.
- **Docs:**
  - https://www.postgresql.org/docs/current/sql-createview.html
  - https://supabase.com/docs/guides/database/postgres/row-level-security#views
  - https://www.postgresql.org/docs/current/using-explain.html
- **Example:** `/reporting-views daily_reconciliation`

#### DB-07 · `seed-data`

**ONE-TIME · Simple**

- **Description:** Writes `supabase/seed.sql` for ADB: org, plant, areas, finishing lines, machines, item types (with counting unit and pack size), wash formulas, shifts. Also fixtures for a second test org.
- **Input:** values from the owner (the "Waiting on the owner" list). **Never invented.**
- **Output:** `supabase/seed.sql`; `supabase db reset` passes.
- **Dependencies:** Supabase CLI. Skills: DB-01.
- **Docs:** https://supabase.com/docs/guides/local-development/seeding-your-database
- **Example:** "Seed the database with the item list Manny sent." This is a normal request; no skill is needed.

#### DB-08 · `generate-db-types`

**HOOK · Simple**

- **Description:** After any edit to `supabase/migrations/**`, regenerate `src/types/database.ts`. Also block hand edits to that file.
- **Input:** the local Supabase stack running.
- **Output:** an updated generated types file.
- **Dependencies:** Supabase CLI; Claude Code hooks: `PostToolUse` on Write/Edit matching migrations; `PreToolUse` deny on `src/types/database.ts`.
- **Docs:**
  - https://supabase.com/docs/guides/api/rest/generating-types
  - https://code.claude.com/docs/en/hooks
- **Example:** Automatic. No invocation.

#### DB-09 · `pg-cron-jobs`

**RULE (add to database.md) · Moderate**

- **Description:** Scheduled jobs:
  - `generate_shift_instances` (daily)
  - `close_stale_sessions` (every 10 min)
  - calling `dispatch-alerts` (every 15 min)
  - retention purges (`app_events` after 13 months, pairing codes after 24 h)
- **Input:** PRD §4.5, §6.2 #12.
- **Output:** a migration with `cron.schedule(...)` calls; tests for the job functions themselves.
- **Dependencies:** `pg_cron`, `pg_net` (to call Edge Functions). Skills: DB-04.
- **Docs:**
  - https://supabase.com/docs/guides/database/extensions/pg_cron
  - https://supabase.com/docs/guides/database/extensions/pg_net
  - https://supabase.com/docs/guides/functions/schedule-functions
- **Example:** "Schedule shift-instance generation daily at 00:05 UTC."

#### DB-10 · `plant-data-query`

**EXISTING (Supabase MCP) · Simple**

- **Description:** Ad hoc questions answered from data ("what did Ironer 2 produce last night?") and schema inspection.
- **Input:** the question; access to the dev project (or read-only prod).
- **Output:** query results and an explanation.
- **Dependencies:** Supabase MCP server (`execute_sql`, `list_tables`, `get_advisors`).
- **Docs:** https://supabase.com/docs/guides/getting-started/mcp
- **Example:** "Using Supabase MCP on dev, show yesterday's shift totals."
- **Guardrail:** read-only against production (CLAUDE.md).

#### DB-11 · `backup-restore`

**ONE-TIME (GitHub Action) + runbook · Moderate**

- **Description:** A nightly `pg_dump` to Cloudflare R2, plus a documented restore drill (required before launch, then quarterly).
- **Input:** `BACKUP_DATABASE_URL`, R2 credentials.
- **Output:**
  - `.github/workflows/backup.yml`
  - `docs/runbooks/restore.md`
  - A restore-drill log entry
- **Dependencies:**
  - `pg_dump`/`pg_restore`; AWS CLI or `rclone` (S3-compatible R2); GitHub Actions.
  - Skills: OPS-01.
- **Docs:**
  - https://supabase.com/docs/guides/platform/backups
  - https://www.postgresql.org/docs/current/app-pgdump.html
  - https://developers.cloudflare.com/r2/api/s3/
- **Example:** "Set up the nightly backup workflow." A normal request; no skill needed.

#### DB-12 · `shift-time-logic`

**Part of DOM-01 · Complex**

- **Description:** Rules for shifts that cross midnight, and for business dates.
- **⚠️ Daylight saving time:** a night shift spanning the DST switch in `America/New_York` lasts 7 or 9 hours. Generation and reports must use `timezone()` conversions, not fixed offsets. **The PRD doesn't call this out yet. Add tests for it.**
- **Input:** shift definitions; plant timezone.
- **Output:** correct `shift_instances`; DST test cases.
- **Dependencies:** Postgres `timestamptz`, `AT TIME ZONE`; `date-fns-tz` on the client.
- **Docs:**
  - https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-TIMEZONES
  - https://github.com/marnusw/date-fns-tz
- **Example:** Loaded via `laundry-domain` when working on A6.

### 4.2 Authentication & authorization

#### AUTH-01 · `supabase-auth-setup`

**ONE-TIME · Moderate**

- **Description:**
  - Configure Supabase Auth: email magic link; custom SMTP via Resend (avoids the default email rate cap); redirect URLs; JWT expiry.
  - Set up the Custom Access Token Hook that adds `app_org_id`, `app_role`, `app_plant_ids`.
- **Input:** PRD §5.6; domain; Resend credentials.
- **Output:** a migration for the hook function; `supabase/config.toml` auth settings; a doc note.
- **Dependencies:** Supabase Auth, Resend SMTP. Skills: DB-01.
- **Docs:**
  - https://supabase.com/docs/guides/auth
  - https://supabase.com/docs/guides/auth/auth-smtp
  - https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook
  - https://resend.com/docs/send-with-supabase-smtp
- **Example:** "Configure auth per PRD §5.6."

#### AUTH-02 · `user-invites-roles`

**Covered by EDGE-01 · Moderate**

- **Description:** The `invite-user` and `revoke-user` Edge Functions, plus the owner UI for roles.
- **Input:** PRD A4, §5.4.
- **Output:** two functions, membership writes, UI screen, tests.
- **Dependencies:** `supabase-js` admin API (`inviteUserByEmail`, `signOut`). Skills: EDGE-01, FE-01.
- **Docs:** https://supabase.com/docs/reference/javascript/auth-admin-inviteuserbyemail
- **Example:** `/edge-function invite-user`
- **Rule:** the last owner can't be removed.

#### AUTH-03 · `device-pairing`

**BUILD (task skill) · Complex**

- **Description:** End-to-end device pairing:
  1. the `create_pairing_code` RPC;
  2. the public `pair-device` Edge Function: rate limit 10 per IP per 10 min, constant-time compare, single-use 15-min codes, creates the device auth user + membership + `devices` row, returns a session;
  3. the `/pair` screen;
  4. persisting the refresh token on the device;
  5. `revoke-device` plus a broadcast "unpaired" message;
  6. heartbeat.
- **Input:** PRD A7, D4, §5.4–5.5; `devices` / `pairing_codes` schema.
- **Output:** RPC + 2 Edge Functions + `/pair` route + tests (pgTAP and Playwright pairing flow).
- **Dependencies:**
  - `supabase-js` (`auth.setSession`), Supabase admin API, Realtime Broadcast.
  - Skills: EDGE-01, DB-04, FE-01, RT-01.
- **Docs:**
  - https://supabase.com/docs/reference/javascript/auth-setsession
  - https://supabase.com/docs/reference/javascript/auth-admin-createuser
  - https://supabase.com/docs/guides/realtime/broadcast
- **Example:** `/device-pairing`
- **Why it's a skill:** it is security-sensitive, touches 4 layers, and is easy to get subtly wrong (token persistence, revocation within 60 s).

#### AUTH-04 · `item-counting-setup`

**Covered by FE-01 + DB-04 · Moderate** *(replaces the removed operator-PIN capability; PRD v1.1)*

- **Description:**
  - The item setup screen (A2): counting unit (`unit` / `pack`), pack size, estimate unit (loads / baskets + `baskets_per_load`), approximate `pieces_per_load` with its source.
  - The `accept_pieces_per_load` RPC: one-tap acceptance of the app's suggested value (G3). **Never applied automatically.**
  - Pack-size changes never rewrite history, because entries store `pack_size_used`.
- **Input:** PRD A2, G3, §4.4 `item_types`; the owner's item list.
- **Output:** setup UI + RPC + tests (a pack item needs a pack size; baskets need baskets per load).
- **Dependencies:** Skills: FE-01, DB-04, DB-06, DOM-01.
- **Docs:**
  - https://supabase.com/docs/guides/database/functions
  - https://react-hook-form.com/
  - https://zod.dev/
- **Example:** `/feature-slice A2`

#### AUTH-05 · `owner-mfa`

**DEFER (P1) · Simple**

- **Description:** TOTP MFA enrollment and challenge for owners; RLS checks `aal2` for owner-only writes.
- **Input:** PRD §5.6 and §6.2 #5; the list of owner accounts.
- **Output:** MFA enrollment and challenge screens; RLS checks of `aal2` for owner-only writes; pgTAP tests proving an `aal1` session is denied.
- **Dependencies:** Supabase Auth MFA (TOTP), `supabase-js` `auth.mfa.*`; an authenticator app on the owner's phone. Skills: FE-01, DB-02.
- **Docs:** https://supabase.com/docs/guides/auth/auth-mfa/totp
- **Example:** "Require MFA for owners" (P1 ticket).

### 4.3 API integration with external services (Edge Functions)

#### EDGE-01 · `edge-function`

**BUILD (task skill) · Moderate**

- **Description:** Scaffolds and implements a Supabase Edge Function to the house template:
  - **authorize first** (verify JWT → membership role → only then create a service-role client);
  - validate input with Zod;
  - `{ code, message }` errors with correct HTTP status;
  - no logging of secrets or bodies;
  - shared code in `_shared/`;
  - Deno tests.
- **Covers:** `invite-user`, `revoke-user`, `revoke-device`, `dispatch-alerts` (EDGE-04).
- **Input:** function name; PRD §5.4 row; `.claude/rules/edge-functions.md`.
- **Output:**
  - `supabase/functions/<name>/index.ts` and a test.
  - Local `supabase functions serve` verified.
  - Deploy command documented. **It does not deploy.**
- **Dependencies:** Deno, `supabase-js`, Zod; Supabase Edge Runtime. Skills: DOM-01, ERR-01.
- **Docs:**
  - https://supabase.com/docs/guides/functions
  - https://supabase.com/docs/guides/functions/auth
  - https://supabase.com/docs/guides/functions/unit-test
  - https://zod.dev/
- **Example:** `/edge-function dispatch-alerts`

#### EDGE-02 · `washer-import`

**DEFER (blocked) · Complex**

- **Description:** The `import-washer-file` function:
  - two-stage preview/commit;
  - CSV/XLSX parse; store the raw file in Storage;
  - dedupe on `file_sha256` and `(plant_id, source, external_id)`;
  - unknown machines/formulas flagged;
  - formula → item mapping.
  - Plus the upload UI.
- **Blocked on a real Accu-Flow CloudView sample export from Diamond Chemical** (CLAUDE.md forbids guessing the format).
- **Input:** sample file(s); PRD F2–F3; `wash_formulas` mapping.
- **Output:** function + UI + fixtures from the real sample + tests.
- **Dependencies:**
  - Papa Parse (CSV) and SheetJS (XLSX) running in Deno; Supabase Storage.
  - Skills: EDGE-01, FE-01.
- **Docs:**
  - https://www.papaparse.com/docs
  - https://docs.sheetjs.com/docs/getting-started/installation/deno
  - https://supabase.com/docs/guides/storage
- **Example (once unblocked):** `/edge-function import-washer-file`, using a `washer-import` reference file written from the sample.

#### EDGE-03 · `accuflow-sync`

**DEFER (P2, contingent) · Complex**

- **Description:** Scheduled pull from a Diamond Chemical API, **only if one exists.** Incremental cursor, retries, idempotent upsert.
- **Input:** Diamond API docs and credentials (`ACCUFLOW_API_KEY`). Unknown today.
- **Output:** function + cron schedule + tests.
- **Dependencies:** a Diamond API (not public); `pg_cron`/`pg_net`. Skills: EDGE-01, DB-09.
- **Docs:** none public. Get them from the Diamond rep.
- **Example:** n/a until Diamond answers.

#### EDGE-04 · `email-alerts`

**Covered by EDGE-01 · Moderate**

- **Description:** `dispatch-alerts` evaluates stale-estimate, device-offline and import-failed rules, dedupes through `alert_events` (1 per subject per shift), and sends via Resend in the recipient's language.
- **Input:** PRD B3, D4, H3; alert rules and thresholds from `plants`; recipients from `profiles.notify_email`; each recipient's language.
- **Output:** the `dispatch-alerts` function, a pg_cron schedule, `alert_events` rows, and translated email templates; tests for dedupe (one alert per subject per shift).
- **Dependencies:** Resend API. Skills: EDGE-01, DB-09.
- **Docs:**
  - https://resend.com/docs/api-reference/emails/send-email
  - https://resend.com/docs/send-with-deno
- **Example:** `/edge-function dispatch-alerts`

#### EDGE-05 · `inbound-email-ingest`

**DEFER (P2) · Moderate**

- **Description:** If Diamond can only email a scheduled report: an inbound address receives the attachment and triggers the EDGE-02 pipeline.
- **Input:** Diamond's confirmation that reports can be emailed on a schedule, plus a sample email with its attachment.
- **Output:** an inbound address and webhook handler that stores the attachment and calls the EDGE-02 preview/commit pipeline.
- **Dependencies:** a Resend inbound webhook (or Cloudflare Email Workers / Postmark inbound).
- **Docs:**
  - https://resend.com/docs/dashboard/receiving/introduction
  - https://developers.cloudflare.com/email-routing/email-workers/
- **Example:** n/a until Diamond answers.

### 4.4 Realtime & frontend

#### RT-01 · `realtime-sync`

**BUILD (task + reference) · Complex**

- **Description:** Wires a screen to live data:
  - a TanStack Query fetch of the snapshot RPC;
  - one Supabase channel per plant topic (§5.5);
  - `postgres_changes` handlers that patch or invalidate the cache;
  - **full refetch on connect, reconnect, `online`, `visibilitychange` and every 5 min**;
  - connection state, plus "updated Xs ago";
  - a latency sample written to `app_events`.
- **Input:** the screen or feature; the tables involved; PRD §5.5, D2, §6.1.
- **Output:** a hook such as `useQueueBoard(areaId)` or `useDisplayFeed(areaId)`, plus tests (Vitest with a mocked channel; Playwright live-update check).
- **Dependencies:**
  - `@supabase/supabase-js` Realtime, `@tanstack/react-query`.
  - Skills: FE-01, DB-02 (tables must be in the publication with RLS), ERR-02.
- **Docs:**
  - https://supabase.com/docs/guides/realtime/postgres-changes
  - https://supabase.com/docs/guides/realtime/authorization
  - https://tanstack.com/query/latest/docs/framework/react/guides/query-invalidation
  - https://tanstack.com/query/latest/docs/framework/react/guides/updates-from-mutation-responses
- **Example:** `/realtime-sync display-feed`

#### RT-02 · `queue-ordering`

**Covered by DB-04 + frontend.md · Moderate**

- **Description:**
  - Fractional `position` (midpoint of neighbors, renumber when the gap is < 1e-6) and optimistic concurrency via `version`.
  - Client: dnd-kit with keyboard and up/down alternatives; optimistic reorder with rollback; a conflict toast.
- **Input:** PRD C2–C3, §5.3 `move_queue_item`, `set_queue_rush`; the `queue_items` schema.
- **Output:** RPCs with midpoint positioning, renumbering and version checks; a sortable list with keyboard and up/down alternatives; tests for concurrent reorders (conflict) and rush ordering.
- **Dependencies:** `@dnd-kit/core`, `@dnd-kit/sortable`.
- **Docs:**
  - https://docs.dndkit.com/presets/sortable
  - https://docs.dndkit.com/api-documentation/sensors/keyboard
- **Example:** `/rpc-function move_queue_item`, then `/feature-slice queue`.

#### FE-01 · `feature-slice`

**BUILD (task skill) · Moderate**

- **Description:** Builds one PRD feature end to end on the frontend in `src/features/<epic>/`:
  - query and mutation hooks on generated types;
  - components for the target surface;
  - a Zod schema mirroring the DB checks;
  - i18n keys (EN + ES);
  - `app_events` instrumentation;
  - Vitest tests;
  - acceptance criteria checked off from the PRD.
- **Input:** PRD feature ID (e.g., `B1`); generated types; existing RPCs.
- **Output:** feature folder; route wiring; tests; a list of acceptance criteria met or not met.
- **Dependencies:**
  - React, React Router, TanStack Query, React Hook Form, Zod, shadcn/ui, Tailwind, react-i18next.
  - Skills: RT-01 (if live), FE-06, ERR-01, ERR-02, DOM-01.
- **Docs:**
  - https://react.dev/
  - https://reactrouter.com/
  - https://tanstack.com/query/latest/docs
  - https://react-hook-form.com/
  - https://zod.dev/
  - https://ui.shadcn.com/docs
  - https://tailwindcss.com/docs
- **Example:**
  - `/feature-slice B1`
  - Agent: `Skill(skill: "feature-slice", args: "C2")`

#### FE-02 · `display-screen`

**BUILD (task skill) · Complex**

- **Description:** Builds or changes the wall-display surface to PRD D1–D3 and §6.3:
  - Now / Next / Later layout at 1920×1080 with viewport-relative type (NOW ≥ 96 px, minimum 32 px, contrast ≥ 7:1);
  - bilingual modes;
  - RUSH badge that respects reduced motion;
  - offline and stale states;
  - Screen Wake Lock;
  - scheduled nightly reload;
  - message banners.
  - Verifies with Playwright screenshots at 1080p, 4K and 1366×768.
- **Input:** feature ID (D1/D2/D3/D5); the `get_display_feed` payload shape.
- **Output:** components in `src/app/display/`; screenshots; an a11y report.
- **Dependencies:**
  - React, Tailwind, the Screen Wake Lock API, `@axe-core/playwright`.
  - Skills: RT-01, FE-06, TEST-02, `design:accessibility-review`.
- **Docs:**
  - https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API
  - https://www.w3.org/TR/WCAG22/
  - https://playwright.dev/docs/screenshots
- **Example:** `/display-screen D2`

#### FE-03 · `finished-goods-entry-ui`

**RULE (frontend.md) · Moderate**

- **Description:** The manager's entry patterns (phone, or an optional shared tablet):
  - item picker (finishing NOW/NEXT first, then recent items);
  - pack items: `packs` + `loose` keypads, with pack size and a live total ("7 packs + 34 = 734");
  - unit items: one count;
  - per-entry pack-size override;
  - ≥ 56 px targets;
  - 10-second Undo;
  - running shift totals;
  - pending-sync counter;
  - ≤ 5 taps and ≤ 10 s per entry.
- **Input:** PRD E1–E4, F1; the item's `count_mode`, `pack_size`; the `record_finished_goods` RPC.
- **Output:** the entry screen (pack + loose keypads or a unit count, live total, Undo, running totals), the washer-load entry screen, Vitest and Playwright tests.
- **Dependencies:** React, Tailwind. Skills: FE-01, FE-05.
- **Docs:** https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html
- **Example:** `/feature-slice E1`. frontend.md loads automatically.

#### FE-04 · `control-mobile-ui`

**RULE (frontend.md) · Moderate**

- **Description:** Phone patterns:
  - bottom tabs;
  - works at 360 px;
  - one-handed primary actions;
  - accessible drag-and-drop;
  - freshness chips;
  - a "+1 call" tally button (PRD §8.5).
- **Input:** PRD B1–B2, C1–C4, G1, §6.4; the control routes.
- **Output:** the phone shell (bottom tabs, language switcher, accessibility settings), estimate and queue screens, the "+1 call" tally.
- **Dependencies:** React, React Router, Tailwind, shadcn/ui, dnd-kit. Skills: FE-01, FE-06, RT-01.
- **Docs:** https://web.dev/learn/design/
- **Example:** `/feature-slice C2`

#### FE-05 · `offline-mutations`

**BUILD (task skill) · Complex**

- **Description:** Entry writes (finished goods, washer loads, estimates) that survive Wi-Fi loss and reloads:
  - TanStack Query persisted mutations with an IndexedDB persister;
  - `client_id` generated before the first attempt;
  - ordered replay;
  - server `on conflict (client_id) do nothing`;
  - a pending counter;
  - limits of 8 h or 500 entries.
  - Includes Playwright offline tests: reload and reboot simulation, no duplicates.
- **Input:** the mutation(s) to make offline-safe; PRD E3.
- **Output:** a persister setup in `src/lib/`; mutation defaults; tests proving zero loss and zero duplicates.
- **Dependencies:**
  - `@tanstack/react-query`, `@tanstack/query-async-storage-persister`, `@tanstack/react-query-persist-client`, `idb-keyval`; Playwright `context.setOffline`.
  - Skills: FE-01, DB-04, TEST-02.
- **Docs:**
  - https://tanstack.com/query/latest/docs/framework/react/plugins/persistQueryClient
  - https://tanstack.com/query/latest/docs/framework/react/guides/mutations#persisting-offline-mutations
  - https://github.com/jakearchibald/idb-keyval
  - https://playwright.dev/docs/api/class-browsercontext#browser-context-set-offline
- **Example:** `/offline-mutations record_finished_goods`

#### FE-06 · `i18n-strings`

**BUILD (task skill with script) · Simple**

- **Description:**
  - Adds or updates translation keys in **every enabled locale file** together.
  - Also handles **adding a new language** (e.g., Creole) end to end: the `languages` row, a new `src/locales/<code>.json` with every key, `name_i18n` / `body_i18n` gaps listed for the item setup screen, and enabling it for the plant. **No code or schema change.**
  - A bundled script reports missing or extra keys per locale, hard-coded JSX strings, and hard-coded language lists.
  - **Review (owner decision, 2026-10-27):** translations are checked by a separate AI review pass, not a human. Drafts are marked `needs_review` until that pass clears them, and `languages.ui_ready` stays false until then.
  - **Recommended:** a crew member also reads the short display and keypad strings once per language. This matters most for Creole, which AI handles less reliably.
- **Input:** new keys or English source strings; the target files.
- **Output:** updated locale JSON; a script report.
- **Dependencies:** react-i18next, i18next; a Node script (`${CLAUDE_SKILL_DIR}/scripts/check-keys.mjs`).
- **Docs:**
  - https://react.i18next.com/
  - https://www.i18next.com/overview/getting-started
- **Examples:** `/i18n-strings check` · `/i18n-strings add-language ht`
- **Frontmatter:** `allowed-tools: Bash(node ${CLAUDE_SKILL_DIR}/scripts/check-keys.mjs *)`

#### FE-07 · `pwa-setup`

**ONE-TIME · Moderate**

- **Description:** vite-plugin-pwa config: manifest, icons, offline shell, update prompt (displays auto-apply at the nightly reload), version string for heartbeats.
- **Input:** PRD H4; app name, icons and theme colors.
- **Output:** `vite.config.ts` PWA config, `manifest.webmanifest`, icon set, update prompt component, version string exposed for heartbeats.
- **Dependencies:** `vite-plugin-pwa` (Workbox). Skills: FE-01.
- **Docs:**
  - https://vite-pwa-org.netlify.app/guide/
  - https://developer.chrome.com/docs/workbox
- **Example:** "Set up the PWA per H4."

#### FE-08 · `forms-validation`

**RULE · Simple**

- **Description:** React Hook Form + Zod schemas that mirror the PRD §4.9 rules. The DB stays the final validator, and server error codes map to field errors.
- **Input:** PRD §4.9 validation rules; generated DB types; the PRD §5.1 error codes.
- **Output:** Zod schemas per form, mirroring the DB checks; server-error-to-field mapping; translated messages.
- **Dependencies:** `react-hook-form`, `@hookform/resolvers`, `zod`. Skills: FE-01, FE-06, ERR-01.
- **Docs:**
  - https://react-hook-form.com/docs/useform
  - https://zod.dev/
- **Example:** applied automatically through frontend.md during `/feature-slice A2`.

#### FE-09 · `report-charts`

**EXISTING (`dataviz` skill) · Moderate**

- **Description:** Charts for the shift report and productivity trends (Recharts), using the installed `dataviz` skill's palette and form guidance.
- **Input:** PRD G1–G2, G5; report RPC payloads (`get_shift_report`, `shift_productivity`).
- **Output:** chart components (loads vs. finished per item, trends) that are accessible (data table alternative, not color-only) and translated.
- **Dependencies:** `recharts`; the installed `dataviz` skill for palette and form. Skills: FE-01, DB-06.
- **Docs:** https://recharts.org/en-US/api
- **Example:** `/feature-slice G2`, with `dataviz` loaded when charting.

#### FE-10 · `design-tokens`

**ONE-TIME · Moderate**

- **Description:** Tailwind theme and shadcn tokens for the three surfaces:
  - a display palette verified at ≥ 7:1 contrast;
  - status colors that always come with icons;
  - a type scale.
- **Input:** PRD §6.3 (contrast, sizes, high-contrast mode); brand colors if any.
- **Output:** Tailwind theme tokens, a shadcn theme, a high-contrast variant, a type scale per surface, and a contrast check report (≥ 4.5:1 control, ≥ 7:1 display).
- **Dependencies:** Tailwind CSS, shadcn/ui; optionally `design:design-system`. Skills: TEST-03.
- **Docs:**
  - https://tailwindcss.com/docs/theme
  - https://ui.shadcn.com/docs/theming
- **Example:** "Create the design tokens." Optionally reviewed with `design:design-system`.

#### FE-11 · `voice-input`

**Covered by FE-01 + frontend.md rules · Moderate**

- **Description:**
  - P0: verify every input works with OS keyboard dictation, iOS Voice Control and Android Voice Access (visible label = accessible name).
  - P1: in-app tap-to-talk for finished goods, washer loads, estimates and queue items. The Web Speech API is feature-detected; a pure-TS parser turns "siete paquetes y treinta y cuatro servilletas" into item, packs and loose fields; **a confirm tap is always required**.
  - P2: text-to-speech announcements on displays (`speechSynthesis`).
- **Input:** PRD H6, H7; the user's language; the item names in that language.
- **Output:** a `useVoiceEntry()` hook, the parser with EN/ES unit tests, the mic UI, a device test log (iOS installed app, Android Chrome, Creole).
- **Dependencies:**
  - The browser Web Speech API. Chrome sends audio to Google; tell the user.
  - **Reports say iOS Safari may block recognition in installed apps**, and **Creole recognition is unconfirmed**. Verify both on devices. A server speech-to-text service would be a paid add-on needing approval.
  - Skills: FE-01, FE-06, TEST-03.
- **Docs:**
  - https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API
  - https://caniuse.com/speech-recognition
  - https://www.w3.org/WAI/WCAG22/Understanding/label-in-name.html
  - https://support.apple.com/guide/iphone/use-voice-control-iph2c21a3c88/ios
  - https://support.google.com/accessibility/android/answer/6151848
- **Example:** `/feature-slice H7`, then "test voice entry on Android Chrome in Spanish."

### 4.5 Testing & validation

#### TEST-01 · `unit-tests`

**RULE · Simple**

- **Description:** Vitest for pure logic: conversions, ordering math, freshness, shift boundaries including DST, offline queue. Lives beside the code as `*.test.ts`.
- **Input:** the module under test; PRD acceptance criteria; edge cases (DST, pack overflow, offline replay).
- **Output:** `*.test.ts` files next to the code; passing `npm test`.
- **Dependencies:** Vitest, `@testing-library/react`, `jsdom`. Skills: FE-01.
- **Docs:** https://vitest.dev/guide/
- **Example:** part of `/feature-slice`. The bundled `engineering:testing-strategy` skill helps with planning.

#### TEST-02 · `e2e-tests`

**BUILD (task skill) · Complex**

- **Description:** Playwright end-to-end tests against a local Supabase with seed data:
  - three viewports: display 1920×1080, entry flow on a 1024×600 tablet, control 390×844;
  - **a two-browser test** (phone reorders → display updates ≤ 2 s);
  - offline sync;
  - pairing flow;
  - axe accessibility scan;
  - screenshot baselines.
- **Input:** PRD feature ID or user flow; seed fixtures.
- **Output:** `tests/e2e/<flow>.spec.ts`; HTML report; screenshots.
- **Dependencies:**
  - `@playwright/test` (Chromium is preinstalled in cloud sessions; use `executablePath: /opt/pw-browsers/chromium` if versions differ), `@axe-core/playwright`, Supabase local stack.
  - Skills: FE-02, FE-05, AUTH-03.
- **Docs:**
  - https://playwright.dev/docs/intro
  - https://playwright.dev/docs/accessibility-testing
  - https://playwright.dev/docs/test-snapshots
- **Example:** `/e2e-tests C2-reorder-reaches-display`

#### TEST-03 · `accessibility-check`

**EXISTING + inside TEST-02 · Moderate**

- **Description:**
  - Automated: axe in Playwright on every route, plus a 200% text-scale run.
  - Manual-criteria review with the installed `design:accessibility-review` skill (WCAG 2.2 AA; display at ≥ 7:1).
  - **Before each UI release:** a manual pass on real devices with VoiceOver, TalkBack, iOS Voice Control and Android Voice Access (PRD H6).
- **Input:** routes to check; PRD H6 and §6.3; the real test devices for the manual pass.
- **Output:** axe results in CI (0 serious/critical violations), a 200%-text-scale run, and a manual checklist record per release.
- **Dependencies:** `@axe-core/playwright`, Playwright; VoiceOver, TalkBack, iOS Voice Control, Android Voice Access on devices; the `design:accessibility-review` skill. Skills: TEST-02.
- **Docs:**
  - https://github.com/dequelabs/axe-core
  - https://www.w3.org/TR/WCAG22/
- **Example:** `/design:accessibility-review` on the display route.

#### TEST-04 · `performance-budget`

**ONE-TIME (CI) · Simple**

- **Description:** CI fails if:
  - initial-route JS is > 250 KB gzipped (size-limit); or
  - Lighthouse misses targets on the display and control routes.
- **Input:** the PRD §6.1 budgets (≤ 250 KB gz initial JS; load-time targets).
- **Output:** `size-limit` and Lighthouse CI configs and a CI step that fails over budget.
- **Dependencies:** `size-limit`, `@lhci/cli`, GitHub Actions. Skills: OPS-01.
- **Docs:**
  - https://github.com/ai/size-limit
  - https://github.com/GoogleChrome/lighthouse-ci
- **Example:** runs in CI. No invocation.

#### TEST-05 · `security-review`

**EXISTING · Moderate**

- **Description:**
  - The bundled `/security-review` on diffs.
  - Supabase security and performance advisors via MCP (`get_advisors`) **before every release and in CI**: missing RLS, mutable `search_path`, unindexed FKs.
- **Input:** the current diff; the dev Supabase project.
- **Output:** a findings list from `/security-review` plus the Supabase advisor report (missing RLS, mutable `search_path`, unindexed FKs); fixes or tracked issues.
- **Dependencies:** the bundled `/security-review` skill; Supabase MCP `get_advisors`. Skills: DB-02, DB-03.
- **Docs:**
  - https://supabase.com/docs/guides/database/database-advisors
  - https://code.claude.com/docs/en/commands
- **Example:** `/security-review`; "Run Supabase advisors on dev."

#### TEST-06 · `verify`

**BUILD (task skill, Claude-invocable) · Moderate**

- **Description:** The project's "prove before pushing" check:
  - typecheck → lint → Vitest;
  - `supabase test db` if any SQL changed;
  - Playwright smoke tests if display or entry UI changed;
  - i18n key check;
  - a short pass/fail report.
- **Named exactly `verify`** so Claude Code runs it **automatically before every commit**. That requires leaving `disable-model-invocation` unset.
- **Input:** the current diff (inject `git diff --stat` via `!` context).
- **Output:** pass/fail per check; blocks the commit recommendation on failure.
- **Dependencies:**
  - npm scripts, Supabase CLI, Playwright.
  - Skills: FE-06 script, DB-03, TEST-02.
  - Can be generated initially with the bundled `/run-skill-generator`, then extended.
- **Docs:** https://code.claude.com/docs/en/skills#run-your-checks-before-each-commit
- **Example:** automatic before commits; or `/verify`.

#### TEST-07 · `code-review`

**EXISTING · Simple**

- **Description:** The bundled `/code-review` (and `/simplify`) on PRs.
- **Input:** a PR number, branch or the working diff.
- **Output:** review findings (optionally posted as PR comments, or applied with `--fix`).
- **Dependencies:** the bundled `/code-review` and `/simplify` skills; GitHub MCP for PR comments.
- **Docs:** https://code.claude.com/docs/en/commands
- **Example:** `/code-review high`

### 4.6 Deployment & infrastructure

#### OPS-01 · `ci-pipeline`

**ONE-TIME · Moderate**

- **Description:** GitHub Actions workflows:
  - `ci.yml`: typecheck, lint, Vitest, local Supabase + pgTAP, Playwright, size-limit, advisors.
  - `deploy.yml`: on `main`, `supabase db push`, regenerate types, Netlify deploy.
  - `backup.yml`: see DB-11.
- **Input:** tech-stack.md CI/CD section; repo secrets (names in CLAUDE.md).
- **Output:** `.github/workflows/ci.yml` and `deploy.yml`; a green first run.
- **Dependencies:** GitHub Actions, `supabase/setup-cli`, Netlify CLI, `actions/setup-node`.
- **Docs:**
  - https://docs.github.com/en/actions
  - https://github.com/supabase/setup-cli
  - https://supabase.com/docs/guides/deployment/managing-environments
  - https://docs.netlify.com/cli/get-started/
- **Example:** "Create the CI workflows from tech-stack.md."

#### OPS-02 · `release`

**BUILD (manual-only: `disable-model-invocation: true`) · Moderate**

- **Description:** The guarded release checklist:
  1. confirm `verify` and CI are green;
  2. run the Supabase advisors;
  3. diff pending migrations against prod;
  4. **get the owner's explicit go-ahead**;
  5. merge to `main` (CI deploys);
  6. smoke-test via Playwright against prod;
  7. confirm displays reconnected via heartbeats;
  8. update CLAUDE.md "Current state".
- **Input:** a version label; release notes.
- **Output:** a release log; deployed app; post-deploy check results.
- **Dependencies:**
  - GitHub, Netlify and Supabase MCP servers.
  - Skills: TEST-06, TEST-05, DOC-01.
  - Optionally the existing `engineering:deploy-checklist`.
- **Docs:**
  - https://docs.netlify.com/deploy/deploy-overview/
  - https://supabase.com/docs/reference/cli/supabase-db-push
- **Example:** `/release v0.3.0`
- **Why manual-only:** the docs explicitly recommend this for deploys.

#### OPS-03 · `cloud-session-setup`

**EXISTING (`session-start-hook` skill) · Simple**

- **Description:** A SessionStart hook so cloud sessions install dependencies and can run lint and tests.
- **⚠️ Cloud sessions may not run Docker,** so the local Supabase stack can fail there. Plan pgTAP and e2e runs for CI or a local machine, and note it in CLAUDE.md once verified.
- **Input:** the project's install and test commands (`package.json`).
- **Output:** a SessionStart hook in `.claude/settings.json` that installs dependencies; a note in CLAUDE.md on what can and can't run in cloud sessions (e.g., Docker).
- **Dependencies:** Claude Code hooks; the installed `session-start-hook` skill; npm.
- **Docs:**
  - https://code.claude.com/docs/en/hooks
  - https://code.claude.com/docs/en/claude-code-on-the-web
- **Example:** `/session-start-hook`

#### OPS-04 · `env-secrets`

**RULE + HOOK · Simple**

- **Description:**
  - Rule: the variable names in CLAUDE.md; `.env.example` with names only.
  - **Hook:** `PreToolUse` blocks writes of anything that looks like a key into tracked files, and blocks reading `.env*` values into output.
  - GitHub secret scanning stays on.
- **Input:** the environment variable names in CLAUDE.md.
- **Output:** `.env.example` (names only), `.gitignore` entries, a `PreToolUse` secret-guard hook, and GitHub secret scanning enabled.
- **Dependencies:** Claude Code hooks; GitHub secret scanning; Netlify/Supabase/GitHub secret stores.
- **Docs:**
  - https://code.claude.com/docs/en/hooks
  - https://docs.github.com/en/code-security/secret-scanning
- **Example:** automatic.

#### OPS-05 · `monitoring-setup`

**ONE-TIME · Simple**

- **Description:** Sentry React SDK with release and version tags; source maps uploaded in CI; heartbeat RPC wiring; uptime check on the app URL.
- **Input:** the Sentry DSN and auth token (names only in repo); PRD D4 and §6.1.
- **Output:** Sentry initialized with release, plant and device tags; source maps uploaded in CI; an uptime check; heartbeat wiring verified.
- **Dependencies:** `@sentry/react`, `@sentry/vite-plugin`; an uptime monitor (e.g., UptimeRobot). Skills: OPS-01, ERR-01.
- **Docs:**
  - https://docs.sentry.io/platforms/javascript/guides/react/
  - https://docs.sentry.io/platforms/javascript/guides/react/sourcemaps/
- **Example:** "Set up Sentry per tech-stack.md."

#### OPS-06 · `kiosk-device-setup`

**ONE-TIME (runbook, non-code) · Simple**

- **Description:** Written steps for configuring an Android TV box with Fully Kiosk Browser:
  - start URL;
  - auto-launch on boot;
  - screensaver off;
  - daily reload;
  - remote admin;
  - Wi-Fi.
  - Plus a pairing walkthrough in Spanish.
- **Input:** the chosen TV boxes and kiosk browser; plant Wi-Fi details; the pairing flow (A7).
- **Output:** `docs/runbooks/display-setup.md`.
- **Dependencies:** Fully Kiosk Browser (or ChromeOS kiosk); Android TV boxes. Skills: AUTH-03, the `engineering:documentation` skill.
- **Docs:** https://www.fully-kiosk.com/en/#manual
- **Example:** "Write the display setup runbook." The existing `engineering:documentation` skill can help.

### 4.7 Documentation

#### DOC-01 · `update-memory`

**BUILD (task skill) · Simple**

- **Description:** At the end of a working session:
  - update the "Current state" section in `.claude/CLAUDE.md` (built / in progress / waiting / debt);
  - correct the commands and file map once they're real;
  - keep the file under 200 lines;
  - propose, never silently make, changes to architecture rules.
- **Input:** the session's commits (`git log` since the last update, injected) plus the conversation.
- **Output:** a CLAUDE.md diff for review.
- **Dependencies:** git. The bundled `/doctor prompt-audit` handles a periodic deeper audit.
- **Docs:** https://code.claude.com/docs/en/memory
- **Example:** `/update-memory`

#### DOC-02 · `decision-record`

**EXISTING (`engineering:architecture`) · Simple**

- **Description:** An ADR whenever an architecture decision changes. Examples: a numeric vs. text fractional index; adding a Python worker for Accu-Flow.
- **Input:** the decision, options considered, and their trade-offs.
- **Output:** `docs/adr/NNN-title.md`.
- **Dependencies:** the installed `engineering:architecture` skill.
- **Docs:** https://adr.github.io/
- **Example:** `/engineering:architecture Accu-Flow ingestion via email vs API`

#### DOC-03 · `crew-communications`

**DEFER (needs HR/legal) · Moderate**

- **Description:** A plain-language notice in EN/ES/HT explaining what the wall screens are for and that **no individual output is recorded**. PRD §6.2 #11 requires it before launch.
- **Input:** PRD §6.2 #11; what the screens show and what is (not) recorded; the enabled languages.
- **Output:** a draft only. **HR/legal approves the final.**
- **Dependencies:** HR/legal approval (required); the `legal:compliance-check` skill can help scope it. Skills: FE-06 for translations.
- **Docs:** https://www.dol.gov/agencies/whd/flsa (context for why payroll use is excluded)
- **Example:** "Draft the crew data notice."

#### DOC-04 · `api-reference`

**RULE · Simple**

- **Description:**
  - Every RPC and Edge Function carries a `comment on function` or header doc with signature, roles and error codes.
  - The PRD §5 remains the spec. Generating separate API docs isn't worth it for an internal app.
- **Input:** each RPC's and Edge Function's signature, roles and error codes (PRD §5).
- **Output:** `comment on function` text and Edge Function header docs; visible via generated types and the Supabase dashboard.
- **Dependencies:** Postgres `COMMENT`. Skills: DB-04, EDGE-01.
- **Docs:** https://www.postgresql.org/docs/current/sql-comment.html
- **Example:** enforced through DB-04 and EDGE-01.

### 4.8 Error handling & logging

#### ERR-01 · `error-handling`

**RULE (extend frontend.md and database.md) · Moderate**

- **Description:** One error contract across layers:
  - DB raises the PRD §5.1 codes;
  - Edge Functions return `{ code, message }`;
  - the client maps each code to an i18n message and an action (refetch on `QUEUE_VERSION_CONFLICT`, highlight the pack/loose fields on `COUNT_MODE_MISMATCH`);
  - unexpected errors go to Sentry with user, device and plant tags (no PII beyond IDs);
  - React error boundaries per surface, so a display never shows a blank screen.
- **Input:** PRD §5.1 error codes; the i18n message catalog; Sentry setup.
- **Output:** a shared `errors.ts` mapping codes to messages and actions; error boundaries per surface; tests that each code renders a translated, actionable message.
- **Dependencies:** React error boundaries, `@sentry/react`, react-i18next. Skills: FE-06, OPS-05.
- **Docs:**
  - https://react.dev/reference/react/Component#catching-rendering-errors-with-an-error-boundary
  - https://docs.sentry.io/platforms/javascript/guides/react/features/error-boundary/
- **Example:** applied automatically through the rules.

#### ERR-02 · `instrumentation`

**Covered by FE-01 + DB-06 · Moderate**

- **Description:**
  - `app_events` for the PRD §8.5 event names, including the display latency sample.
  - The `weekly_success_metrics` view.
  - The "+1 call" tally.
  - These are the only reliable way to prove the north-star metric.
- **Input:** the PRD §8.5 event list and §8.3 targets.
- **Output:** a typed `track(event, props)` helper writing to `app_events`; the `weekly_success_metrics` view; the "+1 call" tally button.
- **Dependencies:** `supabase-js`; Postgres views. Skills: FE-01, DB-06.
- **Docs:** https://supabase.com/docs/guides/database/tables
- **Example:** part of `/feature-slice` and `/reporting-views weekly_success_metrics`.

#### ERR-03 · `edge-logging`

**RULE (edge-functions.md, already present) · Simple**

- **Description:** Structured `console.log` JSON; never secrets, tokens or bodies. Read through the Supabase logs (MCP `get_logs`).
- **Input:** the Edge Function being written.
- **Output:** structured JSON log lines (`level`, `fn`, `plant_id`, `code`, `duration_ms`) with no secrets or bodies.
- **Dependencies:** Supabase Edge Functions logging; Supabase MCP `get_logs`. Skills: EDGE-01.
- **Docs:** https://supabase.com/docs/guides/functions/logging
- **Example:** applied automatically through `edge-functions.md` whenever `/edge-function` runs.

### 4.9 Domain knowledge

#### DOM-01 · `laundry-domain`

**BUILD (reference skill, `user-invocable: false`) · Moderate**

- **Description:** Background knowledge Claude loads when working on any feature:
  - the glossary (soil, wash load, washroom, finishing, counting unit, pack + loose, pieces per load, shift instance, formula);
  - **the measurement model: no scale, so never weights.** Loads are the unit, and `app.to_loads()` semantics apply;
  - reconciliation is approximate ("≈"), and how pieces per load is calibrated;
  - overnight-shift and **DST** logic (DB-12);
  - the Accu-Flow/Milnor facts and what is still unknown;
  - fairness guardrails (team totals on screens; not payroll);
  - the "waiting on owner" values that must never be invented.
- Kept out of CLAUDE.md so it costs context only when relevant.
- **Input:** none (reference).
- **Output:** correct domain behavior in other skills' work.
- **Dependencies:** none. Other skills reference it.
- **Docs:** `research/PRD.md` §0.1, `research/viability-analysis.md` §6.
- **Example:** loaded automatically when the description matches, e.g., "shift report", "packs of napkins", "pieces per load", "Accu-Flow".

---

## 5. Hooks (rules that must always hold)

The docs say rules that must hold every time belong in hooks. These four go in `.claude/settings.json`:

| Hook | Event | Effect |
|---|---|---|
| Regenerate DB types | `PostToolUse` (Write/Edit on `supabase/migrations/**`) | Runs `supabase gen types typescript --local > src/types/database.ts` |
| Protect generated types | `PreToolUse` (Write/Edit on `src/types/database.ts`) | Deny with "generated file — run type generation" |
| Block production writes | `PreToolUse` (Bash) | Deny `supabase db push`, `supabase db reset --linked` and `psql` against the prod URL unless invoked from the `release` flow; deny `git push origin main` and `--force` |
| Secret guard | `PreToolUse` (Write/Edit) | Deny content that matches key patterns (`sk_`, `eyJ` JWTs, `service_role`) in tracked files |

---

## 6. What this inventory deliberately does NOT recommend

- **A skill per CRUD table or per screen.** The general skills (`schema-migration`, `feature-slice`) take the table or feature as an argument. Forty near-duplicate skills would blow the description budget.
- **Duplicating bundled skills:** `/code-review`, `/security-review`, `/debug`, `/run`, `/simplify`, `/doctor`.
- **Skills for blocked work:** Accu-Flow import/sync, crew notice. Write them when the input exists. A skill built on a guessed CSV format would encode the guess.
- **`context: fork` for build skills.** A forked subagent doesn't see the conversation. Reserve it for self-contained tasks (e.g., a future "audit all RLS policies" sweep with `agent: Explore`).

## 7. Open questions for you

1. Are you OK with **17 project skills** rather than one per capability? The docs' context limits are why.
2. Should `release` require **you** to type `/release` every time (my recommendation), or can Claude propose it?
3. ~~Who reviews translations?~~ **Decided:** an AI review pass, with a recommended native-speaker spot check of display strings.
4. Can CI run Docker (GitHub-hosted runners can)? Then local-Supabase tests run there even if cloud sessions can't run Docker.

