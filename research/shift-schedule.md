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
| Day | 10:00 | 16:00 | Tue, Wed, Fri, Sat | 🔸 ("around 10 or 12 to around 4"; "really like 10 to 4") |

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
| Midday | 12:00 | 14:00 | Tue, Wed, Fri, Sat | ✅ ("12 to 2": some washing, then helps unload drivers) |

**Week view (washroom):**

| | Mon | Tue | Wed | Thu | Fri | Sat | Sun |
|---|---|---|---|---|---|---|---|
| 00–12 Night | — | ✔ | ✔ | — | ✔ | ✔ | — |
| 12–14 Midday | — | ✔ | ✔ | — | ✔ | ✔ | — |
| 14–24 Evening | ✔ | ✔ | ✔ 🔸 | ✔ (from 15:00) | ✔ | ✔ | — |

🔸 Wednesday washroom "done by around 8 p.m., maybe midnight". It's scheduled to midnight, the later bound. Finishing early is fine; the schedule only decides which shift a record belongs to.

## How this works in the app

- **Every washer load and finished-goods entry is tied to the shift running in its area at that moment.** A night-shift entry at 3 a.m. Tuesday belongs to Tuesday's night shift.
- **Staying late ("sometimes later"):** an entry after the boundary lands in the next shift by default. The manager can assign it to the previous shift when entering (PRD E1 allows the current or previous shift).
- **Reports:**
  - each area gets a **shift report**;
  - **washroom vs. finishing reconciliation is per business day**, because the two areas' shifts don't line up (PRD v1.3, G1).

## Open questions (don't block the build; the defaults above apply until answered)

1. **Finishing day shift: 10:00 or 12:00 start?** If it's 12:00, nobody covers 10–12 (night ends at 10). The default is **10:00–16:00**.
2. **Washroom midday (12–2):** keep it as its own shift in reports, or **fold it into the night shift** (00:00–14:00)? A 2-hour shift that also unloads trucks makes a thin report. **Recommendation: fold it in.**
3. **Holidays and unusual weeks:** for now a manager can mark a shift "didn't run", which hides it from reports (P1). Is there a fixed holiday list?
