# PRD: ADB Compete, a Switch-and-Retain Platform for America's Dust Busters

| | |
|---|---|
| **Owner** | Manny Ruiz, CFO, America's Dust Busters (ADB) |
| **Status** | Draft v0.1, for review |
| **Date** | Oct 20, 2026 |
| **Based on** | `research/cintas/cintas-competitive-dossier.md` |

> **How to read this:** `[CONFIRM]` marks an ADB number or fact I don't have. Every target and baseline in this PRD needs real ADB data before it is final. Nothing below is invented as fact; the estimates are labeled as estimates.

---

## 1. Problem

ADB is a family-owned business in Miami-Dade, operating since 1988 and running Star Linen Service. It has its own laundry plant and delivery fleet. Its competitors are national providers: Cintas ($11.3B in revenue, about 23% operating margins), UniFirst (being acquired by Cintas), Alsco and Vestis.

ADB cannot win on scale or price. A national provider can match any discount and keep matching it. The dossier shows that the national providers are weakest in three areas:

1. **Contracts.** Lock-ins run 36–60 months, renew automatically, let the provider raise prices unless the customer objects within 10 days, and require the customer to pay all remaining charges to leave early.
2. **Billing trust.** Cintas paid up to $50M in 2025 to settle a public-agency overbilling class action. Customers complain about lost-garment charges and price increases.
3. **Inconsistent service.** Quality varies by branch: missed deliveries, missing inventory, and reps who change often.

On top of that, the **Cintas–UniFirst merger** cannot close before Dec 11, 2026. The integration that follows (merged routes, rep turnover, billing migration) should open a window of about 12–18 months in which customers are unusually willing to switch.

**What's missing today:** ADB says it differs on local service and transparent per-unit pricing, but it has no system that does three things:

- **Find** prospects at the moment they can switch without a penalty (their renewal-notice window).
- **Prove** ADB's service quality with data rather than claims.
- **Lock in** accounts with terms customers prefer, so ADB doesn't become a "national provider" in miniature.

## 2. Goal and non-goals

**Goal:** turn ADB's local advantages into a repeatable, measurable system for winning accounts from the national providers and keeping them.

| Goal | Metric (baseline → 12-mo target) |
|---|---|
| Win more accounts from the national providers | New accounts won per month from Cintas, UniFirst or Alsco: `[CONFIRM]` → +X% |
| Close faster | Days from proposal to signature: `[CONFIRM]` → −Y% |
| Higher win rate | Proposals won ÷ proposals sent: `[CONFIRM]` → target `[CONFIRM]` |
| Retain without lock-ins | 12-month logo retention: `[CONFIRM]` → ≥ national-provider norm |
| Make service visible to customers | % of deliveries with digital proof of service: 0% → 90% |
| Protect margin | Gross margin per account stays ≥ `[CONFIRM]`% (no winning by giving it away) |

**Non-goals for v1:**
- **Uniforms and garment rental.** ADB currently sells linen, mats and floor care. Adding uniforms is a strategic decision for leadership, not a software feature.
- **First aid, fire protection, or a national footprint.**
- **Hotels.** They are not a current ADB focus.
- **A price war.** The platform must enforce a margin floor (see FR-8).

## 3. Users

| User | Need |
|---|---|
| **Manny (CFO/owner)** | Pipeline visibility, pricing accuracy, margin control, merger-window tracking |
| **Sales / account rep** `[CONFIRM who]` | Know who to call, when to call them, and what to say; build proposals fast |
| **Route drivers** | Fast proof of delivery, counts and issue logging on a phone |
| **Plant / ops lead** | Inventory and loss tracking, capacity before taking on new accounts |
| **Customer** (restaurant GM, condo manager or LCAM, healthcare facility manager) | See exactly what was delivered, what was charged and why; reach a real person fast |

## 4. Solution overview

ADB Compete has four modules. An AI agent layer (§7) sits on top of them.

| # | Module | What it does | Dossier play it executes |
|---|---|---|---|
| M1 | **Switch Radar** | Prospect CRM organized by the competitor each prospect uses and that contract's renewal-notice date | Free contract audit + timing switches to the notice window |
| M2 | **Contract & Invoice Audit** | Upload a prospect's competitor contract or invoice → pull out the terms, fees and notice deadline, then generate a savings and terms comparison | "No lock-in" offer; public-sector campaign |
| M3 | **Proposal Engine** | Priced proposals: per-unit rental, replacement %, savings against the current vendor, margin check (extends the existing `adb-service-proposal` skill) | Transparent pricing; margin protection |
| M4 | **Service Proof & Customer Portal** | Driver app (proof of delivery with photo, counts, issues), customer portal (delivery history, invoices, service credits) | Service-level guarantees; turns Cintas's inconsistency into ADB's proof |

## 5. Functional requirements

### M1: Switch Radar
- **FR-1:** Track each prospect with: business type, neighborhood, current vendor (Cintas, UniFirst, Alsco, Vestis, other, or none), contract start, term length, auto-renew window, notice method (certified mail or written), and the date the notice is due.
- **FR-2:** Calculate the **switch window** for each prospect and alert the rep 90, 60 and 30 days before the notice deadline.
- **FR-3:** Tag prospects that are **UniFirst customers**. Report on them separately so ADB can measure the merger-window campaign.
- **FR-4:** Track businesses with no current provider (they handle their own linen) as their own segment. Cintas says more than two-thirds of its new business comes from this group.
- **FR-5:** Import prospects from a CSV or spreadsheet. v1 needs no external data provider.

### M2: Contract & Invoice Audit
- **FR-6:** Accept a PDF or photo of a competitor's contract or invoice. Extract the term, auto-renew clause, price-increase clause, termination fee, lost or damaged charges and the notice deadline into a structured record. A human must review the extraction before it is used.
- **FR-7:** Generate a one-page **"Your Contract, Explained"** comparison for the customer. It contrasts the competitor's terms with ADB's terms on facts only, **never naming or disparaging the competitor** in materials meant for the public. This follows the existing ADB brand rule.

### M3: Proposal Engine
- **FR-8:** Calculate weekly, monthly and annual totals using ADB's rules: rental = qty × unit price; replacement = round(qty × replacement %) × rate; monthly = weekly × 52 ÷ 12. **Block sending** if the margin falls below the floor Manny sets.
- **FR-9:** When the customer's current spend is known, show the savings in dollars and as a percentage. When it isn't known, leave the savings section out; never estimate it.
- **FR-10:** Include standard ADB **"Straight Terms."** The actual terms are a decision for Manny and counsel. Proposed defaults:
  - 12-month or month-to-month options
  - No auto-renewal, or auto-renewal with a 30-day reminder
  - A written cap on yearly price increases
  - A published lost and damaged rate schedule
  - No termination fee when the business changes ownership
- **FR-11:** Produce a PDF and support e-signature.

### M4: Service Proof & Customer Portal
- **FR-12:** Driver mobile app. Works offline (the network is unreliable on routes) and confirms each stop with a timestamp, GPS, photo, delivered and picked-up counts by item, and issue flags.
- **FR-13:** Customer portal. Shows delivery history with photos, current item counts, invoices showing the line-item calculation, and a button to report a service issue.
- **FR-14:** Service-level tracking: on-time delivery %, count accuracy, and how fast issues are resolved. Service credits apply automatically according to the published SLA.
- **FR-15:** Inventory loss tracking for each account. This feeds the replacement charges, so lost-item charges come from data instead of being disputed.
- **FR-16 (Phase 3, optional):** RFID or barcode tagging of linen. This requires capital spending, so it needs a separate business case `[CONFIRM ROI]`.

### Cross-cutting
- **FR-17:** Bilingual in English and Spanish for the driver app and customer communications.
- **FR-18:** Role-based access: owner, sales, driver, ops, customer.
- **FR-19:** Export everything to CSV or Excel, because ADB already runs on spreadsheets.

## 6. Non-functional requirements
- **Cost:** built for a small business. Use off-the-shelf or low-code tools where they work. `[CONFIRM budget]`
- **Reliability:** the driver app must keep working offline, and proofs sync later.
- **Security:** customer contracts and pricing are confidential. Store them encrypted and log who accesses them.
- **Accuracy:** zero tolerance for math errors in proposals and invoices. Automated tests must cover the pricing rules.
- **Usability:** a driver must be able to complete a stop in under 60 seconds.

## 7. AI agent layer

These agents support the humans; they do not replace them. A person approves every customer-facing output.

| Agent | Job | Human check |
|---|---|---|
| Contract Extractor | Read competitor contracts and invoices and fill in the M2 fields | A rep confirms each field before use |
| Proposal Builder | Draft M3 proposals (from the existing skill) | Manny approves the pricing |
| Switch-Window Prospector | Each week, rank which prospects to call and draft outreach | A rep sends it |
| Service Recovery | Flag accounts with service failures and draft the fix and credit | Ops approves |
| Local SEO Writer | Content aimed at people searching to switch providers, e.g. "switch linen provider Miami" (from the existing `adb-seo-blog-writer`) | Manny publishes |

## 8. Phasing

| Phase | Timing | Scope | Why this order |
|---|---|---|---|
| **1. Win** | Now – Jan 2027 | M1 Switch Radar, M3 Proposal Engine, M2 audit done manually with an agent's help, Straight Terms | Must be live **before** the merger closes (no earlier than Dec 11, 2026) |
| **2. Prove** | Q1–Q2 2027 | M4 driver app + customer portal, SLA tracking | Retention and referrals once won accounts come on board |
| **3. Scale** | H2 2027 | Automated M2 extraction, RFID pilot, public-sector campaign, reporting | Only once Phase 1–2 metrics justify it |

## 9. Risks and open questions

| Risk | Mitigation |
|---|---|
| **The merger window closes or never opens.** The FTC could block the deal, or Cintas could integrate smoothly; Cintas's 2017 G&K acquisition cleared with no required divestitures. | M1 and M3 are worth building regardless of the merger. Don't plan revenue around the merger. |
| **Cintas fights back on price** (it is documented offering better terms when customers push back). | Compete on terms and proof, not price. The margin floor (FR-8) stops ADB from "winning" unprofitable accounts. |
| **Tortious interference exposure** (Cintas has sued over contracts). | Target only lawful exits: the notice window, expiry, or the incumbent's documented breach. Counsel reviews any offer to cover a customer's termination fee. |
| **Plant or route capacity** can't absorb a burst of wins. | Ops checks capacity at proposal time. `[CONFIRM plant utilization]` |
| **Adoption.** Drivers or staff don't use the app. | Bilingual, under-60-second stops, with a pilot on one route first. |
| **Bundle gap.** Cintas can sell uniforms, first aid and fire services; ADB cannot. | Consider partnerships (local first-aid or fire vendors). This is a leadership decision. |

**Open questions for Manny:**
1. Current customer count, weekly route stops, number of trucks, and plant utilization?
2. Who sells today? Do you have a CRM, or is it spreadsheets?
3. What contract terms will ADB actually commit to (FR-10)?
4. Budget and timeline: build, buy (e.g., existing route and laundry software), or a hybrid?
5. Do you want public-sector customers (cities, schools)? They mean procurement paperwork and insurance requirements.

## 10. Success criteria for v1 (Phase 1 exit)
- Every active prospect in M1 has a known vendor and notice date, or is marked "unknown."
- 100% of proposals go out through M3, with the math verified and the margin floor enforced.
- Baseline win rate and sales-cycle length measured, so Phase 2 targets can be set from real data.
