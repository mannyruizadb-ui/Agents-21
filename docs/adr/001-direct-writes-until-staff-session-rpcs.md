# ADR 001: Direct client writes in M1, PIN-confirmed RPCs only from M2

- **Status:** Accepted (meta, 2026-11-01). Architect draft from the M1 plan review.
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
