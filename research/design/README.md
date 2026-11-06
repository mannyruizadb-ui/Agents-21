# PlantBoard visual design (owner-approved 2026-11-06)

Source: Google Stitch mockups in `stitch/` (screens + `DESIGN.md` tokens). Use them as the **visual style**.
They are not specs. The rules below win wherever the mockups disagree.

## Owner decisions
- **Dark theme for everyone,** phones included: the Stitch "Industrial Telemetry" palette in `stitch/DESIGN.md`.
- **One language per person.** Show only the viewer's language; **never bilingual "EN / ES" labels.**
- **Fonts:** Barlow Condensed (headings), JetBrains Mono (timers/numbers), Inter (body). All are free (OFL).
  **Self-host them** (bundled, no Google Fonts request), so the app works on bad Wi-Fi.

## Keep from the mockups
- Navy surfaces.
- Status colors, each with an icon plus a word: green = running/OK, amber = rush/warning,
  red with diagonal stripes = out of service, blue = done/info.
- Washer board: a 2-column tile grid, a big monospace countdown, a status badge, a NEXT IN QUEUE banner,
  and an "other machines down" strip.
- Bottom nav, with count badges:
  - owner: Washers · Queue · Load-out · Alerts · More;
  - managers: Washers · Estimates · Load-out · Tasks · More.
- Washer tablet: a giant EMPEZAR, and an amber DESHACER with a 60 s countdown.
- Queue: numbered rows, big up/down buttons, RUSH / Rewash / Washer tags.

## Drop: invented content that breaks project rules
- **No people's names** anywhere (no "Dispatched by …", "Assigned to …", "Signed by …", "Reported by …").
- **No weights, temperatures or lbs.** ADB has no scale.
- **No data the app doesn't have:** batch numbers, staging bays, valves, technician ETAs, work orders,
  severity levels, % capacity, tunnel.
- **Tasks:** no "snooze" (the owner wants reminders until done), no signature, fingerprint or photo proof.
- **Load-out:** no per-item staging checklist. One "Loaded ✓" per route (owner: "must be simple").

## Readability rules (override the Stitch tokens)
- Minimum text size **14 px** on phones (the Stitch label-micro is 11 px: don't use it). The TV keeps its own
  rules: ≥ 32 px, NOW ≥ 96 px, 7:1 contrast.
- ALL-CAPS only for short badges. Body text and names are in sentence case.
- Never truncate the wash group name on primary tiles: wrap to 2 lines instead.
- Green means running/OK only. Don't use it decoratively.
- WCAG 2.2 AA contrast, ≥ 56 px targets on entry screens, and never color alone.

## Owner 2026-11-06 (round 2)
- Replace the button-list ("bubble") home with a **Home dashboard** of live summary tiles, plus a way to choose
  which screens/tiles to see (Customize on Home, the bottom nav, and a More grid of every screen).
- Everything dark, sign-in included, with the **ADB logo** at the top. The logo file is pending from the owner and goes in
  `public/brand/`.

