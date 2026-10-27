# PRD: PlantBoard — Plant Operations App for America's Dust Busters

| | |
|---|---|
| **Working title** | PlantBoard (rename freely) |
| **Version** | 1.0 (draft for review) |
| **Date** | 2026-10-27 |
| **Owner** | ADB operations leadership |
| **Source documents** | [`viability-analysis.md`](./viability-analysis.md) · [`tech-stack.md`](./tech-stack.md) |
| **Status** | Ready for build planning, subject to the open items in §0.3 |

---

## 0. How to read this document

### 0.1 Glossary

| Term | Meaning |
|---|---|
| **Soil / dirty** | Customer goods (mats, linens, apparel, towels, mops) that came back from routes and are waiting to be washed. |
| **Soil estimate** | A manager's best guess of how much dirty work is waiting, by item type. Example: "~10 baskets of 3×5 mats." It is always approximate and is revised often. |
| **Washroom** | The area with the washers (Milnor) and dryers. |
| **Finishing** | The area where clean goods are processed: ironer, folders, packing. |
| **Station** | One work position: "Ironer 1", "Folding table 2", "Mat roller". |
| **Queue** | The ordered list of work an area should do next. Shown on that area's wall display. |
| **Queue item** | One line in the queue. Example: "Napkins, white — 4 loads — RUSH". |
| **Production log** | A record of finished output: what, how much, which station, who, and when. |
| **Operator session** | The period an operator is checked in at a station. It is used to compute output per hour. **It is not payroll time.** |
| **Shift instance** | One concrete occurrence of a shift, e.g. "Night shift, 2026-11-03 22:00 → 2026-11-04 06:00". |
| **Wash formula** | The program run on a washer (with chemical dosing by Diamond's Accu-Flow). Each formula maps to an item type. |
| **Accu-Flow / CloudView** | Diamond Chemical's dispensing system and its reporting portal. This is the source of washer load data. |
| **PPOH** | Pounds per operator hour, the standard laundry productivity metric. We also track pieces per operator hour. |
| **Org / plant** | Tenant hierarchy. An organization (ADB) owns one or more plants (the Miami plant at 222 NE 68th St). |

### 0.2 Priority definitions

- **P0:** required for MVP launch. The product doesn't do its job without it.
- **P1:** important. Target within ~4–6 weeks after MVP.
- **P2:** nice to have. Backlog.

### 0.3 Open items that affect the build

These are carried over from the earlier research and are not blockers to *starting*. The MVP is designed to work with all of them unresolved.

1. **Accu-Flow data export.**
   - Diamond Chemical has not yet confirmed whether there is an API, a scheduled CSV, or only screen views.
   - MVP uses manual washer entry, so this is not on the critical path.
2. **Unit conversion factors** for each item type: lbs per basket, lbs per load, pieces per lb.
   - Operations must supply these.
   - Reports show "estimated" until they are entered.
3. **Crew languages.** English and Spanish are assumed P0. Haitian Creole is P1 pending confirmation.
4. **Shift schedule:** how many shifts, start and end times, and whether any cross midnight.
5. **Screen locations:** Wi-Fi strength and heat/humidity at each mounting spot.

---

## 1. Executive summary

### 1.1 What we're building

PlantBoard is a real-time operations board for an industrial laundry.

- Managers enter and continuously revise **estimates of dirty work waiting**.
- The owner (or any manager) **orders and re-orders the work queue from their phone**.
- **Wall-mounted screens** in the washroom and finishing room show each crew exactly what to do **now, next and later**.
- **Station tablets** capture what was actually produced, by whom, and over what time.
- **Washer load data** (manual at first, later from Diamond's Accu-Flow CloudView) shows what went through the washroom.

Together these produce a per-shift **job output sheet** and **productivity numbers** (pieces/lbs per operator hour) without anyone collecting paper.

It is built first for America's Dust Busters / Star Linen Service in Miami, on a multi-tenant foundation so more plants or organizations can be added later.

### 1.2 Primary value proposition

> **Stop running the plant by phone.** Set the priorities once from your phone. Every screen in the plant shows the crew what's next, and every shift ends with a real record of what got produced.

It delivers value in three ways:

1. **Fewer interruptions.** Direction moves from phone calls to screens.
2. **Visibility.** Live soil estimates, queue status and output, from anywhere.
3. **Accountability with data.** Shift output and productivity are measured, not guessed.

### 1.3 Primary persona (summary; full detail in §2)

**"The Owner-Operator Dispatcher."** This is the family owner or operations lead of a small-to-mid industrial laundry. They currently hold the plant's priorities in their head and push them out by phone.

| | |
|---|---|
| **Motivations** | Keep customers' goods coming back on time. Protect margin against national competitors (Cintas, Alsco, Vestis) and the new Elavo roll-up. Hand the business to the next generation in better shape than they found it. |
| **Fears** | A missed delivery that loses a long-time account. Paying overtime for a shift that wasn't productive. Not knowing what really happened overnight. Becoming the single point of failure, where nothing moves unless they call. |
| **Goals** | Run the plant from anywhere. Know at a glance what's dirty, what's in progress and what's done. Have numbers to coach the crew and plan staffing, without becoming a software administrator. |

---

## 2. User avatar deep dive

### 2.1 Persona A — Owner-Operator Dispatcher (primary)

| Attribute | Detail |
|---|---|
| **Role** | Owner, or second-generation operations lead. The final say on priorities. |
| **Context** | Often away from the plant floor: on routes, with customers, in the office, or at home during night shift. Uses a smartphone constantly; laptop occasionally. |
| **Tech comfort** | High with phone apps. Low patience for setup screens, logins and anything that takes more than a few taps. |
| **Daily reality** | Takes calls from managers ("how much is left?"), calls the washroom ("run the napkins next, the club needs them at 6"), calls finishing ("stop the mats, do the chef coats"). Repeats the same instructions to different people. |

**Motivations**
- Customers get their goods on time, every time.
- Prove the family business can run as tightly as the national chains.
- Free up their own time for selling and customer relationships.

**Fears**
- A rush order is missed because the message never reached the person at the ironer.
- Staff costs keep rising with no evidence of what the extra hours bought.
- New software becomes another thing they have to babysit, or the crew ignores it.
- Tracking feels like spying and damages trust with long-time employees.

**Goals**
- Change priorities in seconds, from anywhere, and know the floor saw it.
- See soil remaining vs. processed by item, live.
- End each shift with an automatic output sheet.
- Spot which shifts or stations need help, with fair numbers.

**Current painful workflow**
1. Morning: managers text or call rough counts ("looks like 10 baskets of mats, 6 of napkins").
2. The owner decides the order in their head and calls the washroom lead.
3. Mid-shift the counts change ("it was really 6 baskets"). More calls follow, and the order changes.
4. The finishing crew doesn't hear about the change. They finish the wrong item first, or wait idle.
5. Night shift runs with no supervision. The next morning nobody can say exactly what was produced or how long it took.
6. Output is pieced together from memory, paper and the CloudView portal, if at all.

**What success looks like**
- **Phone calls to give direction drop by more than half** within a month.
- They reorder the queue from their phone in under 10 seconds, and the screens update within 2 seconds.
- Every morning a shift report is waiting: produced vs. estimated, by item and station.
- They can answer "how did last night go?" without calling anyone.

**What would make them tell a colleague**
> "I haven't called the washroom in two weeks. The screens tell them, and I see the numbers from my phone."

Concretely, the trigger is a **visible, early win**: the first rush order handled entirely through the board, or the first time a shift report caught a problem they would otherwise have missed.

### 2.2 Persona B — Plant Manager / Supervisor (secondary, heavy daily user)

| Attribute | Detail |
|---|---|
| **Role** | Walks the floor and the soil sort area. Knows what's actually piled up. Assigns people. |
| **Device** | Phone (primary); occasionally the station tablets. |
| **Motivations** | Keep the line moving; look competent to the owner; avoid being blamed for missed orders. |
| **Fears** | Being second-guessed; double data entry; numbers being used against them unfairly. |
| **Goals** | Update estimates in two taps; see what's next without asking; fix a mistaken entry easily. |
| **Pain today** | Is the human relay between the owner and the floor. Gets calls from both directions. |
| **Success** | "I update the count once and everyone sees it. I don't relay messages any more." |
| **Would tell a colleague because** | "It saves me from being the messenger." |

### 2.3 Persona C — Washroom Lead (secondary)

| Attribute | Detail |
|---|---|
| **Role** | Loads and runs the Milnor washers and dryers; chooses formulas. |
| **Environment** | Hot, wet, loud. Gloves on. Phone often not reachable. |
| **Language** | Likely Spanish or Haitian Creole first (to be confirmed). |
| **Motivations** | Clear instructions; not getting yelled at for running the "wrong" load. |
| **Fears** | Conflicting instructions from different bosses; screens that are hard to read. |
| **Goals** | Glance up and know the next 3 loads. Mark a load started or done with one big tap. |
| **Success** | "The screen tells me. Nobody changes their mind without it showing up there." |

### 2.4 Persona D — Finishing Operator (ironer / folding / packing)

| Attribute | Detail |
|---|---|
| **Motivations** | Steady work, fair treatment, finishing the shift on time. |
| **Fears** | Being "tracked"; that numbers will be used to punish without context; complicated tablets. |
| **Goals** | Know what to run next. Log output with as few taps as possible. Get credit for good work. |
| **UX implications** | 64 px+ buttons, a numeric keypad, preset counts (+10 / +25 / +50), first-language UI, no typing. |
| **Success** | "I tap my name, tap the item, tap the number. Done." |

### 2.5 Anti-personas (not designing for)

- Corporate IT at a national chain that needs SSO, an ERP integration and SOC 2.
- Laundromat / coin-op operators.
- Route drivers. Route management is out of scope (§7).

---

## 3. Feature specification

Feature IDs are referenced throughout. Each epic opens with what it covers.

### Epic A — Setup & administration

#### A1. Organization & plant setup (P0)

- **Story:** As an owner, I want my organization and plant configured with the right timezone so that shifts and reports line up with our real day.
- **Acceptance criteria:**
  - An org and at least one plant exist, with name and IANA timezone (default `America/New_York`).
  - For MVP, creation is done by a seed/migration script. An admin UI is P2.
  - Every operational record is scoped to `org_id` + `plant_id` (see §4).
- **Tech notes:** Seed via `supabase/seed.sql`. Validate the timezone against `pg_timezone_names`.

#### A2. Item types & unit conversions (P0)

- **Story:** As an owner, I want to define our item types (e.g., 3×5 mat, white napkin, chef coat) with names in each language and conversion factors so that estimates, washer loads and output can be compared in one unit.
- **Acceptance criteria:**
  - CRUD UI for owner/manager: name (EN/ES/HT), category, default unit, `lbs_per_basket`, `lbs_per_load`, `pieces_per_lb`, color, sort order, active flag.
  - Conversion fields are optional. When missing, reports label derived numbers "needs conversion" instead of guessing.
  - Every change to a conversion factor is written to `audit_log` with before/after values.
  - Deactivated items disappear from pickers but stay in historical reports.
- **Tech notes:** Conversion math happens in SQL views (§4.6). Store factors as `numeric`, never float.

#### A3. Areas, stations & machines (P0)

- **Story:** As an owner, I want to define the plant's areas (washroom, finishing), stations (Ironer 1, Folder 2) and machines (Washer 1–N) so that queues, displays and logs attach to the right place.
- **Acceptance criteria:**
  - CRUD for areas, stations and machines.
  - Machines have an optional `external_ref` (the Accu-Flow machine identifier) for future import.
  - A station belongs to exactly one area.
  - Deactivation works without deletion.
- **Tech notes:** Seeded for ADB at launch. The UI can be minimal.

#### A4. User invites & roles (P0)

- **Story:** As an owner, I want to invite managers by email and assign roles so that only the right people can change priorities.
- **Acceptance criteria:**
  - Owner enters an email and a role (`manager`, `lead`, `viewer`). The invitee receives a magic-link email and lands in the app with that role.
  - Role changes take effect on the user's next token refresh (≤ 1 hour) or on forced sign-out.
  - Owner can revoke access, which ends the user's sessions.
  - At least one `owner` must exist per org. The last owner cannot be removed.
- **Tech notes:**
  - Supabase Auth `inviteUserByEmail`, called from an Edge Function using the service role.
  - Membership rows (§4).
  - Custom Access Token Hook adds `org_id`, `role` and `plant_ids` to the JWT.

#### A5. Operator roster & PINs (P0)

- **Story:** As a manager, I want to add floor operators with a 4-digit PIN so that they can check in at station tablets without email accounts.
- **Acceptance criteria:**
  - Add, edit and deactivate operators: display name, preferred language, PIN.
  - PINs are stored hashed. They are never displayed after creation; reset generates a new one.
  - PINs must be unique among active operators in a plant (enforced by the RPC that sets the PIN).
  - 5 wrong PIN attempts at a station lock that operator at that station for 5 minutes.
- **Tech notes:** `pgcrypto` `crypt()` with bcrypt. Operators are **not** auth users.

#### A6. Shift definitions & instances (P0)

- **Story:** As an owner, I want to define our shifts (including overnight shifts) so that output is attributed to the right shift even when it crosses midnight.
- **Acceptance criteria:**
  - Define a shift with name, local start time, local end time and days of week. End time earlier than start time means it crosses midnight.
  - The system generates `shift_instances` 7 days ahead (pg_cron, daily).
  - Every production log, operator session and washer cycle is linked to the shift instance that contains its timestamp.
  - Reports group by shift instance and its **business date** (the date the shift started).
- **Tech notes:**
  - Generation function `app.generate_shift_instances(plant_id, days)`.
  - Lookup function `app.shift_instance_at(plant_id, ts)`.
  - Overlapping shifts are rejected by an exclusion constraint.

#### A7. Device pairing for displays and stations (P0)

- **Story:** As a manager, I want to pair a wall TV or station tablet with a short code so that it signs in once and stays signed in safely, with limited permissions.
- **Acceptance criteria:**
  1. A manager creates a pairing code for a display (with an area) or a station (with a station). The code is 6 characters and expires in 15 minutes.
  2. The device opens `/pair`, enters the code, and becomes a device account with role `display` or `station`, bound to that area or station.
  3. Device sessions persist across reboots: the refresh token is stored on the device.
  4. A manager can rename or revoke a device. A revoked device is signed out within 60 seconds and shows "This screen was unpaired."
  5. More than 10 failed pairing attempts from one IP within 10 minutes are blocked.
- **Tech notes:** Edge Function `pair-device` creates an auth user (`device-<uuid>@devices.local`, random password) and a membership and device row, then returns a session. See §5.4.

### Epic B — Soil estimates

#### B1. Enter or update a soil estimate (P0)

- **Story:** As a manager, I want to update how much dirty work is waiting for each item type, in the unit I naturally count in (baskets, loads, lbs, pieces), so that everyone plans from the latest picture.
- **Acceptance criteria:**
  - The estimates screen lists active item types with their current estimate and its age ("10 baskets · 2h ago").
  - Tap an item, then enter a number or use −1 / +1 / −5 / +5 steppers, choose the unit (default = item's default unit), add an optional note, and save. That is ≤ 3 taps for a simple change.
  - Saving creates a **new** row. History is append-only, never overwritten.
  - Displays and other phones reflect the change in ≤ 2 s (p95).
  - **Bulk mode:** update several items on one screen and save once.
  - Setting an estimate to 0 marks that item "cleared".
- **Tech notes:** RPC `update_soil_estimates` (batch). Realtime subscription on `soil_estimates` filtered by `plant_id`. Idempotent via `client_id`.

#### B2. Estimate history & freshness (P0)

- **Story:** As an owner, I want to see when each estimate was last updated and by whom so that I know whether to trust it.
- **Acceptance criteria:**
  - Each item shows "updated X ago by NAME".
  - The item's history shows the last 20 changes.
  - Freshness colors: ≤ 2h normal; 2–4h amber; > 4h red. Thresholds are configurable per plant.
  - Displays show the same freshness cue with an icon and text, never color alone.
- **Tech notes:** View `current_soil_estimates` (§4.6).

#### B3. Stale-estimate alert (P1)

- **Story:** As an owner, I want to be notified when estimates go stale during a shift so that the board doesn't silently drift from reality.
- **Acceptance criteria:**
  - If any active item with a non-zero estimate is older than the red threshold during an active shift instance, send one email to the configured recipients.
  - Maximum 1 alert per item per shift.
- **Tech notes:** pg_cron every 15 min → Edge Function `dispatch-alerts` → Resend.

### Epic C — Work queue (dispatch)

#### C1. Create a queue item (P0)

- **Story:** As an owner or manager, I want to add work to an area's queue (item, quantity, unit, optional note) so that the crew sees it on their screen.
- **Acceptance criteria:**
  - Choose area → item type → quantity + unit → optional note and RUSH flag → add. The item lands at the bottom of normal items, or at the top if RUSH.
  - Appears on that area's display in ≤ 2 s (p95).
  - Quantity is > 0. The note is ≤ 140 characters.
  - **"Add from estimates" shortcut:** pre-fills the quantity from the item's current soil estimate.
- **Tech notes:** RPC `create_queue_item`.

#### C2. Reorder the queue by drag (P0)

- **Story:** As an owner, I want to drag queue items into a new order from my phone so that I can change priorities in seconds without calling anyone.
- **Acceptance criteria:**
  - Long-press and drag works on iOS Safari and Android Chrome. Up/down buttons are an accessible alternative.
  - Optimistic UI: the new order shows instantly on the phone and persists within 1 s.
  - **Conflict handling:** if two people reorder at once, the second save gets a conflict, their list refreshes, and a toast explains "Queue changed by NAME — refreshed."
  - Displays reflect the new order in ≤ 2 s (p95).
- **Tech notes:**
  - RPC `move_queue_item(item_id, before_id, after_id, expected_version)`.
  - Fractional `position`, with rebalancing when the gap is < 1e-6.
  - `version` integer for optimistic concurrency.

#### C3. Rush flag (P0)

- **Story:** As an owner, I want to mark an item as RUSH so that it jumps to the top and stands out on the screen.
- **Acceptance criteria:**
  - Toggling RUSH moves the item to the top of the area queue.
  - On the display, the item shows a high-contrast "RUSH / URGENTE" badge, an icon, and a ≤ 3 s attention pulse (respects reduced-motion).
  - Multiple RUSH items keep their relative order.

#### C4. Start / complete / cancel queue items (P0)

- **Story:** As a washroom lead, I want to mark the current item as started and then done so that the owner sees progress without calling.
- **Acceptance criteria:**
  - Status flow: `queued → in_progress → done`. `cancelled` can be reached from `queued` or `in_progress`.
  - **Who can change status:**
    - managers and owners from the phone
    - leads from the phone
    - station devices, for items in their own area
  - Starting an item records `started_at`; completing it records `completed_at`.
  - Completed items leave the "Now / Next" columns and appear in "Done this shift" (last 5).
  - Optional on completion: record actual quantity, which creates a production log or washer entry depending on area.
- **Tech notes:** RPC `set_queue_item_status`.

#### C5. Suggested queue from estimates (P1)

- **Story:** As an owner, I want the app to propose a queue from current soil estimates, ordered by rules I set (e.g., RUSH customers' items first, then largest backlog), so that I start from a sensible order instead of a blank list.
- **Acceptance criteria:**
  - A "Suggest" button produces a draft list. The owner reviews, edits and then publishes. **Nothing is published automatically.**
  - Converts estimates to loads using `lbs_per_basket` / `lbs_per_load`. Items without factors are listed separately as "needs conversion."

#### C6. Queue templates (P2)

Save and reuse a typical day's order.

### Epic D — Wall displays

#### D1. Area display: Now / Next / Later (P0)

- **Story:** As a washroom or finishing worker, I want a big, simple screen that shows what to run now, what's next, and what's coming, in my language, so that I don't need to wait for a phone call.
- **Acceptance criteria:**
  - **Layout at 1920×1080:**
    - **NOW:** the current `in_progress` item, or the first queued item if none is in progress. Item name, quantity + unit, RUSH badge, note.
    - **NEXT:** the next 3 items.
    - **LATER:** a count of remaining items + total estimated loads.
    - **Side panel:** soil remaining for the top 6 items, with freshness.
    - **Footer:** shift name, clock, connection status, "updated Xs ago".
  - **Readability:** NOW item text ≥ 96 px; NEXT ≥ 56 px; nothing below 32 px. Readable at 6 m.
  - **Language:** each display has a language setting (EN / ES / HT) or "bilingual" mode, which shows two languages stacked.
  - **No interaction required.** Runs unattended for 72 h without a manual reload.
  - Contrast ≥ 7:1 for all text.
- **Tech notes:**
  - Route `/display/:areaId`.
  - Initial data from RPC `get_display_feed(area_id)`, then Realtime.
  - Screen Wake Lock API.
  - Scheduled full reload at 04:00 local (configurable) to clear memory.

#### D2. Connection & data-age indicator (P0)

- **Story:** As an owner, I want each screen to show clearly when it's offline or stale so that nobody follows outdated instructions.
- **Acceptance criteria:**
  - After 30 s without a Realtime heartbeat, the screen shows a banner: "Reconnecting… last update 10:42".
  - After 5 min offline, the whole screen dims with a large "OFFLINE — ASK SUPERVISOR / FUERA DE LÍNEA" message.
  - On reconnect (or the `online` / `visibilitychange` events), the screen refetches the full feed. It does not rely on missed events.

#### D3. Broadcast message to screens (P1)

- **Story:** As an owner, I want to push a short message to one or all screens (e.g., "Truck leaves 5:30 — finish club napkins first") so that urgent context reaches everyone.
- **Acceptance criteria:**
  - Message up to 140 characters, with optional translations.
  - Target: one area or all.
  - Expiry: 15 min to 12 h.
  - Severity: info or urgent.
  - Shows as a banner.
  - The owner can retract it.

#### D4. Device heartbeat & offline alerts (P1)

- **Acceptance criteria:**
  - Each device calls `device_heartbeat()` every 60 s.
  - If a paired display has no heartbeat for 10 minutes during an active shift, the owner and managers get an email. Max 1 per device per shift.
  - A device list shows last seen, app version and status.

#### D5. Shift scoreboard on display (P1)

Finishing display shows shift totals by item vs. target, if targets are set. **Team totals only by default.** Per-operator numbers are never shown on wall screens unless the owner explicitly enables it (see §6.2 on fairness).

### Epic E — Station production logging

#### E1. Operator check-in at a station (P0)

- **Story:** As an operator, I want to tap my name and enter my PIN at the station tablet so that my output is credited to me.
- **Acceptance criteria:**
  - The station home screen shows a grid of active operators (photo or initials + name), sorted by most recent at this station.
  - Tap name → 4-digit keypad → checked in. This opens an `operator_session` at this station.
  - Multiple operators can be checked in at the same station (e.g., a 3-person ironer crew).
  - Check-out is explicit ("Done / Salir"). It also happens automatically at the end of the shift instance or after 12 h, flagged `auto_closed`.
  - One operator cannot have two open sessions at different stations. Checking in elsewhere auto-closes the previous session.
  - UI is in the operator's preferred language once checked in.
- **Tech notes:** RPC `start_operator_session` (verifies PIN); RPC `end_operator_session`.

#### E2. Log production output (P0)

- **Story:** As an operator, I want to log what I just finished (item + count) in a few taps so that the shift's output is recorded accurately without paperwork.
- **Acceptance criteria:**
  - Tap item (the station shows its area's NOW/NEXT items first) → enter quantity via big keypad or preset buttons (+10, +25, +50, +100) → confirm.
  - Unit defaults to pieces for finishing and loads for washroom (configurable per item).
  - Credited to all operators currently checked in at the station, or to one selected operator. The default is configurable per station.
  - Confirmation shows "✓ 50 napkins saved", with a 10-second **Undo**.
  - Quantity is > 0 and ≤ 5,000 per entry; a larger number needs a second confirmation.
- **Tech notes:**
  - Direct insert into `production_logs` (RLS limits station devices to their own station) or RPC `log_production`.
  - The client generates `client_id` (UUID v4) for idempotency.

#### E3. Offline tolerance at stations (P0)

- **Story:** As an operator, I want my entries to save even if Wi-Fi drops so that I never have to re-enter work.
- **Acceptance criteria:**
  - When offline, entries go to a local queue (IndexedDB) and the UI shows "Saved on tablet — will sync".
  - Entries sync automatically on reconnect, in order. Duplicates are ignored via `client_id`.
  - Survives an app reload and a device reboot. Supports ≥ 8 hours or 2,000 queued entries.
  - A visible pending-sync counter is shown.
- **Tech notes:** TanStack Query persisted mutations + IndexedDB persister; server-side `on conflict (client_id) do nothing`.

#### E4. Correct or void a log (P0)

- **Story:** As a lead or manager, I want to correct a wrong entry so that reports stay accurate without deleting history.
- **Acceptance criteria:**
  - Leads and managers can void a log (reason required) and enter a replacement.
  - Operators can only use the 10-second undo.
  - Voided logs are excluded from totals but stay visible in an audit view.
- **Tech notes:** RPC `void_production_log`. No hard deletes.

#### E5. Per-batch timer (P1)

Optional "Start batch / End batch" on a station to measure cycle time per item, in addition to session-based rates.

#### E6. Downtime reasons (P2)

Log stoppages (machine down, waiting on washroom, no work, break) with start and end times, to separate "slow" from "blocked."

### Epic F — Washroom data

#### F1. Manual washer load entry (P0)

- **Story:** As a washroom lead, I want to record each load I run (machine, formula/item, weight if known) so that we know what the washroom produced even before the Accu-Flow integration exists.
- **Acceptance criteria:**
  - On the washroom station: tap machine → tap formula/item → optional weight → "Load started".
  - "Load done" is optional. If not tapped, the end time is left empty and reports count the load at its start time.
  - **End-of-shift alternative:** a "quick totals" screen to enter the number of loads per formula per machine for the shift.
  - Creates `washer_cycles` with `source = 'manual'`.

#### F2. Wash formula → item mapping (P0)

- **Story:** As an owner, I want to map each Accu-Flow wash formula number to one of our item types so that washer data can be compared with estimates and finishing output.
- **Acceptance criteria:**
  - Table UI: formula number, formula name, item type (or "mixed/other").
  - Unmapped formulas that appear in an import are listed for mapping.

#### F3. Accu-Flow CSV upload import (P1, contingent on Diamond)

- **Story:** As a manager, I want to upload the CloudView export each morning so that washer loads are captured without retyping.
- **Acceptance criteria:**
  - Upload CSV/XLSX (≤ 10 MB) → preview of parsed rows → confirm.
  - The import is **idempotent**: re-uploading the same file creates no duplicates (unique on `plant_id + source + external_id`, or a hash of machine + formula + start time).
  - Shows an import summary: inserted / skipped / errors, with row numbers.
  - Unknown machines or formulas are flagged, not dropped.
  - The raw file is stored in Supabase Storage for audit.
- **Tech notes:**
  - Edge Function `import-washer-file`.
  - The parser is tied to Diamond's actual export format, so **a sample file is required before build.**

#### F4. Automated Accu-Flow feed (P2, contingent on Diamond)

- If an **API** exists: a scheduled pull every 15–60 minutes.
- If a **scheduled email report** exists: an inbound address whose attachment triggers the F3 pipeline.

### Epic G — Reporting

#### G1. Shift output report (P0)

- **Story:** As an owner, I want a report for each shift showing what was produced by item and station, against estimates and queue, so that I know how the shift went without calling anyone.
- **Acceptance criteria:**
  - Choose a shift instance (default: the most recently ended one).
  - **Totals by item:** pieces, lbs (where convertible), loads washed.
  - **Totals by station:** pieces and lbs.
  - **Queue:** completed vs. remaining at shift end.
  - **Soil:** estimate at shift start vs. at shift end.
  - Mobile-first layout, readable on a phone without horizontal scroll.
  - Numbers derived from incomplete conversion factors are labelled "partial."
- **Tech notes:** RPC `get_shift_report(shift_instance_id)` over the views in §4.6.

#### G2. Productivity (P1)

- **Story:** As an owner, I want pieces and lbs per operator hour by station and shift so that I can spot where to coach, staff or fix equipment.
- **Acceptance criteria:**
  - Operator hours = sum of `operator_sessions` durations at the station within the shift.
  - **Per-operator figures are visible only to owners and managers.**
  - Displays a 4-week trend.
  - Includes a caveat banner: "Productivity data is operational, not payroll."

#### G3. Soil vs. processed reconciliation (P1)

Compares estimated soil against what was actually washed and finished, per item per day, to show estimate accuracy (% error) and help managers estimate better.

#### G4. CSV export (P1)

Export any report or raw production logs for a date range (owner/manager).

#### G5. Weekly trends dashboard (P2)

### Epic H — Platform & cross-cutting

#### H1. Localization (P0: EN + ES; P1: HT)

- **Acceptance criteria:**
  - All UI strings are externalized (react-i18next).
  - Item type names have per-language fields.
  - Language is chosen per user, per operator and per display.
  - Numbers and times are formatted for the locale.

#### H2. Audit log (P0)

All create/update/void actions on configuration, queue, estimates and logs write to `audit_log`: actor, device, before/after.

#### H3. Email notifications (P1)

Resend-backed; used by B3 and D4. Per-user opt-in.

#### H4. PWA install, update & versioning (P0)

- Installable on iOS and Android.
- A new version shows "Update available": displays auto-apply it at the nightly reload, and phones apply it on tap.
- The app version is reported in heartbeats.

#### H5. Product analytics events (P0, minimal)

Record key events in `app_events` (queue reorder, estimate update, log created, display offline) to measure the success metrics in §8. No third-party trackers.

---

## 4. Database schema

**Target:** Supabase Postgres 15+. All tables live in `public` unless noted. Helper functions live in schema `app`. Migrations are managed with the Supabase CLI (`supabase/migrations/`).

### 4.1 Multi-tenancy architecture

**Model:** shared database, shared schema, row-level isolation.

**Hierarchy**

- `organizations` 1─* `plants`.
- Every operational row carries **both** `org_id` and `plant_id`.
  - `org_id` makes org-level RLS cheap.
  - `plant_id` scopes day-to-day data.

**Composite FKs enforce consistency**

- A row's `(plant_id, org_id)` must match a real plant.
- The same pattern makes `(area_id, plant_id)` and `(station_id, plant_id)` agree, so a row can never point at another tenant's data.

**Memberships**

- `memberships(user_id, org_id, plant_id NULL, role)`.
- `plant_id NULL` means the membership applies to all plants in the org.

**JWT claims**

- A Custom Access Token Hook adds `app_org_id`, `app_role` and `app_plant_ids` to the token.
- RLS uses helper functions that read from `memberships` (STABLE, SECURITY DEFINER, indexed). This means role changes don't depend on token expiry for critical writes.

**RLS everywhere**

- Every table has RLS enabled, with **deny-by-default**.
- The service role, used only in Edge Functions, bypasses RLS.

**Devices**

- Displays and stations are real auth users with role `display` / `station`.
- They are bound via the `devices` table to one area or one station.

**Future scale-out**

If one tenant ever needs isolation, the `org_id` on every row allows extracting it to its own project with `pg_dump --where`-style tooling. No schema change is needed.

### 4.2 Entity-relationship overview

```
organizations ─┬─< plants ─┬─< areas ─┬─< stations ─┬─< operator_sessions >── operators
               │           │          │             ├─< production_logs >──── item_types
               │           │          │             └── devices (station)
               │           │          ├─< machines ──< washer_cycles >── wash_formulas >── item_types
               │           │          ├─< queue_items >── item_types
               │           │          └── devices (display)
               │           ├─< item_types
               │           ├─< soil_estimates >── item_types
               │           ├─< shifts ─< shift_instances ─< (production_logs, operator_sessions, washer_cycles)
               │           ├─< operators
               │           ├─< display_messages
               │           ├─< import_batches ─< washer_cycles
               │           ├─< pairing_codes
               │           └─< alert_events
               ├─< memberships >── auth.users ── profiles
               ├─< audit_log
               └─< app_events
```

### 4.3 Enumerated types

```sql
create schema if not exists app;
create extension if not exists pgcrypto;
create extension if not exists btree_gist;   -- for shift overlap exclusion

create type app.member_role   as enum ('owner','manager','lead','viewer','display','station');
create type app.area_kind     as enum ('washroom','finishing','folding','packing','other');
create type app.station_kind  as enum ('ironer','folder','mat_roller','packing','washroom','other');
create type app.machine_kind  as enum ('washer','dryer','ironer','folder','other');
create type app.item_category as enum ('mat','linen','apparel','towel','mop','other');
create type app.qty_unit      as enum ('basket','load','lbs','piece');
create type app.queue_status  as enum ('queued','in_progress','done','cancelled');
create type app.log_source    as enum ('station','manual','import','queue_completion');
create type app.cycle_source  as enum ('manual','accuflow_csv','accuflow_api');
create type app.lang          as enum ('en','es','ht');
create type app.device_kind   as enum ('display','station');
create type app.msg_severity  as enum ('info','urgent');
```

### 4.4 Tables (DDL)

> **Conventions**
> - `id uuid primary key default gen_random_uuid()`.
> - `created_at timestamptz not null default now()`.
> - `updated_at` maintained by trigger `app.touch_updated_at()`.
> - All timestamps are UTC (`timestamptz`).
> - Quantities are `numeric(12,2)`.
> - Text lengths are enforced by `check` constraints.

```sql
-- ── Tenancy ─────────────────────────────────────────────────────────────
create table organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 120),
  slug        text not null unique check (slug ~ '^[a-z0-9-]{3,40}$'),
  created_at  timestamptz not null default now()
);

create table plants (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete restrict,
  name        text not null check (char_length(name) between 1 and 120),
  timezone    text not null default 'America/New_York',
  estimate_amber_minutes int not null default 120 check (estimate_amber_minutes > 0),
  estimate_red_minutes   int not null default 240 check (estimate_red_minutes > estimate_amber_minutes),
  display_reload_local_time time not null default '04:00',
  created_at  timestamptz not null default now(),
  unique (id, org_id)                                   -- target for composite FKs
);

create table profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  full_name   text check (char_length(full_name) <= 120),
  language    app.lang not null default 'en',
  notify_email boolean not null default true,
  created_at  timestamptz not null default now()
);

create table memberships (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  org_id      uuid not null references organizations(id) on delete cascade,
  plant_id    uuid,                                     -- null = all plants in org
  role        app.member_role not null,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique nulls not distinct (user_id, org_id, plant_id)
);

-- ── Plant layout ────────────────────────────────────────────────────────
create table areas (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  name        text not null check (char_length(name) between 1 and 60),
  kind        app.area_kind not null,
  sort_order  int not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique (id, plant_id),
  unique (plant_id, name)
);

create table stations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  area_id     uuid not null,
  name        text not null check (char_length(name) between 1 and 60),
  kind        app.station_kind not null,
  credit_mode text not null default 'all_checked_in'
              check (credit_mode in ('all_checked_in','single_operator')),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (area_id, plant_id) references areas(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, name)
);

create table machines (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null,
  plant_id     uuid not null,
  area_id      uuid not null,
  name         text not null check (char_length(name) between 1 and 60),   -- "Washer 3"
  kind         app.machine_kind not null,
  vendor       text check (char_length(vendor) <= 60),                     -- "Milnor"
  model        text check (char_length(model) <= 60),
  capacity_lbs numeric(8,2) check (capacity_lbs > 0),
  external_ref text check (char_length(external_ref) <= 80),              -- Accu-Flow machine id
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (area_id, plant_id) references areas(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, external_ref)
);

-- ── Catalog ─────────────────────────────────────────────────────────────
create table item_types (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null,
  plant_id       uuid not null,
  name_en        text not null check (char_length(name_en) between 1 and 60),
  name_es        text check (char_length(name_es) <= 60),
  name_ht        text check (char_length(name_ht) <= 60),
  category       app.item_category not null,
  default_unit   app.qty_unit not null default 'basket',
  log_unit       app.qty_unit not null default 'piece',     -- unit used when logging output
  lbs_per_basket numeric(10,3) check (lbs_per_basket > 0),
  lbs_per_load   numeric(10,3) check (lbs_per_load > 0),
  pieces_per_lb  numeric(10,4) check (pieces_per_lb > 0),
  color_hex      text not null default '#64748B' check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order     int not null default 0,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique (id, plant_id),
  unique (plant_id, name_en)
);

create table wash_formulas (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null,
  plant_id       uuid not null,
  external_no    text not null check (char_length(external_no) between 1 and 20),  -- Accu-Flow formula #
  name           text check (char_length(name) <= 80),
  item_type_id   uuid,                                    -- null = unmapped / mixed
  created_at     timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (item_type_id, plant_id) references item_types(id, plant_id),
  unique (id, plant_id),
  unique (plant_id, external_no)
);

-- ── People & shifts ─────────────────────────────────────────────────────
create table operators (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  display_name  text not null check (char_length(display_name) between 1 and 60),
  language      app.lang not null default 'es',
  pin_hash      text not null,                            -- bcrypt via pgcrypto crypt()
  failed_pin_attempts int not null default 0,
  locked_until  timestamptz,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique (id, plant_id)
);

create table shifts (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  name          text not null check (char_length(name) between 1 and 40),
  start_local   time not null,
  end_local     time not null,                            -- end < start ⇒ crosses midnight
  days_of_week  smallint[] not null check (days_of_week <@ array[0,1,2,3,4,5,6]::smallint[]
                                           and cardinality(days_of_week) > 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique (id, plant_id),
  check (start_local <> end_local)
);

create table shift_instances (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  shift_id      uuid not null,
  business_date date not null,                            -- local date the shift starts
  starts_at     timestamptz not null,
  ends_at       timestamptz not null check (ends_at > starts_at),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (shift_id, plant_id) references shifts(id, plant_id),
  unique (id, plant_id),
  unique (shift_id, business_date),
  exclude using gist (plant_id with =, tstzrange(starts_at, ends_at) with &&)
);

-- ── Devices ─────────────────────────────────────────────────────────────
create table devices (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  user_id       uuid not null unique references auth.users(id) on delete cascade,
  kind          app.device_kind not null,
  area_id       uuid,                                     -- required for display
  station_id    uuid,                                     -- required for station
  name          text not null check (char_length(name) between 1 and 60),
  language_mode text not null default 'es+en' check (language_mode in ('en','es','ht','es+en','ht+en','es+ht')),
  app_version   text,
  last_seen_at  timestamptz,
  paired_at     timestamptz not null default now(),
  revoked_at    timestamptz,
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (area_id, plant_id) references areas(id, plant_id),
  foreign key (station_id, plant_id) references stations(id, plant_id),
  check ((kind = 'display' and area_id is not null and station_id is null)
      or (kind = 'station' and station_id is not null))
);

create table pairing_codes (
  code          text primary key check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),   -- no 0/O/1/I
  org_id        uuid not null,
  plant_id      uuid not null,
  kind          app.device_kind not null,
  area_id       uuid,
  station_id    uuid,
  device_name   text not null check (char_length(device_name) between 1 and 60),
  created_by    uuid not null references auth.users(id),
  expires_at    timestamptz not null,
  consumed_at   timestamptz,
  foreign key (plant_id, org_id) references plants(id, org_id)
);

-- ── Soil estimates (append-only) ────────────────────────────────────────
create table soil_estimates (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  item_type_id  uuid not null,
  qty           numeric(12,2) not null check (qty >= 0 and qty <= 100000),
  unit          app.qty_unit not null,
  note          text check (char_length(note) <= 280),
  entered_by    uuid not null references auth.users(id),
  entered_at    timestamptz not null default now(),
  client_id     uuid not null unique,                     -- idempotency
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (item_type_id, plant_id) references item_types(id, plant_id)
);

-- ── Queue ───────────────────────────────────────────────────────────────
create table queue_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  area_id       uuid not null,
  item_type_id  uuid not null,
  qty           numeric(12,2) not null check (qty > 0 and qty <= 100000),
  unit          app.qty_unit not null,
  position      numeric(30,15) not null,                  -- fractional ordering
  is_rush       boolean not null default false,
  status        app.queue_status not null default 'queued',
  note          text check (char_length(note) <= 140),
  assigned_station_id uuid,
  version       int not null default 1,                   -- optimistic concurrency
  created_by    uuid not null references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id),
  started_at    timestamptz,
  completed_at  timestamptz,
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (area_id, plant_id) references areas(id, plant_id),
  foreign key (item_type_id, plant_id) references item_types(id, plant_id),
  foreign key (assigned_station_id, plant_id) references stations(id, plant_id),
  check (completed_at is null or started_at is null or completed_at >= started_at),
  check ((status = 'done') = (completed_at is not null))
);

-- ── Production ──────────────────────────────────────────────────────────
create table operator_sessions (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  station_id        uuid not null,
  operator_id       uuid not null,
  shift_instance_id uuid,
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  auto_closed       boolean not null default false,
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (station_id, plant_id) references stations(id, plant_id),
  foreign key (operator_id, plant_id) references operators(id, plant_id),
  foreign key (shift_instance_id, plant_id) references shift_instances(id, plant_id),
  check (ended_at is null or ended_at > started_at),
  check (ended_at is null or ended_at - started_at <= interval '16 hours')
);
-- one open session per operator
create unique index operator_sessions_one_open
  on operator_sessions (operator_id) where ended_at is null;

create table production_logs (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  station_id        uuid not null,
  operator_id       uuid,                                 -- null = credited to all checked-in
  shift_instance_id uuid,
  item_type_id      uuid not null,
  queue_item_id     uuid references queue_items(id),
  qty               numeric(12,2) not null check (qty > 0 and qty <= 20000),
  unit              app.qty_unit not null,
  occurred_at       timestamptz not null default now(),   -- when the work finished
  started_at        timestamptz,                          -- optional batch timing (E5)
  source            app.log_source not null default 'station',
  entered_by        uuid not null references auth.users(id),  -- device or user account
  client_id         uuid not null unique,
  voided_at         timestamptz,
  voided_by         uuid references auth.users(id),
  void_reason       text check (char_length(void_reason) <= 200),
  created_at        timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (station_id, plant_id) references stations(id, plant_id),
  foreign key (operator_id, plant_id) references operators(id, plant_id),
  foreign key (shift_instance_id, plant_id) references shift_instances(id, plant_id),
  foreign key (item_type_id, plant_id) references item_types(id, plant_id),
  check (started_at is null or started_at <= occurred_at),
  check ((voided_at is null) = (void_reason is null))
);

-- ── Washroom ────────────────────────────────────────────────────────────
create table import_batches (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  plant_id      uuid not null,
  source        app.cycle_source not null,
  storage_path  text,                                     -- raw file in Supabase Storage
  file_sha256   text check (file_sha256 ~ '^[0-9a-f]{64}$'),
  status        text not null default 'pending'
                check (status in ('pending','previewed','committed','failed')),
  rows_total    int not null default 0,
  rows_inserted int not null default 0,
  rows_skipped  int not null default 0,
  errors        jsonb not null default '[]'::jsonb,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique (plant_id, file_sha256)
);

create table washer_cycles (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null,
  plant_id          uuid not null,
  machine_id        uuid not null,
  wash_formula_id   uuid,
  item_type_id      uuid,                                 -- resolved from formula or chosen manually
  shift_instance_id uuid,
  started_at        timestamptz not null,
  ended_at          timestamptz,
  weight_lbs        numeric(8,2) check (weight_lbs > 0 and weight_lbs <= 2000),
  load_count        int not null default 1 check (load_count between 1 and 200),  -- >1 for quick totals
  source            app.cycle_source not null,
  external_id       text,                                 -- vendor row id or derived hash
  import_batch_id   uuid references import_batches(id),
  raw               jsonb,                                -- original vendor row
  entered_by        uuid references auth.users(id),
  client_id         uuid unique,
  created_at        timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (machine_id, plant_id) references machines(id, plant_id),
  foreign key (wash_formula_id, plant_id) references wash_formulas(id, plant_id),
  foreign key (item_type_id, plant_id) references item_types(id, plant_id),
  foreign key (shift_instance_id, plant_id) references shift_instances(id, plant_id),
  check (ended_at is null or ended_at >= started_at),
  unique nulls distinct (plant_id, source, external_id)
);

-- ── Messaging, alerts, audit, analytics ─────────────────────────────────
create table display_messages (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  area_id     uuid,                                       -- null = all displays
  body_en     text check (char_length(body_en) <= 140),
  body_es     text check (char_length(body_es) <= 140),
  body_ht     text check (char_length(body_ht) <= 140),
  severity    app.msg_severity not null default 'info',
  starts_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  retracted_at timestamptz,
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now(),
  foreign key (plant_id, org_id) references plants(id, org_id),
  foreign key (area_id, plant_id) references areas(id, plant_id),
  check (coalesce(body_en, body_es, body_ht) is not null),
  check (expires_at > starts_at and expires_at <= starts_at + interval '12 hours')
);

create table alert_events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null,
  plant_id    uuid not null,
  kind        text not null check (kind in ('estimate_stale','device_offline','import_failed')),
  subject_id  uuid,                                       -- item_type / device / batch
  shift_instance_id uuid,
  sent_at     timestamptz not null default now(),
  recipients  text[] not null,
  foreign key (plant_id, org_id) references plants(id, org_id),
  unique nulls not distinct (kind, subject_id, shift_instance_id)   -- dedupe: 1 per shift
);

create table audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references organizations(id),
  plant_id    uuid,
  actor_user_id uuid references auth.users(id),
  actor_device_id uuid references devices(id),
  action      text not null,                              -- 'queue.move', 'item_type.update', …
  entity      text not null,
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  at          timestamptz not null default now()
);

create table app_events (
  id          bigint generated always as identity primary key,
  org_id      uuid not null references organizations(id),
  plant_id    uuid,
  user_id     uuid,
  device_id   uuid,
  name        text not null check (char_length(name) <= 60),   -- 'queue_reordered', …
  props       jsonb not null default '{}'::jsonb,
  at          timestamptz not null default now()
);
```

### 4.5 Triggers and key functions (behavior spec)

| Name | Type | Behavior |
|---|---|---|
| `app.touch_updated_at()` | BEFORE UPDATE trigger | Sets `updated_at = now()`. |
| `app.set_shift_instance()` | BEFORE INSERT on `production_logs`, `operator_sessions`, `washer_cycles` | If `shift_instance_id` is null, sets it to the instance whose range contains `occurred_at` / `started_at`. Leaves it null if there is none (off-shift work). |
| `app.resolve_item_from_formula()` | BEFORE INSERT/UPDATE on `washer_cycles` | If `item_type_id` is null and `wash_formula_id` is set, copies the formula's `item_type_id`. |
| `app.audit()` | AFTER INSERT/UPDATE on config tables, `queue_items`, `production_logs` (void), `item_types` | Writes to `audit_log` with before/after JSON. |
| `app.bump_queue_version()` | BEFORE UPDATE on `queue_items` | `version = old.version + 1`; sets `started_at` / `completed_at` on status transitions; rejects illegal transitions (e.g., `done → queued`). |
| `app.prevent_mutation()` | BEFORE UPDATE/DELETE on `soil_estimates` | Raises an exception (append-only). |
| `app.prevent_delete()` | BEFORE DELETE on `production_logs`, `washer_cycles`, `queue_items` | Raises an exception. Use void or cancel instead. |
| `app.throttle_device_writes()` | BEFORE INSERT on `production_logs` | If the inserting user is a station device with > 120 inserts in the last 60 s, raises `RATE_LIMITED`. |
| `app.generate_shift_instances(plant, days)` | function, pg_cron daily 00:05 UTC | Creates instances for the next N days; idempotent. |
| `app.close_stale_sessions()` | function, pg_cron every 10 min | Closes sessions past their shift end + 30 min, or older than 12 h; sets `auto_closed = true`. |

### 4.6 Views (reporting layer)

All views are `security_invoker = true`, so the RLS on the underlying tables applies.

| View | Purpose | Key columns |
|---|---|---|
| `current_soil_estimates` | Latest estimate per item, with age and freshness state | `plant_id, item_type_id, qty, unit, qty_lbs (nullable), entered_at, entered_by_name, age_minutes, freshness ('ok','amber','red')` |
| `queue_board` | Ordered queue per area (excludes done/cancelled), with item names in all languages | `area_id, id, position, is_rush, status, qty, unit, item names, note` |
| `shift_output_by_item` | Non-voided production totals per shift instance and item | `shift_instance_id, item_type_id, pieces, lbs (nullable), loads, partial_conversion bool` |
| `shift_output_by_station` | Same, by station | `shift_instance_id, station_id, pieces, lbs` |
| `station_operator_hours` | Sum of session hours per station per shift instance | `shift_instance_id, station_id, operator_id, hours` |
| `station_productivity` | Pieces and lbs per operator hour | `shift_instance_id, station_id, pieces_per_oh, lbs_per_oh` |
| `washroom_by_shift` | Loads and lbs per formula and item per shift | `shift_instance_id, item_type_id, loads, lbs` |
| `soil_vs_processed_daily` | Estimate vs. washed vs. finished per business date | `business_date, item_type_id, est_lbs_start, washed_lbs, finished_lbs` |

**Conversion rules (single source of truth: a SQL function `app.to_lbs(item_type_id, qty, unit)`):**
- `basket → lbs = qty × lbs_per_basket`
- `load → lbs = qty × lbs_per_load`
- `piece → lbs = qty / pieces_per_lb`
- `lbs → lbs = qty`
- If the needed factor is null, the function returns null and the view sets `partial_conversion = true`.

### 4.7 Row Level Security (summary matrix)

**Helper functions:**

```sql
-- true if current user has any of the roles on the plant (direct or org-wide membership)
create function app.has_role(p_plant uuid, p_roles app.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.plants p on p.id = p_plant
    where m.user_id = (select auth.uid())
      and m.revoked_at is null
      and m.org_id = p.org_id
      and (m.plant_id is null or m.plant_id = p_plant)
      and m.role = any (p_roles));
$$;

create function app.my_device() returns public.devices
language sql stable security definer set search_path = '' as $$
  select d.* from public.devices d
  where d.user_id = (select auth.uid()) and d.revoked_at is null;
$$;
```

**Policy matrix** (R = select, C = insert, U = update; anything blank is denied):

| Table | owner | manager | lead | viewer | display device | station device |
|---|---|---|---|---|---|---|
| organizations, plants | R U | R | R | R | R (own plant) | R (own plant) |
| memberships | R C U | R | — | — | — | — |
| areas, stations, machines, item_types, wash_formulas, shifts | R C U | R C U | R | R | R | R |
| shift_instances | R | R | R | R | R | R |
| operators (never exposes `pin_hash`; use the `operators_public` view) | R C U | R C U | R | — | R (names only) | R (names only) |
| devices, pairing_codes | R C U | R C U | R | — | own row R | own row R |
| soil_estimates | R C | R C | R C | R | R | R |
| queue_items | R C U | R C U | R U (status only, via RPC) | R | R (own area) | R (own area) |
| operator_sessions | R | R | R | — | — | R C U (own station, via RPC) |
| production_logs | R U (void via RPC) | R U (void via RPC) | R U (void via RPC) | R (totals via views) | — | R C (own station) |
| washer_cycles, import_batches | R C | R C | R C | R | — | R C (washroom station) |
| display_messages | R C U | R C U | R | R | R (own area or all) | R |
| audit_log, app_events | R | R | — | — | C (app_events only) | C (app_events only) |

Policies use `(select auth.uid())` and `(select app.has_role(...))` so that Postgres caches them per statement, per Supabase RLS performance guidance.

### 4.8 Indexing strategy

| Query | Index |
|---|---|
| Current estimate per item (latest row) | `soil_estimates (plant_id, item_type_id, entered_at desc)` |
| Queue board per area, ordered | `queue_items (area_id, position) where status in ('queued','in_progress')` (partial) |
| Rush first | covered by the above + `is_rush` in the sort; table is small |
| Shift report: logs per shift | `production_logs (shift_instance_id, item_type_id) where voided_at is null` (partial) |
| Logs per station over time | `production_logs (station_id, occurred_at desc)` |
| Sessions per station per shift | `operator_sessions (station_id, shift_instance_id)` |
| One open session per operator | partial unique index (defined above) |
| Washer cycles per shift | `washer_cycles (shift_instance_id, item_type_id)` |
| Import dedupe | unique `(plant_id, source, external_id)` (defined) |
| Shift instance lookup by time | GiST exclusion index on `(plant_id, tstzrange)` (defined) + `shift_instances (plant_id, starts_at)` |
| RLS membership checks | `memberships (user_id, org_id) where revoked_at is null` |
| Device lookup by auth user | unique `devices (user_id)` (defined) |
| Every FK column | B-tree index on every FK column. Supabase advisors flag any that are missing. |
| Audit lookups | `audit_log (org_id, entity, entity_id, at desc)` |
| Analytics | `app_events (org_id, name, at)` |

**Expected volumes (single plant):**
- About 200–600 production logs per day.
- About 50–150 washer cycles per day.
- About 50 estimate updates per day.
- That is roughly 300k rows a year: trivial for Postgres. No partitioning is needed before about 50 plants.

### 4.9 Data validation rules (summary)

**Validated in both places:**
- The client validates with Zod for instant feedback.
- **The database re-enforces every rule** with CHECK constraints, FKs, triggers and RPC guards. The client is never trusted.

| Field | Rule |
|---|---|
| Quantities | `> 0` (estimates allow `0` = cleared). Max 100,000 (estimates/queue) or 20,000 (single log). Two decimals. A UI confirm step appears above 5,000 per log. |
| Units | Must be one of `basket, load, lbs, piece`. Logging units are restricted per item `log_unit` unless a manager overrides. |
| Timestamps | `occurred_at` / `started_at` no more than 5 min in the future and no more than 7 days in the past (RPC check). Managers can backfill up to 30 days, which is audited. |
| Ranges | `ended_at > started_at`. Sessions ≤ 16 h. Shifts cannot overlap within a plant. |
| Text | Names 1–60 characters. Notes ≤ 140 (queue) / 280 (estimates). Trimmed. Control characters are rejected. |
| PIN | Exactly 4 digits. Not `0000`, `1234` or a repeated digit. Unique among active operators in a plant (checked in RPC by comparing hashes). |
| Pairing code | 6 characters from an unambiguous alphabet; expires in 15 min; single use. |
| Color | `#RRGGBB`. |
| Timezone | Must exist in `pg_timezone_names` (trigger). |
| Tenant consistency | Composite FKs guarantee area, station, item and machine belong to the same plant (and org) as the row. |
| Status transitions | `queued → in_progress → done`; `queued`/`in_progress → cancelled`. All others are rejected. |
| Idempotency | `client_id` UUID required on all device-originated inserts. Duplicates are ignored. |

---

## 5. API specification

### 5.1 Architecture recap (from tech-stack.md)

There is **no custom API server.** The API surface is made of four parts:

1. **Supabase Data API (PostgREST)** for simple table reads and writes, protected by RLS. Base: `https://<project>.supabase.co/rest/v1/`.
2. **RPC (Postgres functions)** for multi-step or validated operations. `POST /rest/v1/rpc/<function>`.
3. **Edge Functions (TypeScript/Deno)** for work needing the service role or external I/O. `POST https://<project>.supabase.co/functions/v1/<name>`.
4. **Realtime** for push updates to displays and phones.

**Common request requirements:**

- **Headers on every request:**
  - `apikey: <publishable anon key>`
  - `Authorization: Bearer <user or device JWT>`
  - `Content-Type: application/json`
- **Clients:** use `supabase-js`, never raw `fetch`, so tokens refresh automatically. Types come from `supabase gen types typescript`.

**Errors (PostgREST format):**

```json
{ "code": "P0001", "message": "QUEUE_VERSION_CONFLICT", "details": "expected 7, found 8", "hint": null }
```

**App error codes**, raised from RPCs as `message`:

| Code | Meaning |
|---|---|
| `QUEUE_VERSION_CONFLICT` | Someone else reordered or edited the queue first |
| `INVALID_STATUS_TRANSITION` | The requested status change isn't allowed |
| `PIN_INVALID` | Wrong PIN |
| `OPERATOR_LOCKED` | Too many wrong PINs; operator temporarily locked |
| `PAIRING_CODE_INVALID` | Pairing code is wrong |
| `PAIRING_CODE_EXPIRED` | Pairing code has expired |
| `RATE_LIMITED` | Too many requests |
| `NOT_AUTHORIZED` | Caller lacks the required role |
| `VALIDATION_FAILED` | Input failed validation; `details` holds the field and rule |
| `OUT_OF_RANGE_TIMESTAMP` | Timestamp outside the allowed window |
| `CONVERSION_MISSING` | A required unit conversion factor is not set |

**Auth legend** used in the tables below:

- **O** = owner
- **M** = manager
- **L** = lead
- **V** = viewer
- **D** = display device
- **S** = station device
- **SR** = service role (Edge Functions only)

### 5.2 Data API (PostgREST) resources

| Method & path | Purpose | Auth | Notes |
|---|---|---|---|
| `GET /plants?select=*` | Plant settings | All | RLS returns the caller's plants only |
| `GET/POST/PATCH /areas` | Areas CRUD | GET all; POST/PATCH O,M | Soft-delete via `active=false` |
| `GET/POST/PATCH /stations` | Stations CRUD | GET all; POST/PATCH O,M | |
| `GET/POST/PATCH /machines` | Machines CRUD | GET all; POST/PATCH O,M | |
| `GET/POST/PATCH /item_types` | Item catalog CRUD | GET all; POST/PATCH O,M | Audit trigger on conversion changes |
| `GET/POST/PATCH /wash_formulas` | Formula mapping | GET O,M,L,V,S; POST/PATCH O,M | |
| `GET/POST/PATCH /shifts` | Shift definitions | GET all; POST/PATCH O,M | Instances are regenerated by cron after changes |
| `GET /shift_instances?plant_id=eq.X&starts_at=gte.Y` | Shift lookup | All | |
| `GET /operators_public` | Operator names (no PIN hash) | O,M,L,D,S | View |
| `GET /current_soil_estimates?plant_id=eq.X` | Current estimates | All | View |
| `GET /soil_estimates?item_type_id=eq.X&order=entered_at.desc&limit=20` | Estimate history | O,M,L,V | |
| `GET /queue_board?area_id=eq.X&order=is_rush.desc,position.asc` | Queue for an area | All (D/S own area) | View |
| `POST /production_logs` | Log output (simple path) | S (own station), O,M | Body below; `Prefer: resolution=ignore-duplicates` with `on_conflict=client_id` |
| `GET /production_logs?station_id=eq.X&occurred_at=gte.Y` | Station history | O,M,L,S (own) | |
| `POST /washer_cycles` | Manual load entry | S (washroom), O,M,L | `source='manual'` enforced by RLS check |
| `GET/POST/PATCH /display_messages` | Broadcast messages | GET all; POST/PATCH O,M | PATCH is only for `retracted_at` |
| `GET /devices` | Device list & health | O,M,L | |
| `GET /audit_log?entity=eq.queue_items&entity_id=eq.X` | Audit trail | O,M | |
| `POST /app_events` | Analytics event | All | Insert-only |
| `GET` report views (`shift_output_by_item`, `station_productivity`, …) | Reports | O,M (productivity per operator), L,V (totals only) | |

**Example: `POST /rest/v1/production_logs?on_conflict=client_id`**

Request:

```json
{
  "org_id": "…", "plant_id": "…", "station_id": "…",
  "operator_id": null, "item_type_id": "…",
  "qty": 50, "unit": "piece",
  "occurred_at": "2026-11-03T23:41:10Z",
  "source": "station",
  "client_id": "5f0c3d6e-6a1e-4f7b-9a43-2d1c0b8e7f11"
}
```

Response (201, with `Prefer: return=representation`):

```json
[{ "id": "…", "shift_instance_id": "…", "qty": 50, "unit": "piece", "occurred_at": "2026-11-03T23:41:10Z", "voided_at": null }]
```

### 5.3 RPC functions

All functions are `security definer` with `set search_path = ''`. Each checks the caller's role explicitly and validates every argument.

| Function | Purpose | Auth |
|---|---|---|
| `update_soil_estimates(p_entries jsonb)` | Batch insert estimates | O,M,L |
| `create_queue_item(...)` | Add to queue | O,M |
| `move_queue_item(...)` | Reorder | O,M |
| `set_queue_rush(p_id uuid, p_is_rush bool, p_expected_version int)` | Toggle RUSH | O,M |
| `set_queue_item_status(...)` | Start / done / cancel | O,M,L; S (own area) |
| `start_operator_session(p_station_id uuid, p_operator_id uuid, p_pin text)` | Check in | S (own station) |
| `end_operator_session(p_session_id uuid)` | Check out | S (own station), O,M,L |
| `log_production(...)` | Validated log insert | S, O,M |
| `void_production_log(p_id uuid, p_reason text, p_replacement jsonb default null)` | Correct a log | O,M,L |
| `set_operator_pin(p_operator_id uuid, p_pin text)` | Create or reset PIN | O,M |
| `create_pairing_code(p_kind, p_area_id, p_station_id, p_device_name)` | Start pairing | O,M |
| `device_heartbeat(p_app_version text)` | Health ping | D,S |
| `get_display_feed(p_area_id uuid)` | Full display snapshot | D (own area), O,M,L,V |
| `get_shift_report(p_shift_instance_id uuid)` | Shift report payload | O,M (+ per-operator), L,V (totals) |
| `suggest_queue(p_area_id uuid)` (P1) | Draft queue from estimates | O,M |
| `upsert_washer_quick_totals(p_shift_instance_id, p_rows jsonb)` | End-of-shift loads | O,M,L, S (washroom) |

**Selected signatures, payloads and errors:**

**`update_soil_estimates`**
- Request: `{ "p_entries": [ { "item_type_id": "…", "qty": 6, "unit": "basket", "note": "recounted", "client_id": "…" } ] }`
- Response: `[ { "item_type_id": "…", "qty": 6, "unit": "basket", "entered_at": "…" } ]`
- Errors: `VALIDATION_FAILED`, `NOT_AUTHORIZED`

**`create_queue_item`**
- Request: `{ "p_area_id": "…", "p_item_type_id": "…", "p_qty": 4, "p_unit": "load", "p_is_rush": false, "p_note": "Country club", "p_client_id": "…" }`
- Response: the full `queue_items` row
- Places the item at `max(position)+1`, or at `min(position)-1` among rush items if `p_is_rush`.

**`move_queue_item`**
- Request: `{ "p_id": "…", "p_before_id": "…|null", "p_after_id": "…|null", "p_expected_version": 7 }`
- Behavior: the new position is the midpoint of the neighbors; the area is renumbered if the gap is < 1e-6.
- Response: `{ "id": "…", "position": 1.5, "version": 8 }`
- Errors: `QUEUE_VERSION_CONFLICT`, `NOT_AUTHORIZED`

**`set_queue_item_status`**
- Request: `{ "p_id": "…", "p_status": "done", "p_expected_version": 8, "p_actual_qty": 4, "p_client_id": "…" }`
- If `p_actual_qty` is given and the area is finishing, it creates a `production_logs` row (`source='queue_completion'`). For the washroom it creates `washer_cycles` (`load_count = qty`).
- Errors: `INVALID_STATUS_TRANSITION`, `QUEUE_VERSION_CONFLICT`

**`start_operator_session`**
- Response: `{ "session_id": "…", "operator": { "id": "…", "display_name": "…", "language": "es" } }`
- Errors: `PIN_INVALID` (increments the failure counter), `OPERATOR_LOCKED` (5 failures → `locked_until = now()+5m`)

**`log_production`**
- Request: `{ "p_station_id", "p_item_type_id", "p_qty", "p_unit", "p_operator_id", "p_occurred_at", "p_started_at", "p_queue_item_id", "p_client_id" }`
- Behavior: idempotent on `client_id`, and returns the existing row on a duplicate.
- Errors: `VALIDATION_FAILED`, `OUT_OF_RANGE_TIMESTAMP`, `RATE_LIMITED`

**`get_display_feed`**
- Response:

```json
{
  "area": { "id": "…", "name": "Washroom" },
  "server_time": "2026-11-03T23:42:00Z",
  "shift": { "name": "Night", "starts_at": "…", "ends_at": "…" },
  "now":  { "id": "…", "item": { "en": "White napkins", "es": "Servilletas blancas", "ht": null }, "qty": 4, "unit": "load", "is_rush": true, "note": "Club 6am", "status": "in_progress" },
  "next": [ { "id": "…", "item": { … }, "qty": 6, "unit": "basket", "is_rush": false } ],
  "later_count": 5,
  "later_total_loads": 12.5,
  "soil": [ { "item": { … }, "qty": 10, "unit": "basket", "age_minutes": 35, "freshness": "ok" } ],
  "messages": [ { "id": "…", "severity": "urgent", "body": { "en": "Truck leaves 5:30", "es": "El camión sale 5:30" }, "expires_at": "…" } ],
  "done_this_shift": [ { "item": { … }, "qty": 3, "unit": "load", "completed_at": "…" } ]
}
```

**`get_shift_report`**
- Response: `{ shift, totals_by_item[], totals_by_station[], washroom[], queue: {completed, remaining}, soil: {start[], end[]}, productivity[] (O/M only), partial_conversion: bool }`

### 5.4 Edge Functions

| Function | Trigger | Auth | Purpose |
|---|---|---|---|
| `invite-user` | HTTP POST | O (verified from JWT + membership) | `{ email, role, plant_id? }` → Supabase Admin `inviteUserByEmail`, insert membership. Returns `{ user_id }`. |
| `revoke-user` | HTTP POST | O | Marks membership revoked and signs out all sessions (`auth.admin.signOut`). |
| `pair-device` | HTTP POST | **Public** (code is the credential) | `{ code }` → validates code, creates the device auth user, membership and `devices` row, consumes the code, returns `{ access_token, refresh_token, device }`. **Rate limit:** 10 attempts per IP per 10 min (tracked in a `pairing_attempts` table), plus a constant-time compare. |
| `revoke-device` | HTTP POST | O,M | Sets `revoked_at`, signs out the device user. The display's Realtime presence channel receives an `unpaired` broadcast. |
| `import-washer-file` (P1) | HTTP POST (multipart) | O,M,L | Stage 1 `preview`: store the file, parse, return rows + issues. Stage 2 `commit`: insert with dedupe, return a summary. Max 10 MB, CSV/XLSX only. |
| `accuflow-sync` (P2) | pg_cron → HTTP | SR | Pulls from the vendor API if available. |
| `dispatch-alerts` (P1) | pg_cron every 15 min | SR | Evaluates stale-estimate and device-offline rules, dedupes via `alert_events`, sends via Resend. |

### 5.5 Realtime channels

| Channel | Mechanism | Subscribers | Payload / action |
|---|---|---|---|
| `plant:{plant_id}:queue` | Postgres Changes on `queue_items` (filter `plant_id=eq.X`) | Displays (own area, filtered client-side by `area_id`), phones | Row change → patch the TanStack cache; on any gap, refetch `get_display_feed` |
| `plant:{plant_id}:soil` | Postgres Changes on `soil_estimates` (INSERT) | Displays, phones | New estimate → update the soil panel |
| `plant:{plant_id}:messages` | Postgres Changes on `display_messages` | Displays | Show or remove a banner |
| `plant:{plant_id}:control` | Broadcast | Displays | `{ type: "reload" }`, `{ type: "unpaired", device_id }`, sent by owners/managers via the device admin UI |
| `plant:{plant_id}:presence` | Presence | Displays and stations track themselves | Live online status for the device list (supplements heartbeat) |

**Rules for Realtime:**
- Realtime respects RLS for Postgres Changes. Enable it per table via the `supabase_realtime` publication, for the tables above only.
- **Clients must never trust Realtime alone.** Refetch the full feed on connect, on reconnect, every 5 min as a safety net, and on `visibilitychange`.

### 5.6 Authentication requirements summary

| Actor | Sign-in | Token lifetime | Notes |
|---|---|---|---|
| Owner / manager / lead / viewer | Email magic link (or email + password) via Supabase Auth | Access 1 h, refresh rotating | MFA (TOTP) **required for owners** (P1), optional for others |
| Display device | Pairing code → device account | Refresh token persisted on device; long-lived | Read-only RLS; revocable |
| Station device | Pairing code → device account | Same | Insert-only on own station; operator identity via PIN inside the app |
| Operator | PIN on a paired station | No token. The session lives in `operator_sessions` | **Attribution, not authentication.** |
| Edge Functions | Service role key (server env only) | — | Never shipped to clients |

### 5.7 Rate limiting considerations

Supabase gives some limits out of the box; the rest are added at the app level.

| Surface | Limit | Mechanism |
|---|---|---|
| Auth (magic link, sign-in) | Supabase defaults (configurable in the dashboard). Magic-link emails are limited per hour. | Supabase Auth rate limits. Use custom SMTP (Resend) to avoid the default email cap. |
| Pairing | 10 attempts / IP / 10 min; codes expire in 15 min | `pair-device` Edge Function + `pairing_attempts` table |
| PIN entry | 5 failures → 5-minute operator lock at that station | `start_operator_session` RPC |
| Station writes | 120 production logs / device / minute | `app.throttle_device_writes` trigger |
| Reads | Max 1,000 rows per request; `statement_timeout` 5 s for `authenticated` | PostgREST `max_rows` + role setting |
| Realtime | One socket per client; ≤ 5 channels per client | Client design. Within the Pro plan quota at ADB scale. |
| Edge Functions | File import 1 concurrent per plant; 10 MB max | Function guard via an `import_batches` status check |
| Display polling safety net | Full refetch ≤ every 5 min | Client timer |

There is **no general per-IP API rate limiting at the PostgREST layer** at this stage. Abuse risk is low: no public signup, and every endpoint requires a JWT tied to a membership. If this becomes multi-tenant SaaS, revisit with a WAF (Cloudflare) in front of custom domains.

---

## 6. Non-functional requirements

### 6.1 Performance targets

| Metric | Target | How measured |
|---|---|---|
| Phone action → display updated (queue reorder, estimate, rush) | **p95 ≤ 2 s**, p50 ≤ 1 s on plant Wi-Fi | Timestamp in the RPC response vs. display receive time, logged to `app_events` during pilot |
| Optimistic UI response on phone | ≤ 100 ms | Manual + Playwright |
| Station log tap → "saved" confirmation | ≤ 200 ms (local), synced ≤ 5 s when online | `app_events` |
| Display cold load (paired device) | ≤ 3 s to first meaningful paint on a $50 Android TV box | Lighthouse / manual |
| Phone cold load (4G) | ≤ 3 s; JS ≤ 250 KB gzipped for the initial route (code-split per surface) | Bundle analyzer in CI |
| Shift report generation | ≤ 1.5 s for a 12-hour shift with ≤ 1,000 logs | RPC timing |
| Display memory stability | No growth > 50 MB over 72 h; nightly reload as backstop | Chrome memory sampling in pilot |
| **Availability (plant hours)** | 99.5% monthly, bounded by Supabase/Netlify SLAs; degraded mode (last known board + offline banner) during outages | Heartbeat data |
| Offline tolerance | Station: 8 h / 2,000 entries queued. Display: shows last state with a clear offline banner. | Test by unplugging the access point |
| Data durability | RPO ≤ 24 h (daily backups + nightly `pg_dump`); RTO ≤ 4 h | Restore drill before launch |

### 6.2 Security requirements

1. **RLS on every table, deny by default.**
   - CI runs the Supabase security advisor and fails on "RLS disabled" or "policy missing".
   - Automated tests assert each role's access matrix in §4.7.
2. **Least privilege for devices.** Displays can read only. Stations can insert only for their own station. Revocation takes effect in ≤ 60 s.
3. **Secrets.**
   - The service role key exists only in the Edge Functions environment.
   - Only the publishable (anon) key is in the client.
   - No secrets in the repo; GitHub secret scanning is on.
4. **PINs** are bcrypt-hashed (`pgcrypto`), never returned by any API, and locked out after 5 failures.
5. **Owner accounts require MFA (TOTP)** from P1. Magic links expire in 1 hour.
6. **Transport:** HTTPS only (HSTS via host). Realtime over WSS.
7. **Audit:** all configuration, queue, estimate and void actions are written to `audit_log`, retained ≥ 2 years.
8. **Backups:** Supabase daily backups plus a nightly encrypted `pg_dump` to Cloudflare R2. Restore is tested before launch and quarterly after.
9. **Environments:** separate dev and prod. The Supabase MCP server is pointed at dev only, read-only against prod.
10. **Dependencies:** Dependabot / `npm audit` in CI; pinned versions.
11. **Workforce data & fairness (policy requirement):**
    - Productivity data is **operational, not payroll.** The app must not be used as a timekeeping system of record.
    - Per-operator metrics are visible only to owners and managers, and **never on wall displays by default.**
    - The crew is told in writing, in their languages, what is recorded and why, before launch.
    - Any use of these metrics for pay or discipline gets HR/legal review first. This matters given the prior wage-and-hour matter noted in the company dossier.
12. **Data retention:**
    - Production, washer and estimate data: kept indefinitely (it is operational history).
    - `app_events`: 13 months.
    - Pairing codes: purged after 24 h.
    - Uploaded import files: 1 year.

### 6.3 Accessibility standards

- **Control and station surfaces:** WCAG 2.2 Level AA.
- **Wall displays:** exceed AA. Text contrast ≥ 7:1 (AAA) because of distance, glare and steam.
- **Color is never the only signal.** RUSH, freshness and offline states always combine color + icon + text.
- **Touch targets:**
  - ≥ 48×48 px on phones.
  - **≥ 64×64 px on station tablets**, because of gloves and wet hands.
  - ≥ 8 px spacing between targets.
- **Typography:** display minimum 32 px (NOW ≥ 96 px); phone body ≥ 16 px; supports system font scaling to 200% without loss of function.
- **Motion:** respects `prefers-reduced-motion`. The RUSH pulse is ≤ 3 s, with no flashing > 3 Hz.
- **Language:** `lang` attributes set per element for mixed-language displays, so screen readers pronounce them correctly.
- **Low literacy:** icons accompany every item category and action; numbers dominate; no long text on station or display screens.
- **Keyboard and screen reader:** the control app is fully operable by keyboard (drag-and-drop has up/down button alternatives) and labelled for VoiceOver/TalkBack.

### 6.4 Mobile responsiveness requirements

| Surface | Target devices | Requirements |
|---|---|---|
| Control (owner/manager) | Phones 360–430 px wide, portrait first; works up to desktop | Bottom tab navigation; no horizontal scroll at 360 px; one-handed reach for primary actions; installable PWA (iOS 16.4+, Android Chrome) |
| Station | Tablets 768–1280 px, **landscape**, mounted | Fixed layout; no scrolling for core flow (check-in → item → qty → confirm); works at 1024×600 budget tablets |
| Display | 1920×1080 (primary), 3840×2160 (scaled), 1366×768 (fallback); portrait 1080×1920 (P2) | Viewport-relative typography; no scrolling; nothing interactive required |

Supported browsers:
- Last 2 versions of Chrome/Chromium (incl. Android System WebView and Fully Kiosk Browser), Safari iOS 16.4+, Edge.
- Firefox is best-effort.

---

## 7. Out of scope

### 7.1 Not in MVP (explicitly)

| Not building | Why / instead |
|---|---|
| Payroll, timekeeping, or attendance | Legal risk and existing systems. Operator sessions are attribution only. |
| Route, delivery or driver management | A separate problem. The soil estimate stays manual. |
| Customer accounts, invoicing, contracts, pricing | Belongs in the business/billing system. |
| RFID, barcode or per-piece linen tracking | Hardware and process cost; v2+ consideration. |
| Machine control (writing to Milnor washers or Accu-Flow) | Read-only integration at most; safety and warranty risk. |
| Automated Accu-Flow API integration | Contingent on Diamond Chemical (F4, P2). MVP uses manual entry; CSV upload is P1. |
| Chemical usage / cost management | Diamond's portal already covers it. |
| Maintenance work orders / CMMS | Use an existing tool. Downtime reasons are P2. |
| Native iOS/Android or TV apps | PWA covers all surfaces (tech-stack decision). |
| Self-serve signup, billing, plans (SaaS) | Multi-tenant *schema* yes; multi-tenant *product* no. |
| Org/plant admin UI | Seeded by script for MVP (A1). |
| AI forecasting / automatic scheduling | `suggest_queue` (P1) is rules-based and always human-approved. |
| SMS or WhatsApp notifications | Email only in MVP (cost and complexity). |
| Per-operator leaderboards on wall screens | Fairness and morale risk (§6.2). |
| Public API / third-party integrations | None needed yet. |

### 7.2 Future considerations (v2+)

1. **Automated Accu-Flow feed** (API or scheduled email) → live washer status on the washroom display.
2. **Route-informed soil estimates:** pre-fill estimates from route pickup counts, if the route system can export them.
3. **Targets & staffing planner:** set per-shift targets by item; suggest crew size from historical productivity.
4. **Downtime & OEE** for the ironer: reasons, durations, availability × performance.
5. **Queue templates and recurring customer priorities** (e.g., "Country club linens always before Friday 6 am").
6. **Portrait and ultra-wide display layouts**; multiple displays per area with different views.
7. **SMS/WhatsApp alerts** for owners.
8. **Multi-plant SaaS:** org admin UI, self-serve onboarding, Stripe billing, per-tenant branding, a WAF and per-tenant rate limits. Only pursue after 6+ months of proven ADB results (see the viability analysis).
9. **RFID/barcode** integration for per-piece counts at finishing.
10. **Spanish/Creole voice prompts** at stations for low-literacy users.

---

## 8. Success metrics

### 8.1 What "working" means

The product works if **the owner stops dispatching by phone, the floor follows the screens, and every shift produces a trustworthy output record.** That gives three metric groups:

| Group | North-star metric | Supporting metrics |
|---|---|---|
| **Dispatch moved to screens** | **Direction phone calls per shift** (owner/manager tally) | Queue actions from phone per day; % of shift time each display is online; median time from queue change to display |
| **Data is current and trusted** | **Median soil-estimate age during shifts** | % of items updated ≥ 2× per shift; estimate accuracy (% error vs. processed, G3) |
| **Output is captured** | **% of shift output logged in-app** (vs. paper/known totals) | Production logs per shift; voided-log rate; washroom loads recorded vs. Accu-Flow totals |
| Adoption & sentiment | Weekly active managers; operator check-ins per shift | 3-question crew pulse at week 1 and month 1: clear? easy? fair? |

### 8.2 Baseline (required before launch)

During the **one-week no-code pilot** recommended in the viability analysis, or the week before launch at the latest:
- The owner and managers tally **direction phone calls per shift**.
- Record how output is currently known (paper sheets, memory) and an estimate of the % actually captured.
- Note how many times per shift priorities change.

**Without a baseline, the main success metric can't be proven.** Treat this as a launch gate.

### 8.3 Targets

| Metric | Launch week | Month 1 | Month 3 |
|---|---|---|---|
| Direction phone calls per shift (vs. baseline) | −30% | **−50%** | **−70%** |
| Display online during shift hours | ≥ 95% | ≥ 98% | ≥ 99% |
| Phone → display latency p95 | ≤ 3 s | ≤ 2 s | ≤ 2 s |
| Median estimate age during shifts | ≤ 4 h | ≤ 3 h | ≤ 2 h |
| Items with estimate updated ≥ 2× per shift | ≥ 50% | ≥ 75% | ≥ 90% |
| Shift output logged in-app | ≥ 60% | ≥ 90% | ≥ 95% |
| Washroom loads recorded (manual or import) vs. Accu-Flow totals | ≥ 70% | ≥ 90% | ≥ 98% (import live if Diamond allows) |
| Voided-log rate (data quality) | ≤ 10% | ≤ 5% | ≤ 3% |
| Shift report opened by owner/manager | ≥ 3 of 5 days | daily | daily |
| Estimate accuracy (abs % error, daily, by lbs) | measure only | ≤ 30% | ≤ 20% |
| Productivity (pieces or lbs per operator hour) | measure only | baseline established | **+5–10% vs. month-1 baseline** (hypothesis, not a promise) |
| Data-loss incidents (entries lost offline) | 0 | 0 | 0 |
| Crew pulse: "screen is clear" (agree) | ≥ 60% | ≥ 75% | ≥ 80% |

### 8.4 Kill / pivot criteria

At the **month-1 review**, pause feature work and fix fundamentals if any of these holds:
- Direction calls are down less than 25%.
- Displays are online less than 95% of shift time.
- Less than 60% of output is logged in-app.

In that case, investigate whether the cause is process (ownership of estimates, crew training) or product (UX, hardware). If month 3 still misses these thresholds, reconsider buying an off-the-shelf tool (e.g., Spindle) instead of continuing to build. That was the alternative identified in the viability analysis.

### 8.5 Instrumentation

**`app_events` names:**

| Event | Meaning |
|---|---|
| `queue_item_created` | A queue item was added |
| `queue_reordered` | The queue order changed |
| `queue_rush_set` | An item was marked RUSH |
| `queue_status_changed` | An item was started, completed or cancelled |
| `estimate_updated` | A soil estimate was saved |
| `operator_checked_in` | An operator checked in at a station |
| `production_logged` | Output was logged |
| `production_voided` | A log was voided |
| `display_offline` | A display went offline |
| `display_online` | A display came back online |
| `display_latency_sample` | One phone-to-display latency measurement |
| `report_viewed` | A report was opened |
| `import_committed` | A washer data import was committed |

- **Phone-call tally:** a simple "+1 call" counter in the owner's control app (P0, two taps). This is the only reliable way to measure the north-star metric.
- **Weekly metrics view:** a SQL view `weekly_success_metrics` (P1) computes §8.3 directly from the tables.

---

## 9. Delivery plan (indicative)

Follows the complexity estimate in the viability analysis.

| Phase | Scope | Duration |
|---|---|---|
| 0. Prep | Baseline tally; Diamond call; item list + conversions; shift schedule; Wi-Fi survey; hardware ordered | 1 week (parallel with build start) |
| 1. Foundation | Schema + RLS + tests; seed ADB; auth + invites; device pairing | Week 1–2 |
| 2. Core loop | Estimates (B1–B2); queue (C1–C4); displays (D1–D2); i18n EN/ES | Week 2–4 |
| 3. Capture | Station check-in & logging incl. offline (E1–E4); manual washer entry (F1–F2); shift report (G1); audit and events | Week 4–6 |
| 4. Pilot & harden | Install screens; 1-week pilot on one shift; fix; full rollout | Week 6–7 |
| P1 follow-ups | Alerts, broadcast messages, heartbeat alerts, productivity, CSV import, HT language, owner MFA | Weeks 8–12 |

---

## 10. Assumptions & risks (carried from research)

| # | Assumption / risk | Mitigation |
|---|---|---|
| 1 | Diamond allows some data export | Manual entry (F1) makes the product work without it |
| 2 | Formulas map cleanly to item types | `wash_formulas.item_type_id` nullable; "mixed" supported |
| 3 | Managers will keep estimates current | Freshness cues, stale alerts, 3-tap update; ownership assigned per shift |
| 4 | Plant Wi-Fi reaches screen locations | Survey in prep phase; wired AP if needed; offline modes |
| 5 | Heat/humidity damage hardware | Mount outside wet zone or use enclosures; budget spares |
| 6 | Crew perceives tracking as surveillance | Team totals on screens; written explanation in crew languages; no pay use without review |
| 7 | Supabase/Netlify pricing changes | Standard Postgres + static SPA; portable to other hosts |
