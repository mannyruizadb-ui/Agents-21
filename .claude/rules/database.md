---
paths:
  - "supabase/migrations/**"
  - "supabase/tests/**"
  - "supabase/seed.sql"
---

# Database rules (Supabase Postgres)

The source of truth is `research/PRD.md` §4: DDL, triggers, views, RLS matrix, indexes and validation.

## Migrations
- Create with `supabase migration new <verb_noun>`. **Never edit a migration that has been pushed.** Add a new one instead.
- One concern per migration (tables, then RLS, then functions).
- Every migration must be re-runnable from scratch with `supabase db reset`.
- After any schema change, regenerate `src/types/database.ts` and commit it in the same change.

## Tables
- Default columns:
  - `id uuid primary key default gen_random_uuid()`
  - `created_at timestamptz not null default now()`
  - `updated_at` maintained by the `app.touch_updated_at()` trigger where rows are mutable
- Tenant scoping:
  - Every operational table has `org_id` + `plant_id`, with a composite FK `(plant_id, org_id) references plants(id, org_id)`.
  - Child references use `(x_id, plant_id)` composite FKs, which needs `unique (id, plant_id)` on the parent.
- Types and constraints:
  - Quantities: `numeric(12,2)`. Conversion factors: `numeric`. **Never float.**
  - Text length is enforced with `check (char_length(..) ...)`.
  - Enums live in schema `app`.
- Index every FK column. Use partial indexes for active subsets (e.g., `status in ('queued','in_progress')`, `voided_at is null`).
- No hard deletes on `production_logs`, `washer_cycles`, `queue_items`, `soil_estimates`. Enforce with triggers.

## RLS (mandatory)
- `alter table ... enable row level security;` in the **same migration** that creates the table.
- Policies call the helpers `app.has_role(plant_id, roles[])` and `app.my_device()`.
- Wrap helpers as `(select auth.uid())` and `(select app.has_role(...))` so Postgres caches them per statement.
- Device roles:
  - `display`: SELECT only, limited to its area's data.
  - `station`: INSERT only to its own station (plus the reads it needs).
- `operators.pin_hash` must never be selectable by clients. Expose the `operators_public` view instead.
- Views use `with (security_invoker = true)`.
- Add only the needed tables to the `supabase_realtime` publication: `queue_items`, `soil_estimates`, `display_messages`.

## RPC functions
- `security definer`, `set search_path = ''`, schema-qualified names everywhere.
- Check the caller's role explicitly at the top of every function, and validate every argument.
- Raise app errors as `raise exception 'CODE' using detail = '...'`, using the codes in PRD §5.1 (`QUEUE_VERSION_CONFLICT`, `PIN_INVALID`, …).
- Optimistic concurrency: queue writes take `p_expected_version` and compare it to `version`.
- Idempotent inserts: `on conflict (client_id) do nothing`, then return the existing row.

## Tests (pgTAP, `supabase test db`)
- **Every table gets a test file asserting the PRD §4.7 access matrix for each role:** owner, manager, lead, viewer, display, station, anon.
- Include negative tests:
  - cross-tenant reads and writes are denied;
  - a station cannot write to another station;
  - a display cannot write anything.
- Test that CHECK and validation rules reject bad data, not just that good data passes.
