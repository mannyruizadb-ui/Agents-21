# ADR 001: Direct client writes in M1, PIN-confirmed RPCs only from M2

- **Status:** Accepted (meta, 2026-11-01). Architect draft from the M1 plan review.
  **Implemented in M2 (2026-11-04, migration `20261103212048_revoke_direct_operational_writes.sql`):**
  the policies `soil_estimates_insert`, `queue_items_insert`, `queue_items_update`, `fge_insert` and
  `washer_cycles_insert` are dropped, and INSERT/UPDATE/DELETE/TRUNCATE are revoked from `anon` and
  `authenticated` on `queue_items`, `soil_estimates`, `washer_cycles` and `finished_goods_entries`
  (this includes the security carry-forward `revoke update on washer_cycles`). The only client write
  paths are now the SECURITY DEFINER RPCs: the queue RPCs, `start_washer_load` / `undo_washer_load`,
  `record_soil_estimate`, `record_finished_goods` and `void_finished_goods`. pgTAP 050/051/060/061
  assert 42501 for every role on direct writes.
  **Amendment (owner decisions 2026-11-02/03):** washer start-taps carry no name or PIN (station
  attribution: `entered_by` = the signed-in account, `staff_id` null), and queue writes from the
  owner's phone carry no staff session. Estimates and finished goods keep name + PIN.
  Setup tables (items, wash groups, machines, formulas, shifts, areas, stations) are outside this ADR:
  they keep direct, RLS-guarded, audited writes, column-limited since `20261103212053`.
- **PRD:** A8 (entry staff + PIN), §4.7, §5.3.

## Context

PRD A8 requires every data entry to be confirmed with a staff name and 4-digit PIN, through
write RPCs that take a `staff_session_id`. The §4.7 RLS matrix also allowed direct client
inserts on `soil_estimates`, `washer_cycles` and `finished_goods_entries`. That left a path
that skips staff attribution.

## Options

- A: keep the direct writes; staff attribution stays optional.
- B: allow the direct writes during M1, while no write RPCs exist. In M2, once the
  staff-session write RPCs land, revoke direct INSERT/UPDATE on those tables.
- C: add a trigger that requires a valid staff session on direct inserts.

## Decision

**B.** The direct-insert policies stay in M1, with guards:
- with_check pins `entered_by = auth.uid()`;
- `washer_cycles.source = 'manual'`;
- finished goods can't be inserted pre-voided;
- there is no direct UPDATE on finished goods (voids go through an RPC).

M2 drops the policies `fge_insert`, `washer_cycles_insert` and `soil_estimates_insert`, and
updates pgTAP tests 050/060 to match.

## Consequences

- Until M2, attribution can be bypassed. There are no real users before M2, so the risk is low.
- Every SECURITY DEFINER write RPC must check the caller's role on the target plant before
  writing, because definer functions bypass RLS (M1 security re-review N1;
  `.claude/rules/database.md`).
