# Owner answers (dated)

Owner answers and decisions for 2026-11-01 to 2026-11-09. The 2026-11-01 to 2026-11-06 blocks were moved here verbatim from `.claude/CLAUDE.md` "Current state" on 2026-11-09 (that file was over the 200-line limit). Nothing was reworded. Where answers conflict, the later answer supersedes the earlier one, as the original blocks say. Build status is in `research/build-history.md`.

## 2026-11-01

- **Owner answers 2026-11-01 (built, 432 pgTAP tests pass; security-reviewer PASS WITH NOTES):**
  - Staff admin: owner, plus managers the owner grants (`memberships.can_manage_staff`).
  - Production day runs **12:00 → 12:00** (`plants.production_day_start`, `shift_instances.production_date`). Report views now use `production_date`, `loads_run` and `standard_loads`.
  - Washer 6 (160 lb) has `machines.load_factor` 1.19; washers 1–5 (135 lb) are 1.00.
  - Seed: 48 items (tablecloths per size+color, 14 napkin colors, towels and wipes in packs of 50, sheets in packs of 10) and 10 machines. Sign-ups are OFF.

## 2026-11-02

  - Washroom tapping: the washman taps each washer start, on every shift. **Taps carry no name or PIN** (owner 2026-11-02). The tablet is a washroom station, because washmen overlap and per-washman loads would be per-worker output. Manager corrections use name + PIN.

## 2026-11-03

### Sign-in decision
  - **Sign-in (owner decision 2026-11-03): username + password; the owner creates every account. No email is ever sent, and Resend/DNS are off the critical path.** Magic links were dropped because they open in Safari, not the installed iOS app.
    - Usernames map to `<u>@accounts.adbheadquarters.com`; a typed value containing "@" is used as-is (the owner signs in with their Gmail).
    - Edge Function `manage-users` (create / reset / deactivate / list / change_own_password).
    - Forced password change is enforced in the DB (`app.password_ok()` gates has_role/has_org_role/can_manage_staff).
    - 592 pgTAP tests pass; security-reviewer PASS WITH NOTES (2 rounds).
    - Cloud: the owner account (`mannyruiz.adb@gmail.com`) has an org-wide owner membership; `profiles.full_name` = 'Manny Ruiz'.
    - **LIVE 2026-11-03:** PR #4 merged; deploy-db run 3 applied the migration (20 in the cloud, latest 20261103202156) and deployed `manage-users` (ACTIVE, verify_jwt). CORS answers only https://adb-plantboard.netlify.app.
    - The owner set the cloud minimum password length to **6**; I recommended 10. The function still enforces ≥ 10 on change_own_password.
    - The null MX record was skipped. `accounts.adbheadquarters.com` is NXDOMAIN with no wildcard (checked), so mail to it can't be delivered.
    - Carry-forward: the Custom Access Token Hook must keep `app_metadata` in the JWT, or the password gate silently passes.

### Launch scope
- **Launch scope (owner 2026-11-03): build the whole app and release it all at once; TVs last.**
  - Day-one screens:
    - queue + washer control (start taps from managers' phones);
    - dirty-work estimates;
    - finished goods (name + PIN);
    - reports: shift report, day report, pace screen.
  - In-app setup: items + wash groups, people + entry staff, washers + formulas, shifts.
  - First users are the owner and managers only. The washroom tablet and TVs come later.
  - Build order: server RPCs + pg_cron → setup screens → queue/washer → estimates → finished goods → reports/pace. Merge in PRs; the owner starts using it when all are done.

## 2026-11-04

- **Owner answers 2026-11-04 (now built, see above):**
  - **The M2 screens were lost.** They were never committed and the session container was reset. The server side survived (`d496d09`). Rebuild them, and push WIP at every checkpoint from now on.
  - PIN reuse: 10 minutes on a phone, "for now".
  - Offline entries: no second PIN when they finally send ("too much stuff"). Proposed: keep the pending entry plus its PIN on the device until it sends, then wipe it (PINs are attribution only). Needs security-reviewer sign-off.
  - "Entered by <name>": the owner wants it, **on the owner's screens only**. Managers and others never see names. Reports never total by person.
  - Managers should see only what they need, not all the owner's data. This is a role/RLS change: get the owner to confirm a screen-by-screen matrix before building.
  - Pilot: for 2–3 weeks the owner is on site nightly and taps washer starts on their phone or the company tablet. Then a tablet at each of the 6 washers (pick the wash group; the formula follows; one green START) plus a removable tablet in finishing. The owner will pay for the tablets.
  - Open: what estimates are, explained to the owner; the meaning of wash group colors, explained; pace with 3 cards.
- **Owner answers 2026-11-04, round 2 (these supersede round 1 where they conflict):**
  - **Pilot target: Monday 2026-11-09.** The owner is tallying baseline calls this week.
  - The owner's father gets his own account with owner access.
  - **No "entered by" names anywhere, the owner's screens included.** Finished goods are entered by the shift manager only, one person per shift.
  - **Estimates ship from day one.** Denise enters them; train while the owner is on site. The owner wants a clear, well-designed screen, not just +/− buttons.
  - Wash group colors: preset them, yes.
  - **Machine breakdowns:** a "machine down" status, shown on the owner boards. Add **automatic notifications** to selected owners and managers (e.g. "Washer 4 down"). The owner asked for text messages; SMS is a paid service, so get approval first.
  - **Washroom TVs stay** (above the washers; the whole crew sees them). Washer tablets come later, maybe iPads with Guided Access. Build the per-washer station screen now so a tablet only has to open its URL.
  - **Queue: managers can only view it; editing is owner-only.** Today the server lets `{owner,manager}` call create/reorder/update/cancel (`20261103212040`), so a migration must restrict them to owner. Open: may managers still move a load off a broken washer (2026-11-02 decision), and who creates rewash items from finishing?
  - **Owner 2026-11-04, round 3 (queue exceptions, containers, a second customer):**
    - Managers may move a load off a washer that broke down.
    - Shift managers may add **rewash** items at the bottom of the queue (wash group + how full a basket/bin). Every other queue edit is owner-only.
    - **Two containers:** *bins* (tall, 5–6 ft; mostly linen) and *baskets* (half the height, longer; mats, sometimes linen). Loads per full container are estimates, not rules:
      - mats per basket 3.5;
      - kitchen towels per basket 2, per bin 2.5;
      - sheets per bin 2;
      - napkins (all colors) per bin 2;
      - tablecloths per bin 2 (confirm).
      - This needs a per-group factor for each container, so it **is** a schema change (`research/estimate-bins.md`).
    - **AA Linen:** a second customer whose volume varies. Kitchen towels, aprons, mats, napkins and tablecloths arrive, always in bins. Not modeled yet; ask the owner whether it must be tracked separately.
  - **Pace screen: deferred (not for Monday), and owner-only when built.** Its layout and the ship-next-morning groups are still undecided.
  - **Alerts: push notifications approved (free Web Push to the installed app), not SMS.**
  - **Estimates by bin fill** (¼ / ½ / ¾ / full, several bins allowed) × loads per full bin per wash group. No schema change: `unit='basket'`, `baskets_per_load = 1/loads_per_bin`. Numbers are pending in `research/estimate-bins.md` (owner examples: mats 5–6, kitchen towels 2–3, linens ≈ 2).
  - Accu-Flow lags about 10 minutes, so it is for cross-checking reports only, not the live source. The owner offered the CloudView login: still **never scrape the portal**; ask for exported files instead.

## 2026-11-05

- **Owner answers 2026-11-05 (one-shot list; supersede earlier where they conflict):**
  - Web Push library: **approved**.
  - **Upload to the cloud as soon as it's ready.** The owner wants to try every screen live and then request changes. Open the PR: yes.
  - Monday accounts: owner, father, Denise. **All managers** get accounts, entry-staff PINs and machine-down alerts (`notify_machine_down` default true for managers too).
  - **Machines to add:** compressor, soap machine, boiler, ironer, folder, wrapping machine, water pump. Machines and down reasons must be **editable in the app** (Setup); reasons become data, not an enum.
  - **Spanish wording:** EMPEZAR, Estimados, "bin" (keep the English word), Fuera de servicio / Arreglada, Mapos, Próximo / Relavar / Urgente. Spanish only, no Creole.
  - Monday scope: OK (taps, board, queue, machine down, estimates, alerts). Finished goods, reports and TVs come later; the TVs go up when the app is fully ready.
  - **Managers: current shift totals only, NOT the previous shift.** Everything else per the matrix: confirmed. Lock it server side.
  - **Load factors:** editable by owners only, plus anyone the owner grants (a new grantable permission like `can_manage_staff`).
  - 30-minute late tap: the owner wants it "alarmed". Interpretation pending (late tap vs. load behind schedule).
  - Tablecloths: 2 loads per bin, confirmed. **Mats: 4 loads per full bin** (AA Linen mats).
  - Napkin colors, pieces per load and the remaining factors: the owner wants **one fill-in sheet** covering every wash group and item.
  - **AA Linen:** washed separately, processed about midnight to midday. The owner wants to see **washing time spent on AA Linen**. That needs a customer tag on queue items and washer cycles; for now its loads go in the queue.
  - Ship next morning: carpets, sheets, butcher coats. Truck times vary.
  - Production day 12:00→12:00: confirmed (this closes the old business-day question). **Holidays: closed only on the day of Christmas, New Year's and Thanksgiving.**
  - Washer tablets: undecided.
  - **New feature requests:**
    1. **Tasks:** the owner sends a job to a named manager ("check all parked trucks"). She gets a push immediately, it stays open until she confirms it's done, and then the owner and father are notified. This is per-person work direction, not output data. No completion-time stats or ranking per person (HR/legal note).
    2. **Driver load-out list:** from midnight to midday, Denise sees what each driver needs (sheets, butcher coats, plus special items the owner adds). The source of the quantities is undecided (owner entry vs. LinenTrack par levels).
  - Not yet answered: #29 Diamond export sample, #30 call tally, #31 Supabase net-grant fix, #32 GitHub branch protection, #33 password length.

## 2026-11-06

Order below follows the source bullets in CLAUDE.md. "The answers in the PR #9 bullet above" in the third block refers to the first block here.

### PR #9 bullet (owner answers)
  - Owner answers 2026-11-06:
    - Task window: 7 days is only the list window (tasks are never deleted). A done task leaves the list once ONE owner reviews it (`review_task`). Managers see only open tasks.
    - Alerts: per-person Clear / Clear all finished (`alert_dismissals`). Live alerts can't be cleared; `route_loaded` is always clearable; `task_done` stays live until reviewed.
    - Old audit names: NOT scrubbed (owner wants them).
    - Names: the owner role sees who entered (queue creator, machine status, load-out lines and loaded, tasks; owner-only reads `get_soil_estimate_entries`, `get_finished_goods_entries`, `get_machine_status_history`), for accountability. Managers never see names. No totals by person. Washer taps stay anonymous. This reverses the 2026-11-04 "no names anywhere" rule for owners only.
    - Father: full owner access, with his own washer-idle switch (`memberships.notify_washer_idle`, `set_washer_idle_alert`). The manager on duty always gets idle alarms (owner OK).
    - Soil bags, Spanish: "Bolsas".

### UI redesign
- **UI redesign approved (2026-11-06):** follow `research/design/README.md`. Stitch style, dark theme for all, one language per person, self-hosted Barlow Condensed / JetBrains Mono / Inter. Drop names, weights, invented data, snooze/signatures.

### Third cloud upload (owner decisions open)
  - Owner decisions open (resolved items struck through; answers in the PR #9 bullet above):
    - ~~task timing window (rec 7 days)~~ **resolved 2026-11-06:** 7 days is the list window only; done tasks leave after one owner review;
    - ~~scrub old audit names~~ **resolved 2026-11-06:** NOT scrubbed;
    - ~~father's opt-out of idle alarms~~ **resolved 2026-11-06:** per-owner washer-idle switch;
    - soap wording (open);
    - ~~Spanish for soil bags~~ **resolved 2026-11-06:** "Bolsas";
    - "Lavadora N" in pushes (open).
  - Owner to do before Monday: tick each manager's usual shifts in People.

### Pilot bullet (owner 2026-11-06, round 1 and 2, routes, soil bags)
  - Owner 2026-11-06:
    - Tasks re-notify every **10 minutes** until done.
    - **4 routes.** The office prints a daily route + master load sheet with each route's products and quantities. A **different manager** is on duty when the drivers load, so tasks and the load-out go to the manager on duty, not to a fixed person.
    - "30 minutes behind": **both**: the late/unsent tap alarm (built) AND a load running behind (a washer done with no next load started while work waits). Threshold TBD.
  - **Load-out (owner 2026-11-06):** the office manager or the owner types each day's numbers into the app; it must be simple. Items that matter to the supervisor, shown on the pace/load-out board: **sheets, butcher coats, soil bags, special items (as needed)**. 4 routes.
  - Owner 2026-11-06 (round 2):
    - Load sheets are printed by **Fulcrum** (export unknown; the owner checks for Excel/CSV).
    - Trucks load at **03:30, 04:30, 05:00, 05:30** (4 routes).
    - **Manager on duty = the shift schedule.**
    - Washer idle with work waiting: alarm after **15 min**.
    - Sheets are entered in **packs of 10**; butcher coats by size **M/L/XL**.
  - **Routes (owner 2026-11-06):**
    - Route 21: 03:30 daily.
    - Route 11 (Mon/Thu) and Route 5 (Tue/Fri): 04:30.
    - Route 2: 05:00.
    - Route 4: 05:30.
    - Routes need a weekday schedule.
  - **Soil bags:** empty bags dropped off to customers, in packs of 5 (counted, not washed).
  - The owner dislikes the Setup → Machines layout; ask what to change.
  - **Route days:** Route 21 and Route 4 run Mon/Tue/Thu/Fri; Route 2 runs Mon–Fri; Route 11 Mon/Thu; Route 5 Tue/Fri. On Wednesday only Route 2 runs.
  - Open: pieces per load for sheets and coats (fill-in sheet).

## 2026-11-07 to 2026-11-09

Recorded from the owner's answers, as relayed to the docs keeper (not verbatim).

- Cotton tablecloths: formula 3. Stained AA items: formula 5.
- AA Linen: aprons white/black; napkins white/colored; tablecloths white/colored/cotton (12 AA groups). Mats are "Alfombras".
- Managers can cancel AA deliveries. Only the owner edits customer products.
- Tablets and TVs show customer names.
- Alert switches are self-only. A misread `off_queue_start` alert was deleted.
- Spanish: "Máquina de jabón" (soap machine) and "Lavadora N" are OK.
- Washer idle alarm (15 min) = "behind schedule".
- Fulcrum load sheets: dual option (type in or upload). Needs a sample export.
- Diamond Accu-Flow: owner says yes. Sample file still needed.
- GitHub branch protection on `main` is set (PR required, 0 approvals).
- Supabase minimum password 6: 6-digit sign-in for everyone, owners included. Owner accepted the risk with lockout + pepper.
- Viewer accounts explained; none needed.
- Rollout: week 1 owner + Denise on the shared iPad; week 2 Denise on her phone; then Yasmary; then other managers one at a time. TVs and washer tablets last.
- Owner's desktop is a regular monitor.
- Inventory counts on Wednesdays and Saturdays. LinenTrack integration later.
- Washroom rules: tablecloths estimated and queued by colour; washmen split sizes themselves (52s + 62s together; 72s + 90s + rounds together); colours always washed separately. Mats likewise by basket; size counted at finishing. The roller counts total cubby inventory nightly after rolling; mats leave by invoice (not the load-out list).
- Open: where the roller's nightly count is recorded (LinenTrack or paper), which means a LinenTrack read vs. a nightly cubby-count screen; whether Fulcrum can export invoices; finishing-goods entry screen (linens) not built; access templates + per-person layouts (owner approved, next); "what don't you like about the overall setup" still unanswered.
