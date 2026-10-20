# Viability Analysis: ADB Plant Operations App

*Prepared 2026-10-20 for America's Dust Busters / Star Linen Service (Miami). Status tags: **[C]** confirmed from a source, **[I]** my inference or judgment, **[?]** unknown — needs your input.*

---

## 0. Verdict up front

**Conditional GO — as an internal tool for ADB. NO-GO (for now) as a product to sell to other laundries.**

There is no fatal technical flaw. Every piece is buildable with common, cheap technology:
- live queue screens
- phone control
- estimate updates
- shift output logging

The real risks are not code. They are:
1. **The washer integration is an unknown.** You haven't named the washer brand or app, and some vendors expose data while others don't.
2. **Adoption on the floor.** If managers don't update estimates and operators don't log output, the screens show stale fiction and people go back to calling you.
3. **Units.** Managers think in baskets, washers count loads, and finishing counts pieces. Without conversion factors, nothing lines up.
4. **Build vs. buy.** Laundry-specific products already exist and are used by your direct competitors (Alsco uses Spindle).

### Two corrections to the brief

- **The "reference materials" aren't technical references.** Cintas, Alsco, Vestis and Cy's are competitors, not API docs. The placeholders for API docs and technical specs were left empty. The one technical document that matters is your washer system's documentation, and it isn't here.
- **The problem may be partly process, not software.** "Always on the phone telling them what to do" means priorities live in your head. A screen fixes that only if someone keeps the queue current. Test that behavior cheaply before writing code (§4).

---

## 1. Technical viability

### Can it be built? Yes. [I]

| Component | What it is | Difficulty |
|---|---|---|
| **Queue / priority board** | Ordered list of work per area (washroom, finishing), editable from your phone; screens update live | Low |
| **Estimate input** | Managers enter "dirty out there" (e.g., 10 baskets of mats) and revise anytime | Low |
| **Wall displays** | Cheap TVs + Fire TV/Android stick or mini-PC running a browser in kiosk mode | Low (hardware/environment is the real issue) |
| **Job output sheet** | Per-shift quantities by item and station, start/stop times | Low–Medium |
| **Productivity reporting** | Pieces/pounds per operator hour, per shift and per station | Medium (needs clean data + unit conversions) |
| **Washer data integration** | Pull cycle counts/programs per night from the washer app | **Unknown: from trivial to impossible depending on vendor** |

### Suggested stack (low cost, already connected in this workspace) [I]

- **Backend:** Supabase.
  - Postgres stores the queue and logs.
  - Realtime pushes updates to the screens.
  - Auth handles manager and owner logins.
- **Frontend:** one web app with three views, hosted on Netlify or similar. No app store is needed.
  - Phone control panel: a PWA you can install on your home screen.
  - Display view: big text, auto-refreshing, no login on the TV.
  - Tablet entry view at each station for logging output.
- **Displays:** any TV plus a ~$30–60 streaming stick, or a $150 mini-PC for reliability.

### Primary technical risks

1. **Washer integration (highest).**
   - **Electrolux OnE Connected** logs every wash, dry and ironing cycle, offers downloadable per-cycle reports, and lists a "Cloud to Cloud API" in its quick guide. [C] ([Electrolux guide](https://www.electroluxprofessional.com/wp-content/uploads/2025/11/EPR_OnEConnected-Laundry_Quick-Guide_OPL_INTERNAL_20251120_EN.pdf))
     - Access terms and pricing are not public. [?]
   - **Milnor Mildata** reports operating data per load over a plant network. It is a networked plant system, not a documented public cloud API. [C] ([Milnor](https://www.milnor.com/cbw-batch-washers-pulseflow-technology/mildata-computer-systems/))
   - **Girbau, Continental and others:** no public API documentation found. [?]
   - **Fallback options, in order of preference:**
     1. Official API.
     2. Scheduled CSV or report export, which you upload or which is emailed and auto-parsed.
     3. Manual nightly entry of cycle counts.
     4. Current-sensor or IoT clamps on each machine to count cycles independently (~$50–150 per machine). This adds hardware work.
     - Scraping the vendor's app is possible but fragile and may violate its terms. **Don't build on that.**
2. **Plant environment.**
   - Washrooms are hot, humid and full of lint, which kills consumer TVs and Wi-Fi coverage.
   - You'll likely need enclosed or industrial-rated displays (or mount screens outside the wet zone) and a Wi-Fi survey or a wired access point.
3. **Data quality and the human loop.**
   - Estimates are "10 but really 6." The app can make updating easy, but it can't make people do it.
   - Design so that **the screen shows how old each estimate is** ("updated 3h ago").
4. **Language and usability.**
   - The crew likely works in Spanish and/or Haitian Creole (Little Haiti / MiMo area). [I]
   - Screens must be icon- and number-heavy, readable from 10+ feet, and bilingual or trilingual.
   - Operators logging output need big buttons, not forms.
5. **Labor tracking (legal sensitivity).**
   - Per-operator timing is valuable, but ADB has a 2013 DOL wage-and-hour finding on record.
   - **Do not make this app a timekeeping or pay system of record.** Keep payroll hours in your existing system.
   - Treat production timing as operational data, and have counsel or HR review any incentive or pay-for-performance use.

### Rate limits, pricing, API restrictions

| Item | Risk | Notes |
|---|---|---|
| Supabase / hosting | **Low** | Small plant, a handful of screens and users. The free tier covers prototyping; a paid tier is about $25/mo. [I — verify current pricing] |
| Washer vendor API | **Medium–High** | May require a subscription, dealer involvement, or may not exist for your model. This is the only external dependency that could block a feature. |
| Display hardware | Low cost, medium durability risk | Budget roughly $300–800 per screen location including mount, stick and protection. [I] |

---

## 2. Competitive landscape

### Existing solutions

| Solution | What it does | Fit for ADB | Source |
|---|---|---|---|
| **Spindle** | Laundry-specific production and labor tracking. Monitors over finishing equipment show operator efficiency; cloud dashboards and mobile app; since 2007, "hundreds of companies." Used at Alsco Raleigh and Alsco Atlanta (worst-to-improved PPOH story; saved 30+ hrs/week of manual data collection) | **Closest match** to the output and productivity half. Unknown whether it handles your "dirty out there" estimate queue | [TRSA – Alsco Raleigh](https://trsa.org:443/news/march-ts-preview-finishing-strong-at-alsco-raleigh/), [Network CSC](https://networkcsc.com/2025/07/supplierspotlight-spindle/), [laundryandcleaningnews](https://laundryandcleaningnews.com/?p=15915) |
| **LinenTech / Dash Linen** | Cloud laundry management: soil intake (weighing, scales), production, dispatch, real-time PPOH, alerts | Covers intake + production; may be heavier than you need | [LinenTech](https://www.linentech.net/), [PPOH page](https://www.linentech.net/laundry-employee-management) |
| **Jensen Futurail / target monitoring** | Plant-level production with daily targets per linen category and manual prioritization | Built for large plants with Jensen rail systems; likely overkill | [Jensen](https://jensen-group.com/experts-corner/detail/accelerated-production-planning-with-target-monitoring) |
| **Fabrico** | MES/OEE + maintenance for laundries (e.g., detects slow ironer) | Maintenance-first; partial fit | [Fabrico](https://www.fabrico.io/blog/best-maintenance-software-industrial-commercial-laundries/) |
| **Generic andon / shop-floor boards** (Peakboard, Mitsubishi iQ Monozukuri Andon, Digital Teamboard) | Production displays; Peakboard licenses per display | Display layer only; you'd still configure everything | [Peakboard](https://www.peakboard.com/en-us/solutions/andon-board), [Mitsubishi](https://www.automationworld.com/products/data/product/13318962/mitsubishi-electric-automation-andon-manufacturing-visualization-for-small-and-medium-sized-factories) |
| **Google Sheets / Airtable + a TV** | DIY board | Fastest test; weak on live updates and logging UX | — |

Most of the above comes from vendor marketing or trade-press pieces. Pricing for Spindle, LinenTech and Jensen is not public. [?]

### What would differentiate a custom build?

- **The estimate-driven queue.** "What's dirty out there, revised live, drives what's next" is your specific workflow. Off-the-shelf tools focus on measuring output, less on remote dispatching of the queue from the owner's phone. [I]
- **Fit to a small mixed plant.** Mats and linens/apparel share one washroom, which is different from the hospitality-linen giants these tools target.
- **Cost and control.** No per-seat or per-display licenses, and you own the data.
- **The counter-argument.** Spindle has 15+ years of laundry-specific edge cases. If its demo covers ~80% of what you described, buying is cheaper than building and maintaining.

### Evidence of market demand

- **Inside ADB:** clear. The owner is the human dispatcher by phone, which is a real cost and a bottleneck.
- **Industry:** yes. PPOH is described as the core laundry efficiency metric, and large operators (Alsco) pay for automated tracking. [C] ([American Laundry News](https://americanlaundrynews.com/node/98051), [TRSA](https://www.trsa.org/magazine-article/finishing-moves-driving-efficiency-while-satisfying-customers/))
- **As a commercial product:** **weak case.**
  - Incumbents exist (Spindle, LinenTech, Jensen).
  - The industry is consolidating to a few hundred operators, and the big ones (Cintas, Alsco, Vestis) build or buy enterprise systems.
  - Revisit only after the internal tool works at ADB for 6+ months and you have hard before/after numbers.

---

## 3. Complexity estimate

**MVP: weeks. Full vision with washer integration and productivity analytics: months.** [I]

| Phase | Scope | Estimate (1 dev, or you + Claude) |
|---|---|---|
| **0. No-code pilot** | TV + shared sheet as queue; paper/tablet output sheet | 2–5 days |
| **1. MVP** | Queue board per area, phone control, estimate entry with "last updated", output logging by item/shift, basic daily report, bilingual UI | **3–6 weeks** |
| **2. Productivity** | Start/stop timing per station, pieces/lbs per hour, shift comparisons, unit conversion tables | +3–4 weeks |
| **3. Washer integration** | Depends entirely on vendor: CSV import (days), official API (1–3 weeks + access approval), IoT sensors (3–6 weeks incl. hardware) | **Unknown until §4 step 1** |
| **4. Hardening** | Offline tolerance, display reliability, permissions, backups | +2 weeks |

### Hardest challenges (ranked)

1. **Washer data access.** This is an external dependency outside your control.
2. **A common unit model.**
   - Baskets → lbs → loads → pieces per item type (mats vs. napkins vs. chef coats).
   - You need agreed factors, e.g., "1 basket of 3×5 mats ≈ X lbs ≈ Y per washer load."
   - **This is a business decision, not code.** Without it, washroom data, finishing output and manager estimates can't be reconciled.
3. **Keeping estimates honest.** Make the update a 2-tap action and show staleness.
4. **Floor UX.** Wet hands, gloves, noise, multiple languages, and operators who won't log anything that takes more than 5 seconds.
5. **Reliable displays** in a hot, humid, linty room.

---

## 4. Go/No-Go and what to validate first

### Recommendation

**GO on an internal MVP, gated by three cheap validations (one to two weeks total) before any real build.**

**Validate first, in this order:**

1. **Identify the washer system.** (Blocking — one phone call.)
   - Find the brand, model and app name.
   - Ask the vendor or dealer:
     - Is there an API or a scheduled export (CSV/email)?
     - What does it cost?
     - What fields are included (machine, program/formula, start/end time, weight)?
   - **If there's no export at all, plan on manual nightly entry or sensors.** That does not kill the project, but it removes the "automatic" part.
2. **Run a one-week no-code pilot.**
   - Put one TV in finishing and one in the washroom, showing a live shared sheet that you edit from your phone.
   - Track how many "what's next" calls you make per shift, before vs. during the pilot.
   - Track whether managers actually update estimates.
   - **If the calls don't drop or nobody updates the sheet, software won't fix it.** Fix the process or ownership first.
3. **Get a demo and quote from Spindle (and LinenTech).**
   - If one covers the queue + output + PPOH for a plant your size at a reasonable monthly cost, **buy it** and only build what's missing.
   - If neither handles the estimate-driven dispatch queue, that confirms your build.

Also decide in week one:
- the unit conversion table
- the list of item categories
- who is responsible for updating estimates, and how often

### What would turn this into a NO-GO

- The pilot shows the crew still waits for calls regardless of the screen. That is a management or process issue, not a tooling one.
- Managers won't commit to updating estimates.
- An existing product covers ~80% of the need at an acceptable price. Buy instead.
- The goal is primarily to sell software to other laundries. That's a different, much harder business against entrenched incumbents.

---

## 5. Open questions for you

1. Washer brand, model and app name? How many washers and dryers? Which ironers and folders?
2. How many shifts, and how many people per area? What languages?
3. What do managers currently send you daily? (Format, timing, examples would help.)
4. What output do you track today, and in what unit (pieces, lbs, carts)?
5. Is per-operator tracking a goal, or is per-station/per-shift enough? (Per-station is simpler and less sensitive.)
6. Who would maintain this after it's built?

---

## 6. Update (2026-10-20): washer system identified

**ADB's setup:**
- **Washers:** Milnor
- **Reporting:** "Accu-Flow CloudView"

### What Accu-Flow actually is [C]

- **Accu-Flow is a chemical-dispensing system made by Diamond Chemical Company** (East Rutherford, NJ). It is not a Milnor product.
- Diamond's site lists several versions:
  - Accu-Flow, Accu-Flow Lite and Accu-Flow II for conventional washers
  - Accu-Flow Tunnel for tunnel washers
- Diamond says the systems offer "accurate and reliable reporting of all aspects of your laundry process."
  ([DiamondChem – Commercial Laundry](https://www.diamondchem.com/solution/commercial-laundry/))
- When Accu-Flow launched in 2015, it came with "Diamond Web-View Reporting Software… complete web-based reporting of all washroom operations… review all past and current production information anytime."
  ([Laundry Ledger, 2015](https://laundryledger.com/diamond-chemical-alis-accu-flow-dispensing-system/))
- "CloudView" appears to be the current name of that reporting portal. [I]
- **I found no public API, CSV export or developer documentation for it.** [NF]

### What this changes

1. **The data gatekeeper is your chemical supplier, not your washer maker.**
   - Access to the data depends on your contract with Diamond.
   - Dispensing and reporting systems like this are commonly bundled with the chemical supply contract. [I]
   - **If you ever switch chemical vendors, this data feed likely goes with them.** Treat that as a lock-in risk, and keep your own copy of the data in your app's database.
2. **The data is probably a good fit.** Dispensers usually log per-load events: machine, formula number, time, and often load weight and chemical usage ([Hydro Systems whitepaper](https://www.hydrosystemsco.com/solutions-center/whitepapers/the-perfect-cycle.html)). [I]
   - **Wash formulas usually map to item types:** a mat formula, a white-linen formula, a kitchen-towel formula.
   - So "washes of each thing per night" may come almost for free if each item type has its own formula.
   - **Confirm that mapping with your washroom lead.**
3. **Real-time isn't required.** Output reporting works fine on a **nightly or per-shift import**. Live washer status on the screens would be a nice phase-3 extra, not an MVP need.
4. **There may be a second source.** Milnor washer controllers may log formula and cycle data on their own (Milnor also sells the networked **Mildata** system: [Milnor](https://www.milnor.com/cbw-batch-washers-pulseflow-technology/mildata-computer-systems/)).
   - Ask your Milnor dealer what your specific controller model can export.
   - Treat this as a backup if Diamond can't give you data. [?]

### Questions for your Diamond Chemical rep

1. Can CloudView **export reports to CSV or Excel**? Can it **email a scheduled daily report** automatically?
2. Is there an **API** or data feed for third-party software? Is there a cost, or does it need approval?
3. **What fields are logged per load?** Machine ID, formula number and name, start and end time, load weight, chemical usage, alarms.
4. How far back does the history go? Can you get a bulk export of the past 90 days?
5. **Who owns the data under your contract,** and what happens to it if the contract ends?
6. Can formulas be renamed to match ADB's item types? For example, "Formula 3 = 3×5 mats."

### Integration plan, depending on the answer

| Diamond's answer | How we integrate | Effort |
|---|---|---|
| API available | Scheduled Supabase Edge Function pulls new loads every 15–60 min | 1–3 weeks once access is granted |
| Scheduled emailed CSV/Excel | Dedicated inbound address → Edge Function parses the attachment | ~1 week |
| Manual CSV export only | Upload button in the app; manager uploads it each morning (~1 min) | 2–4 days |
| No export (screen only) | Manual nightly entry of load counts per formula, or current sensors on each washer | 2–3 days (manual) / 3–6 weeks (sensors) |

**The verdict doesn't change. It's still a conditional GO.**
- The one blocking unknown is now a **single phone call to Diamond Chemical.**
- **Do not scrape the CloudView portal.** It would break whenever they change the site and may violate your agreement with Diamond.
