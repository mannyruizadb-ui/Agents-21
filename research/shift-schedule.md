# Shift Schedule: ADB Miami plant (seed source for `shifts`)

*Received from the owner 2026-10-30. Source for `supabase/seed.sql`. Times are local (America/New_York). Days are the day a shift **starts**. Status: ✅ confirmed by owner · 🔸 my reading of the owner's description (confirm).*

## Key facts

- **The plant runs in two blocks a week:**
  - **Block 1:** Mon afternoon → Wed night (finishing runs into Thu ~5 a.m.).
  - **Block 2:** Thu afternoon → Sat midnight.
- **Sunday is closed.** ✅ Daylight-saving changes happen Sunday at 2 a.m., so **no shift ever spans a DST change.**
- **Washroom and finishing have different shift times**, so shifts are defined **per area** (PRD v1.3, A6).
- Times are approximate ("sometimes later"). The schedule defines which shift a record belongs to; it doesn't police hours.

## Finishing (ironing, folding, packing)

| Shift | Start | End | Starts on | Status |
|---|---|---|---|---|
| Evening | 16:00 | 24:00 | Mon, Tue, Wed, Fri, Sat | ✅ ("4 p.m. to 12") |
| Evening (Thu) | 17:00 | 24:00 | Thu | ✅ ("Thursday… 5 p.m. to 12 a.m.") |
| Night | 00:00 | 10:00 | Tue, Wed, Fri, Sat | ✅ ("12 a.m. to 10 a.m.") |
| Night (Thu, short) | 00:00 | 05:00 | Thu | 🔸 ("we finish Thursday at like 5 a.m.") |
| Day | 10:00 | 16:00 | Tue, Wed, Fri, Sat | ✅ nominal. The real handover varies (night crew sometimes stays until 12), which is why entries **follow the person** (below) |

**Week view (finishing):**

| | Mon | Tue | Wed | Thu | Fri | Sat | Sun |
|---|---|---|---|---|---|---|---|
| 00–10 Night | — | ✔ | ✔ | ✔ (to 05:00) | ✔ | ✔ | — |
| 10–16 Day | — | ✔ | ✔ | — | ✔ | ✔ | — |
| 16–24 Evening | ✔ | ✔ | ✔ | ✔ (from 17:00) | ✔ | ✔ | — |

## Washroom

| Shift | Start | End | Starts on | Status |
|---|---|---|---|---|
| Evening | 14:00 | 24:00 | Mon, Tue, Wed, Fri, Sat | ✅ ("2 to 12 midnight": carpets, sheets, butcher coats) |
| Evening (Thu) | 15:00 | 24:00 | Thu | ✅ ("Thursday it starts back up at 3 p.m.") |
| Night | 00:00 | 12:00 | Tue, Wed, Fri, Sat | ✅ ("midnight to about midday": all other items) |

**Week view (washroom):**

| | Mon | Tue | Wed | Thu | Fri | Sat | Sun |
|---|---|---|---|---|---|---|---|
| 00–12 Night | — | ✔ | ✔ | — | ✔ | ✔ | — |
| 14–24 Evening | ✔ | ✔ | ✔ 🔸 | ✔ (from 15:00) | ✔ | ✔ | — |

🔸 Wednesday washroom "done by around 8 p.m., maybe midnight". It's scheduled to midnight, the later bound. Finishing early is fine; the schedule only decides which shift a record belongs to.

## How this works in the app (owner decisions 2026-10-30, PRD A8)

- **Every entry is confirmed with name + 4-digit PIN** (data-entry staff only: owner, managers, leads). This records who entered it, not per-worker production.
- **Entries follow the person:** each staff member has a **home shift**. An entry counts toward the current or most recent instance of that shift, so a night crew staying until noon still counts as night. The entry screen offers **"My shift" / "Next shift"** for handovers.
- **Washroom noon–2 p.m. helper:** ✅ no shift and no shift report. Any loads he records are off-shift and count in the **day totals**, so day reconciliation stays complete.
- The clock-based schedule above is the fallback, used when an entry has no staff home shift.
- **Reports:**
  - each area gets a **shift report**;
  - **washroom vs. finishing reconciliation is per business day**, because the two areas' shifts don't line up (PRD v1.3, G1).

## Open questions (don't block the build; the defaults above apply until answered)

1. ~~Finishing day shift start~~ **Answered:** it varies (10 or 12), so attribution follows the person (A8).
2. ~~Washroom midday~~ **Answered:** no shift, no report; loads count in day totals.
3. **Production day start** (for day-level reconciliation): pending, with 14:00 proposed (see the architect's ADR question).
4. **Holidays and unusual weeks:** for now a manager can mark a shift "didn't run", which hides it from reports (P1). Is there a fixed holiday list?
