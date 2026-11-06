# Google Stitch prompt: PlantBoard UI

How to use it:
- Paste **Part 1** first, then one screen from **Part 2** at a time. Stitch does better with one screen per prompt.
- Make the phone screens first, then the TV.
- Don't paste real customer names or numbers into Stitch. The examples below are made up.
- Stitch's output is a visual reference only. It gets rebuilt in the app's own code, and every accessibility rule in Part 1 still applies even if the design ignores it.

---

## Part 1: context (paste first)

Design a mobile-first web app called **PlantBoard** for a family-owned commercial laundry in Miami. The
laundry washes floor mats, linens (sheets, tablecloths, napkins, kitchen towels) and uniforms (butcher coats)
for restaurants and businesses. The app replaces phone calls between the owner and the plant floor.

Who uses it:
- **Owner (and his father):** on the phone all day. They want to see in 2 seconds what every washer is doing,
  set the order of work, and get alerts when something breaks. Not technical.
- **Shift managers (night shift):** in a hot, loud plant, often wearing gloves, Spanish first. They enter how
  much dirty work is waiting, tap when a washer starts, mark machines out of service, check which delivery
  route is loaded.
- **Crew:** only read big wall TVs over the washers.

Design rules (must follow):
- **Phone first**, 390 × 844. Every screen must also work on a 10-inch tablet mounted at a washer.
- **Big touch targets:** at least 56 px tall; the main action on a screen is at least 96 px tall and full width.
- **Never use color alone:** every status has an icon plus a word (e.g. a wrench icon plus "Out of service",
  a clock plus "Running 14 min left").
- **High contrast** (WCAG 2.2 AA minimum; the TV is 7:1). It must be readable in a bright, steamy room.
- **Bilingual:** every label works in English and Spanish. Spanish is about 30% longer, so leave room.
- **Glanceable:** numbers and icons over sentences. One idea per card. No dense tables on phones.
- **Show data freshness** on every live screen ("Updated 20 s ago").
- **No people's names** next to numbers anywhere: the plant tracks work, not workers.
- Each wash group has a color chip (black mats, colored mats, white linen, napkins…), always next to its name.
- Feel: calm, industrial, confident. Think airline departure board meets a modern banking app. Dark mode
  for the washer tablet and TV; light or dark for phones. A bold, simple sans-serif with tabular numbers.

Bottom navigation for the owner: **Washers · Queue · Load-out · Alerts · More**.
Managers see: **Washers · Estimates · Load-out · Tasks · More**.

---

## Part 2: screens (one per prompt)

### 1. Washer board (home)
The owner's main screen. Show 6 washers as compact tiles in a 2-column grid, each with:
- the washer number, large;
- status icon + word: Running / Done, unload / Empty / Out of service;
- what's inside (wash group color chip + name, e.g. "Black mats");
- a big countdown ("14 min").
An out-of-service washer is clearly marked (wrench icon, dashed border, the reason, e.g. "Water pump").
Above the grid, a strip says "Next in queue: Colored mats · 2 loads · RUSH".
Below the grid, a row lists other machines that are down (ironer, boiler, compressor).
Freshness in the top right.

### 2. Washer tablet (one washer, dark mode, mounted at the machine)
- Huge "WASHER 3".
- NOW: wash group + a giant countdown.
- NEXT: the next wash group.
- One giant green **START / EMPEZAR** button (about a third of the screen).
- After a tap, a big yellow **UNDO** with a 60-second countdown.
- A small "Other wash group" button.
- A small "Out of service" link.
- Usable with gloves, readable from 2 m.

### 3. Work queue (owner)
An ordered list of upcoming loads. Each row:
- position number;
- wash group chip + name;
- loads left;
- badges: RUSH (lightning icon), Rewash (circular arrow icon), "Washer 4" (pin icon).
Owner actions: move up/down, mark rush, assign washer, cancel. Use row buttons or swipe, no tiny icons.
A big "+ Add work" button at the top.
The manager view is read-only, except "Add rewash".

### 4. Dirty work estimates (manager, once per shift)
- One compact row per wash group (33 groups): chip, name, last estimate ("2½ bins ≈ 5 loads, 8:02 PM"),
  and a "Nothing waiting" quick button.
- Tapping a row opens a bottom sheet:
  - choose Bin or Basket;
  - "Full bins: [−] 2 [+]";
  - "Partial: none / ¼ / ½ / ¾";
  - a live answer: "≈ 5 loads · ≈ 2 h washer time".
- A sticky summary at the top: "≈ 18 loads waiting · done around 3:40 AM".
- A sticky "Review & save (3 changes)" button at the bottom, then a 4-digit PIN pad.

### 5. Load-out board (manager on duty, 3:00 to 6:00 AM)
- Today's routes in load-time order, as cards: "Route 21 · 3:30 AM", "Route 11 · 4:30", "Route 2 · 5:00",
  "Route 4 · 5:30". Each card shows what it needs:
  - Sheets 12 packs;
  - Butcher coats M 6 / L 10 / XL 4;
  - Soil bags 8 packs;
  - any special item.
- A big **"Loaded ✓"** button per route. Once tapped, the card turns to a done state, with an icon and the time.
- Night totals at the top, with an on-pace indicator ("Sheets: 48 packs needed · on pace ✓" or
  "behind ⚠ 30 min").
- A countdown to the next truck.

### 6. Load-out entry (office, daytime, once a day)
- A simple grid: today's routes as columns, items as rows (Sheets packs, Coats M/L/XL, Soil bags packs),
  plus "+ Special item".
- A "Same as yesterday" button at the top. Number fields with steppers.
- One "Save" button.

### 7. Machine out of service
- Pick a machine from big tiles grouped by area (Washroom / Finishing / Utilities).
- Pick a reason from big tiles (Water pump, Soap machine, Won't start, Leaking, Other).
- Optional details, with the hint "Describe the problem, not the person".
- A big red "Mark out of service" button.
- A separate "Back in service" list with one tap + confirm.

### 8. Tasks (owner sends, manager confirms)
- **Owner:** a short text box ("Check all parked trucks"), then "Send to: Manager on duty / [name]", then Send.
  Below, a list of open tasks with how long each has been open.
- **Manager:** open tasks pinned at the top as bold cards with a big "Done" button and an optional note.
  A banner says it will remind every 10 minutes.

### 9. Alerts inbox
A chronological list of alerts:
- machine down (red wrench);
- washer idle 15 min with work waiting (amber clock);
- route loaded (green truck);
- task done (green check).
Each has a time and a one-tap action ("Open washer board").

### 10. Setup (owner only)
- A clean settings-style list: Machines, Down reasons, People, Routes, Wash groups, Shifts.
- The Machines list has one row per machine (type icon, name, status dot + word) and a big "+ Add machine"
  button. Areas can collapse. Tap a row to edit in a bottom sheet.

### 11. Wall TV (1920 × 1080, dark, readable from 6 m)
- 3 washers side by side. For each:
  - washer number;
  - NOW wash group with its color chip at 96 px or larger;
  - countdown;
  - NEXT wash group.
- Nothing smaller than 32 px; contrast 7:1.
- An out-of-service washer gets a full-tile wrench + "OUT OF SERVICE".
- The clock and data freshness sit in a corner.
