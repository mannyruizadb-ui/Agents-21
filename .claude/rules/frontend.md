---
paths:
  - "src/**/*.{ts,tsx,css,json}"
  - "tests/e2e/**"
---

# Frontend rules (React + Vite PWA)

Specs live in `research/PRD.md` §3 (features), §5.5 (Realtime) and §6 (performance, accessibility, responsiveness).

## Structure
- **Three surfaces** in `src/app/`:
  - `control/`: owner and manager phone, including finished-goods and washer-load entry; also used on an optional shared tablet
  - `display/`: wall TV, read-only
  - `pair/`: display pairing
- Each surface is code-split. The initial route must stay **≤ 250 KB gzipped JS**.
- Feature code lives in `src/features/<epic>/`. Shared code lives in `src/lib/`.
- Import the Supabase client only from `src/lib/supabase.ts`. Never construct another client.

## Data
- **Server state belongs only to TanStack Query.** Query keys look like `['queue', areaId]`, `['soil', plantId]`, `['shift-report', shiftInstanceId]`.
- Realtime events patch or invalidate the cache. They never write to component state directly.
- Mutations are optimistic where the PRD says so (queue reorder, finished-goods entry), with rollback and a toast on error.
  - Handle `QUEUE_VERSION_CONFLICT` by refetching and showing "Queue changed by NAME — refreshed."
- Entry mutations (finished goods, washer loads, estimates) persist offline (IndexedDB persister). Generate `client_id` with `crypto.randomUUID()` **before** the first attempt.
- Use `useState` for UI state. Add Zustand only if state becomes genuinely shared. **No Redux.**

## Displays (`src/app/display/`)
- No interaction is required. Request a Screen Wake Lock.
- Do a full reload at the plant's `display_reload_local_time`.
- Refetch `get_display_feed` on connect, reconnect, `online`, `visibilitychange` and every 5 min.
- Show "updated Xs ago". After 30 s with no heartbeat, show a reconnect banner. After 5 min, show the full-screen OFFLINE state.
- Typography: NOW ≥ 96 px, NEXT ≥ 56 px, minimum 32 px. Use viewport-relative sizing, with no scrolling at 1920×1080.
- Contrast ≥ 7:1. RUSH, freshness and offline always pair color + icon + text.
- Respect `prefers-reduced-motion`.

## Entry & control UX
- **Finished-goods entry:**
  - item → quantity in that item's counting unit;
  - pack items show `packs` + `loose`, with the pack size and a live total ("7 packs + 34 = 734");
  - unit items show one count;
  - keypad targets ≥ 56 px, no typing in the core flow;
  - a 10-second Undo;
  - ≤ 5 taps per entry;
  - warn (don't block) when loose ≥ pack size.
- **Never compute `pieces` on the client** except as a preview. The DB value is authoritative.
- **Control:**
  - targets ≥ 48 px;
  - works at 360 px wide with no horizontal scroll;
  - drag-and-drop has up/down button alternatives.

## Languages (PRD H1)
- **Every string goes through `t()`.** Add keys to every enabled locale file together. Missing keys fall back to the plant default, then `en`. **Never render raw keys.**
- Locale files (`src/locales/<code>.json`) are lazy-loaded. The language list comes from the `languages` table and the plant's `enabled_languages`. **Never hard-code `['en','es']`.**
- Item names and messages come from `name` + `name_i18n` (or `body` + `body_i18n`). Use the shared `localize(value, i18nMap, lang)` helper.
- Format numbers, dates and times with `Intl` for the user's language.
- Set the `lang` attribute on mixed-language elements (displays).

## Accessibility & voice (PRD H6, H7, §6.3)
- WCAG 2.2 AA on the control app: labels, focus order, keyboard operation, target size, dragging alternatives.
- **Visible label = accessible name** (Voice Control / Voice Access say "tap Save"). Icon-only buttons get a visible text label or tooltip *and* `aria-label` with the same words.
- Use native `<input>`, with `inputmode="numeric"` for counts, so **OS keyboard dictation works in every field**. No custom canvas keypads without a real input behind them.
- Announce save, sync and error status with `aria-live`. Errors say how to fix the problem.
- Apply `profiles.a11y_prefs`: text scale, high contrast, reduced motion, confirm-before-save, Undo seconds (10–60).
- In-app voice (P1):
  - Feature-detect `SpeechRecognition` / `webkitSpeechRecognition` and hide the mic when it's unavailable.
  - Tap-to-talk only, never always-on.
  - Parse into fields, then **require a confirm tap**. Never save straight from speech.
  - The spoken-number and item parser is pure TS with EN/ES unit tests.

## Tests
- Vitest for logic: conversions, ordering, offline queue, the voice-entry parser, the translation fallback.
- Playwright for:
  - the display at 1920×1080 (screenshot + live-update check);
  - the entry flow on a 1024×600 tablet;
  - control at 390×844;
  - an axe scan on every route, plus one run with 200% text scale.
- Simulate offline in Playwright for the entry sync tests.
