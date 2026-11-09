# PlantBoard app review: 2026-11-09

The owner asked: *"Review the whole app and make sure everything is logical and makes sense. If it's useless, review it with me and let's get rid of it or upgrade it."*

**How this was checked**
- Code: `main` at 8edd0c8, run locally (`db:reset`, seed, local owner, and a manager account "denise" made through People).
- Sample data:
  - 12 dirty-work estimates: mats in baskets; napkins, tablecloths and kitchen towels in bins; sheets and mops in loads.
  - 1 rush item and 1 rewash.
  - 5 washer starts, one of them off-queue.
  - Washer 5 and the Ironer down.
  - 1 AA Linen delivery (3 groups).
  - 2 tasks for Denise.
  - Load-out for Tuesday's 4 routes.
- Screenshots: every control screen, as owner and as manager, at 1920×1080, 1180×820 and 390×844, plus a Spanish pass as manager. They are in the session scratchpad `review/` folder; they are not committed.
- Rules kept: no per-person output or rankings, no weights.

**Verdicts:** KEEP = fine as is. UPGRADE = keep the screen, change something concrete. CUT = remove.

---

## 1. The big picture: four problems that run through the whole app

1. **The same pile of dirty work shows three different numbers.** With the same data at the same moment:

   | Where | What it said |
   |---|---|
   | Home (owner), "Hours of work waiting" | ≈ **50.75** loads, ≈ 8 h 0 min |
   | Home (manager), "Dirty work waiting" | ≈ **50.8** loads |
   | Home tile "Queue" and Queue header | 16 items · ≈ **59** loads |
   | Estimates row "Black mats" | 3 baskets ≈ **10.5** loads |
   | Queue item / Washers "Next in queue" / Station "Next" | 3 baskets · ≈ **9** loads left |
   | Dashboard "AA Linen waiting" | **8** loads not started |
   | Queue, AA Kitchen towels and AA White napkins | "3 bins · ≈ **0** loads left" ← wrong |
   | Customer deliveries, same AA lines | "3 bins · loads **unknown**" ← right |

   - Why: estimates leave out AA work, the rewash and loads already in washers, while the queue counts everything. Each screen picks its own source and rounds its own way (50.75 vs 50.8 vs ≈ 9).
   - The owner cannot tell which number to trust. This is the main reason the dashboard feels "useless".

2. **Too many words for one thing.**
   - The same idea is called "Estimates", "Dirty work waiting", "Work waiting", "Hours of work waiting" and "Waiting now".
   - The same AA job is called "Record a delivery", "Customer deliveries" and the "AA Linen" tab.
   - Pick one word per idea:
     - **Dirty work** = what is out there.
     - **Queue** = the washing order.
     - **AA drop-off** = AA arrivals.

3. **Units switch halfway through a line.**
   - People enter **baskets/bins**, but cards answer in **loads**, with decimals ("10.5", "5.19 standard loads", "50.75").
   - Rule: show what was entered first (3 baskets), then "≈ N loads" rounded to a whole load, and nothing more.
   - Decimal loads mean nothing on the floor.

4. **Owner screens are long because every item carries every control.**
   - On the phone, the queue is **7,100 px** tall for 16 items. Each card has a washer picker, Move up, Move down, Make RUSH and Cancel.
   - On Estimates, each of 30 rows has its own "Nothing waiting" button.
   - Collapse the actions behind one tap on the item.

---

## 2. Screen by screen

### Home: owner dashboard (`/control`, owner)
**Purpose:** the owner's morning and evening glance from desktop or phone: is the plant OK, and what is waiting?

**Useful**
- The top tiles: Machines down (with reason), Next truck countdown, Tasks, Queue. They are clear and tap through.
- "Washers right now" (5 of 6 running, plus a status bar).
- "AA Linen waiting" as its own card.
- "Done around 11:48 PM": a good, plain promise.

**Useless or confusing**
- **"Work waiting by wash group"** (the owner's complaint):
  - It lists 12 wash groups as *hours bars*.
  - The owner thinks in "how many baskets of black mats are out there", not "1 h 30 min of kitchen towels".
  - The hours depend on how many washers are up (they are divided by working capacity), so the bars change when Washer 5 breaks even though the pile did not.
  - The bar colours are the group colours: white, black and grey bars on a dark card. They carry no meaning, and "Black mats" is nearly invisible.
  - It shows the top 12 groups and hides the rest behind "Show all 12".
- **"Hours of work waiting" and "Work waiting by wash group" say the same thing twice.** One big number, then the same number split up. Merge them (proposal in § 3).
- **"Loads washed today: 5.19 standard loads".**
  - 5 starts happened. The ".19" is Washer 6's load factor leaking into the headline.
  - Show "5 loads started", with the standard-load figure only in the report.
- **"Off-queue today"** takes a full-height card for a single number. It shows 4 bars, 3 of them zero.
  - Make it one line inside the Washers card ("1 start off the queue today: Urgent"), and show it only when it isn't 0.
- **"Finished goods today"** is a placeholder ("the finishing entry screen is coming"). Hide it until that screen exists.
- On 1920×1080 the bottom row is cut off below the fold, so the most important card in the owner's request is the one he scrolls for.

**Verdict:** UPGRADE.
- Replace "Hours of work waiting" + "Work waiting by wash group" with one **"Dirty work out there"** card, grouped by category (§ 3).
- Fold "Off-queue" into the Washers card.
- Hide "Finished goods" until it is built.
- Round loads to whole numbers.

### Home: manager (`/control`, manager)
**Purpose:** the manager's glance on the shared iPad or her phone.

**Useful:** Washers 5/6, Machines down, My tasks, Next truck, Queue. A clean tile layout.

**Confusing**
- "Dirty work waiting ≈ 50.8" sits next to "Queue 16 items · ≈ 59 loads". Two "how much is waiting" tiles that disagree (see § 1).
- Keep one: the dirty-work tile, split by category, the same as the owner's (§ 3).

**Verdict:** UPGRADE. One "Dirty work" tile; drop the loads number from the Queue tile (show "16 items, next: Black mats").

### Washers board (`/control/washers`)
**Purpose:** everyone sees what each washer is doing and when it frees up.

**Useful**
- Big minutes left, the group name with its colour bar, the DOWN cards with reason, "Next in queue" once at the top, "Other machines down".
- Works well at all 3 sizes.

**Confusing**
- "No. 4 · 59 min" under each washer. The washman knows "No. 4" is the Milnor formula; the owner and managers won't. Label it **"Formula 4 · 59 min"**.
- "3 baskets · ≈ 9 loads left": the 9 comes from 10.5 loads minus 2 started, rounded, but the Estimates screen says 10.5 for the same group. Show "≈ 9 loads left (of 3 baskets)", or just "≈ 9 loads left".
- "Done, to unload" never showed (0) while Washer 2 had finished its cycle. Worth confirming how "done" is decided.

**Verdict:** KEEP, with the 2 label fixes.

### Washer station (`/station/washer/:id`)
**Purpose:** a tablet at one washer, used by the washman with gloves on. One tap = load started.

**Useful**
- NOW / NEXT, a huge START, the countdown, "Starts: Black mats (next in the queue)", "Other wash group".
- Spanish (EMPEZAR, Ahora/Próximo) reads well.

**Confusing**
- "3 baskets · ≈ 9 loads left" under NEXT means nothing to the washman. What he needs is the formula number and whether it is rush.
- The "All washers" link on a kiosk tablet sends the crew off the station. It is fine for the pilot, while the owner taps from his phone.

**Verdict:** KEEP.
- Under NEXT, show the **formula number** instead of baskets/loads.
- Hide "All washers" when the station runs in kiosk mode (later, with the tablets).

### Queue (`/control/queue`)
**Purpose:** the owner sets the washing order; managers view it, add rewash and move loads off a broken washer.

**Useful**
- The "From estimates" tag (estimates fill the queue automatically: a big win).
- The Rush and Rewash filters.
- The manager notice that explains what she can and can't do.
- AA Linen badge on customer items.

**Useless or confusing**
- **Length:** each card has a washer `<select>`, Move up, Move down, Make RUSH and Cancel. 16 items = 7,100 px on the phone and 5,900 px on the desktop, which uses only a narrow middle column.
- **Moving is slow:** moving item #14 to the top takes 13 taps of "Move up". The owner's main job here is ordering, and this is the slowest possible way to do it.
- **"≈ 0 loads left"** on AA groups that have no bin factor (Kitchen towels 3 bins, White napkins 1½ bins). This is a wrong number: it should say "loads unknown", as Deliveries does, and it pulls the AA total down (the dashboard says 8 loads instead of 8 + unknown).
- "Added by Manny Ruiz" on every card. It's allowed for the owner (2026-11-06), but on an owner-only queue it is always his own name: noise. Show it only when someone else added the item (rewash by a manager, an estimate by Denise).
- The **"Area: Washroom"** picker: only one area has a queue. Hide it when there is one.
- The "Rush (0)" filter takes space while it's empty.

**Verdict:** UPGRADE.
- One-line items: colour, name, "3 baskets ≈ 9 loads", badges.
- Tap an item to open its actions: washer, Rush, Cancel, **"Move to top"**, **"Move to position…"**.
- Add drag-to-reorder on desktop and tablet (dnd-kit is already in the stack).
- Fix the ≈ 0 → "loads unknown".

### Estimates: "Our work" (`/control/estimates`)
**Purpose:** a manager (Denise) or the owner says what is out there dirty. It now also fills the queue.

**Useful**
- The category chips with counts (Napkins 3, Mats 4…).
- "12 of 30 wash groups estimated" plus the "Needs estimate (18)" filter.
- The last value and time on each row.
- The two-column desktop list.

**Useless or confusing**
- **"Nothing waiting" button on all 30 rows**, including rows that *have* something waiting (Black mats, 3 baskets). It reads like a status ("there's nothing waiting") when it is an action ("set to zero"). It's the most confusing control in the app. Move it inside the row's editor as "None left (0)".
- The "Waiting now ≈ 50.75 loads" summary block repeats the dashboard card with different rounding. Use the same category summary component as Home (§ 3) so the two can't disagree.
- On the phone, the summary block plus the chips push the first row below the fold.
- Each row's time ("8:41 PM") has no date. After midnight, yesterday's estimate looks current. Use "2 h ago" or "Mon 8:41 PM".

**Verdict:** UPGRADE.
- Remove the per-row "Nothing waiting" button.
- Use the shared category summary at the top.
- Use relative times.

### Estimates: "AA Linen" tab (`/control/estimates?view=aa`)
**Purpose:** record an AA Linen drop-off (bins per group).

**Confusing**
- The "Our work" tab is a *state* (what is out there). The "AA Linen" tab next to it is an *event form* (what just arrived). Same header ("Dirty work waiting"), different meaning.
- The tab doesn't show what AA has waiting at all (3 + 2 + 1½ bins delivered this morning).
- Steppers go in ¼ bin: entering 3 bins takes 12 taps. AA always arrives in whole or half bins. Use a **+1 / +½** stepper or tap-to-type.
- 12 rows of steppers, all at 0, then "Save delivery" at the very bottom.
- This is the **third** way into the same form: More → "Record a delivery", More → "Customer deliveries" → "Record a delivery", and this tab.

**Verdict:** UPGRADE.
- Top of the tab: "AA waiting now" (bins per group, ≈ loads where known).
- Then one "+ AA drop-off" button that opens the form.
- Remove the separate "Record a delivery" tile from More.

### Customer deliveries history (`/control/deliveries`)
**Purpose:** the owner checks and cancels AA drop-offs.

**Useful:** clear lines, "loads unknown" where there is no factor (correct), the note, "Cancel this delivery".

**Confusing**
- **For the manager it's an empty page with one button.** She can record a delivery but not see the one she just recorded, even though managers may cancel AA deliveries (owner 2026-11-07). She has no way to find the one to cancel.
- Show managers today's drop-offs, without names.

**Verdict:** UPGRADE. Managers see today's list (no names); the owner keeps 7 days.

### Load-out board (`/control/load-out`)
**Purpose:** the manager on duty sees what each truck needs and taps "Loaded ✓".

**Useful**
- Next truck plus countdown.
- "Tonight's totals" (exactly the pull list the supervisor needs).
- One card per route with its time.
- A big Loaded button.

**Confusing**
- "by Manny Ruiz" on every line (owner view). It's always the person who typed the sheet. Drop it per line; show "Entered by … at …" once per day.
- The special item "Hotel Ritz: 40 extra napkins … **2**": 2 of what? Show the unit, or let the special text carry the number.
- The **orange "4" badge** on Load-out in the nav from 3 PM onward, 12 hours before the first truck. A badge that is always on gets ignored. Show it from about 1 h before the next truck, or only when a truck is late.

**Verdict:** KEEP, with 3 small fixes.

### Load-out entry (`/control/load-out/entry`)
**Purpose:** the office manager or the owner types the drivers' load sheet.

**Useful:** "Same as yesterday", the per-route cards, butcher coats grouped by size, "+ Special item".

**Confusing**
- **Only ±1 steppers.** Route 2 needs 20 packs of sheets, which is 20 taps. The owner asked for "simple". Let people tap the number and type it (numeric keypad), and keep ±1 for corrections.
- "4 of 4 routes filled · **44 packs · 16 pcs**". It adds sheet packs (10) and soil-bag packs (5) into one meaningless total. Drop it, or show it per item, like the board's "Tonight's totals".
- 7 rows × 4 routes are always shown, mostly zeros. Fine on the desktop, a long scroll on the phone. On the phone, show one route at a time (route tabs).
- "Same as yesterday" copies Monday into Tuesday although different routes run (Route 11 Mon/Thu vs Route 5 Tue/Fri). Better: "Same as last <weekday>".

**Verdict:** UPGRADE.
- Type-in numbers.
- Remove the mixed total.
- "Same as last Tuesday".

### Machine down / back up (`/control/machines`)
**Purpose:** mark a machine down with a reason, and back up.

**Useful:** "Out for 3m", the reason, a big "Back up", the area chips, and the report form at the bottom.

**Confusing**
- "Report a machine out of service" is at the bottom, below the cards. It's the main *action* of the screen, so put it first.
- "Marked by Manny Ruiz" is owner-only, which is allowed.
- **Spanish:** "Ironer" stays English ("Ironer está fuera de servicio"), and so do Folder, Boiler, Compressor, Water pump, Soap machine (the owner approved "Máquina de jabón") and Wrapping machine. Only Washer and Dryer are translated in `src/lib/seededNames.ts`.

**Verdict:** KEEP. Move the report form to the top; add the Spanish machine names.

### Tasks (`/control/tasks` owner, "My tasks" for the manager)
**Purpose:** the owner sends a job to a manager; it nags every 10 minutes until it's done.

**Useful:** a very clear "New task" button, Open / To review, "Open for 2 minutes", the big Done ✓, and the reminder banner.

**Confusing**
- Managers have no Tasks entry in the bottom nav; it's reachable from the Home tile and More. Fine for now.
- Tasks can ask for things the manager can't do in the app ("move the red napkins up" while the queue is owner-only). That isn't a bug, but worth telling the owner.

**Verdict:** KEEP.

### Alerts (`/control/alerts`)
**Purpose:** everything that buzzed, open first.

**Useful:** "Open now" (live, can't be cleared), "Last 7 days" with Clear and Clear all finished, the icons plus words.

**Confusing**
- The manager's list repeats each task ("Nueva tarea …") that is already on My tasks and the Home tile. Acceptable.
- On the owner's account, "Estimates entered: 12 groups" fires even when the owner entered them himself. Skip alerts about your own actions.

**Verdict:** KEEP; don't alert people about their own actions.

### More (`/control/more`)
**Purpose:** everything that isn't in the bottom nav.

**Confusing**
- The grid repeats Washers, Queue, Estimates and Load-out, which are already in the bottom nav one finger away.
- The owner sees 13 tiles, and "Record a delivery" plus "Customer deliveries" are two tiles for one feature. "Record a delivery" uses the same bin icon as Estimates.
- No "Change my password" entry.

**Verdict:** UPGRADE.
- Show only what isn't in the nav, grouped as **Daily** (Tasks, Alerts, Machine down, AA drop-offs, Load-out entry) and **Setup** (People, Machines, Down reasons), plus language and sign out.

### People (`/control/people`, owner)
**Purpose:** create accounts, reset passwords, alert switches, manager shifts.

**Useful:** "Usual shifts (manager on duty)" with real times, the load-out grant, Reset / Deactivate / Unlock.

**Useless or confusing**
- **"Can manage entry staff and PINs"** checkbox on Create account: entry PINs were removed on 2026-11-07, so this grant does nothing visible. Remove it, or rename it to what it now does.
- The owner's alert settings mix 2 checkboxes (Machine down, Washer idle) with 4 three-way Buzz / Quiet / Off pickers. Use one pattern for all six.
- "Username: No username" on the owner: hide the line.
- On the manager's account, "Washroom · Evening (partly)": the word *partly* needs the More info to make sense ("ticked on some days"). Show the ticked days instead.
- Manager view: "Only an owner can manage people." Fine; the tile is already hidden for managers.

**Verdict:** UPGRADE: remove the PIN grant, one alert pattern.

### Setup: machines (`/control/setup/machines`)
**Purpose:** add, rename and deactivate machines. The owner dislikes this screen (open since 2026-11-06).

**Why it feels bad**
- 17 identical rows, each with a type caption ("Utility (compressor, boiler, pump…)") and an Edit button.
- Nothing useful about the machine is shown: active?, down now?, load factor (Washer 6 = 1.19), area.
- The "Add a machine" form takes a third of the page, though it's used once a year.
- Small bug: on load it requests `machines?plant_id=eq.` (empty) and gets a 400, because the query runs before the plant is known. It is harmless but shows in the console on every visit.

**Verdict:** UPGRADE.
- A compact table: Name | Area | Kind | Status (up/down) | Load factor | Active.
- Edit in place.
- "+ Add machine" as a button that opens the form.

### Setup: down reasons (`/control/setup/reasons`)
**Purpose:** the list of reasons for "machine down".

**Useful:** reorder, edit, English + Spanish labels, "Ask for a description".

**Confusing:** the "Other" row shows "**Fixed** asks for a description", with "Fixed" highlighted like a link; it reads as "Fixed" = "repaired". Say "Always there · always asks for a description".

**Verdict:** KEEP, with 1 wording fix.

### Missing from Setup
Several things are still impossible to edit in the app:
- wash groups and their factors (loads per basket and per bin; AA Kitchen towels and White napkins have no bin factor, hence "≈ 0 loads");
- items and pack sizes;
- routes and their days;
- shifts.

The CLAUDE.md launch scope lists "items + wash groups, shifts" as in-app setup. Today the fill-in sheet is the only path. **This is the root cause of the "≈ 0 loads" and "loads unknown" numbers.**

### Sign-in and change password
- Sign-in: logo, Username, 6-digit password, clear errors, lockout. KEEP.
- Forced change: clear. KEEP.
- There's no voluntary "change my password" in More (see More).

---

## 3. Replacement for "Work waiting by wash group"

What the owner wants is *what* is out there, in the units he and Denise think in, rolled up so it fits on one card. The hours stay as a small secondary number.

**Card: "Dirty work out there"** (replaces "Hours of work waiting" and "Work waiting by wash group" on the owner's Home; the same component sits at the top of Estimates and as the manager's Home tile).

```
Dirty work out there                         ≈ 51 loads · ≈ 8 h on 5 washers
Updated by Denise's estimates · oldest 2 h ago      Done around 11:48 PM

▸ Mats            7½ baskets              ≈ 26 loads   ≈ 2 h 15 min
    Black 3 · Charcoal 2 · Colored 1½ · Brito 1   (baskets)
▸ Napkins         4¾ bins                 ≈ 10 loads   ≈ 2 h 20 min
    Regular white 2½ · Black 1¾ · Green & red ½   (bins)
▸ Tablecloths     3 bins                  ≈ 6 loads    ≈ 1 h 35 min
    White 2 · Black 1   (bins)
▸ Towels & aprons 2 bins                  ≈ 5 loads    ≈ 1 h 35 min
    Kitchen towels 2   (bins)
▸ Sheets          3 loads                 3 loads      ≈ 25 min
▸ Mops            1 load                  1 load       ≈ 5 min
  Not estimated: 18 groups  ›  (opens Estimates › Needs estimate)

AA Linen (separate)                                    ≈ 8+ loads
  Towels & aprons 3 bins (loads unknown) · Mats 2 bins ≈ 8 loads ·
  Napkins 1½ bins (loads unknown)          → ask for the bin factors
```

**Rules**
- **The category is the line; the groups are the detail.** Categories are always in the same order: mats, napkins, tablecloths, towels & aprons, sheets, mops.
  - On desktop the group detail is shown; on the phone it's collapsed (tap ▸).
  - Categories with nothing waiting are hidden.
- **Units as entered.**
  - A category's total uses its single unit when every group used it (7½ baskets).
  - If units are mixed, list them: "2 baskets + 1 load".
  - Never add baskets to bins.
- **≈ loads are whole numbers.** Hours are rounded to 5 minutes and shown in a smaller, muted font.
  - Hours are worked out on the washers up now, so they say "on 5 washers" in the header. That way a breakdown visibly explains why the hours jumped while the pile stayed the same.
- **No colour bars.** If a visual is wanted, use one neutral bar per category for its share of the loads, with the number always printed. That follows the "never colour alone" rule; the group colours stay in the detail chips.
- **AA is separate**, from the deliveries not yet washed (the same source as "AA Linen waiting"). Missing factors are shown as "loads unknown" and the total as "≈ 8+ loads", never 0.
- **One source for every screen.** The same function feeds:
  - Home (owner card and manager tile);
  - the Estimates summary;
  - the Queue header ("≈ 51 our loads + AA 8+ + rewash 1").

  The three numbers can then never disagree again.

**Data:** everything needed already exists: `wash_groups.category`, `current_soil_estimates` (qty + unit), `app.to_loads`, cycle minutes, `customer_delivery_lines`. This is UI work plus one shared selector; no schema change.

---

## 4. Cross-app checks

**Navigation by role**

| | Owner | Manager |
|---|---|---|
| Nav | Home, Washers, Queue, Load-out, More | Home, Washers, Estimates, Load-out, More |
| Comment | Estimates is only in More, even though the owner also enters them in week 1 on the iPad. Fine. | Good fit. Queue, Tasks and Machine down are reached through Home tiles and More. |

**Things a manager can tap but can't use**
- The Customer deliveries tile, which shows an empty page.
- Earlier this list included "Loaded ✓" for a manager who is not on duty. That case is handled correctly: a notice explains it.

**Dead ends**
- AA "≈ 0 loads".
- Manager deliveries history.
- "Finished goods today" placeholder.

**Common flows over 3 taps**
- Reorder a queue item more than 3 places.
- Enter 3 AA bins (12 taps).
- Enter 20 sheet packs (20 taps).
- Mark a group "nothing left": this one is 1 tap, which is too easy to hit by mistake.

**Spanish**
- UI strings are complete: 0 missing keys. The identical ones are numbers, units and "bin" (kept by the owner).
- Gaps:
  - machine names except washers and dryers;
  - task text, which is free text entered by the owner (expected);
  - a mats wording split: AA "Mats" = **Alfombras** (owner 11-07), but our groups use **Tapetes** (Tapetes negros…). Ask the owner which word the crew uses, and use one.

**Numbers that disagree:** see § 1, problem 1. The fix is § 3's single source.

**Times**
- Times are shown in the device's timezone, not the plant's (America/New_York).
- It's harmless while every device is in Miami, but a laptop in another timezone would show other times. Low priority.

---

## 5. Top 10 changes (priority order)

| # | Change | Type | Effort |
|---|---|---|---|
| 1 | **"Dirty work out there" by category** (§ 3) replaces "Hours of work waiting" + "Work waiting by wash group". It's one shared selector used by Home (owner + manager), Estimates and the Queue header, so the numbers agree everywhere. Whole loads only. | UPGRADE | M |
| 2 | **Fix AA "≈ 0 loads left"** → "loads unknown"; the AA total becomes "≈ 8+". Ask the owner for the AA bin factors (Kitchen towels, White napkins, …). | UPGRADE (bug) | S |
| 3 | **Compact queue:** one-line items, actions behind a tap, "Move to top" / "Move to position", drag on desktop and tablet. Hide the area picker and empty filters. Show the "Added by" name only when it isn't the owner. | UPGRADE | M |
| 4 | **Estimates:** remove the per-row "Nothing waiting" button (move "None left (0)" into the row editor); relative times. | UPGRADE | S |
| 5 | **AA in one place:** the AA tab shows "AA waiting now" + a "+ AA drop-off" button; +1 / +½ steppers; managers see today's drop-offs; remove the duplicate More tile. | UPGRADE | M |
| 6 | **Load-out entry:** type-in numbers (keep ±1); remove the "44 packs · 16 pcs" total; "Same as last <weekday>"; one route at a time on the phone. | UPGRADE | S–M |
| 7 | **Cut placeholders and filler from Home:** hide "Finished goods today" until it's built; fold "Off-queue today" into one line on the Washers card; "Loads washed today" shows starts, not 5.19. | CUT | S |
| 8 | **Setup → Machines as a table** (status, area, load factor, active, edit in place, "+ Add" button); fix the empty `plant_id` 400. Then add **Setup → Wash groups** (factors per basket/bin), the root cause of the missing numbers. | UPGRADE | M (machines) / L (wash groups) |
| 9 | **More and People clean-up:** More shows only what's not in the nav, grouped Daily / Setup, plus "Change my password"; remove the stale "entry staff and PINs" grant; one alert-switch pattern; no alerts for your own actions. | CUT + UPGRADE | S |
| 10 | **Small wording and labels:** "Formula 4 · 59 min" on the washer cards; formula number under NEXT on the station; Spanish machine names (Planchadora, Dobladora, Caldera, Compresor, Bomba de agua, Máquina de jabón, Empacadora); one word for mats (Tapetes or Alfombras, owner to pick); the Load-out badge only near truck time; special-item unit; down-reason "Fixed" wording. | UPGRADE | S |

**Questions for the owner (one message)**
1. Is the § 3 card what you meant by "a summary of what is out there"? On the phone, should groups open under each category, or always show?
2. The AA bin factors for Kitchen towels, White napkins and the other AA groups (they show "loads unknown" today).
3. Mats in Spanish: "Tapetes" or "Alfombras", for both our mats and AA's?
4. Can "Finished goods today" and "Off-queue today" come off Home until finishing entry is built?
5. Setup → Machines: is a table with status and load factor what you'd like?
