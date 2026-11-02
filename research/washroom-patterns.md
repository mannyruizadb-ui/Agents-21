# Washroom patterns (owner, 2026-11-02)

**Status:** this is how the washroom runs today, as the owner described it. **Not rules.** The owner said "it's all changeable, don't just take my numbers right now". Nothing here is hard-coded. Each pattern becomes an owner-approved rule only after the app's own data confirms it (see "Learning from the data" below).

## Typical evening (washing starts Monday 14:00; production day runs 12:00 → 12:00)

| When | Washers | What | Notes |
|---|---|---|---|
| 14:00 → about 22:00–24:00 | 1–3, sometimes 1–4 | Floor mats ("straight carpets"), formula 1 / 6 | Mats run first |
| All night, past midnight | 5–6 | Sheets, formula 2 | Sheets keep going all night |
| Around 19:00–20:00 | 6 | Kitchen towels, formula 5 | |
| Start by about 21:00–21:30 | whichever is free | Butcher coats, formula 3 | About 2 h door-to-door, in practice longer than the 88-min program |
| As mats finish | 1–4 | Linens per the owner's queue | |

Rewash: the finishing staff pull items that came out dirty and send them back to the washroom. Rewash is a queue item, and its loads are excluded from washed-vs-finished reconciliation.

## Learning from the data

There is no machine learning here: plain statistics on the washman's taps. The point is to show the owner what actually happens. The app never changes the plan on its own.

1. **Weeks 1–4, run it manually.**
   - The owner queues work and pins loads to washers when wanted. Unpinned loads go to the next free washer.
   - The washman taps each start. Every tap records the group, washer, start time and formula.
2. **Pattern report (after about 3–4 weeks).** For each wash group, it shows:
   - which washers it ran on, and what share of the time;
   - usual start-time windows;
   - real turnaround: the time from one start to the next start on the same washer, including loading and unloading, against the program time.

   Example: "Butcher coats started 20:40–21:35 on 18 of 20 nights; real turnaround 1 h 58 min."
3. **Standing rules: proposed by the app, approved by the owner, switchable on and off.**
   - **Lane rule:** "Washers 5–6 default to Sheets." An unpinned sheets load prefers 5–6. The owner can still pin anything anywhere.
   - **Deadline rule:** "Butcher coats must start by 21:30."
     - At 21:00 the queue moves them up.
     - The TV and the owner's phone show a warning if they haven't started.
     - At 21:30 the owner gets a single alert.
   - **Daily template:** a default evening queue the owner can load in one tap and then edit.
4. **Ongoing.** The report keeps running, so it shows when reality drifts from a rule (for example, kitchen towels moved to 21:00).

Build order: lane and deadline rules are worth the most. The template comes later. None of this is built before the pilot has about 3 weeks of tap data.
