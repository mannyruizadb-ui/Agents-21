---
paths:
  - "src/**/*.{ts,tsx,css,json}"
  - "tests/e2e/**"
---

# Frontend rules (React + Vite PWA)

Specs live in `research/PRD.md` §3 (features), §5.5 (Realtime) and §6 (performance, accessibility, responsiveness).

## Structure
- **Four surfaces** in `src/app/`:
  - `control/`: owner and manager phone
  - `display/`: wall TV, read-only
  - `station/`: tablet
  - `pair/`: device pairing
- Each surface is code-split. The initial route must stay **≤ 250 KB gzipped JS**.
- Feature code lives in `src/features/<epic>/`. Shared code lives in `src/lib/`.
- Import the Supabase client only from `src/lib/supabase.ts`. Never construct another client.

## Data
- **Server state belongs only to TanStack Query.** Query keys look like `['queue', areaId]`, `['soil', plantId]`, `['shift-report', shiftInstanceId]`.
- Realtime events patch or invalidate the cache. They never write to component state directly.
- Mutations are optimistic where the PRD says so (queue reorder, logging), with rollback and a toast on error.
  - Handle `QUEUE_VERSION_CONFLICT` by refetching and showing "Queue changed by NAME — refreshed."
- Station mutations persist offline (IndexedDB persister). Generate `client_id` with `crypto.randomUUID()` **before** the first attempt.
- Use `useState` for UI state. Add Zustand only if state becomes genuinely shared. **No Redux.**

## Displays (`src/app/display/`)
- No interaction is required. Request a Screen Wake Lock.
- Do a full reload at the plant's `display_reload_local_time`.
- Refetch `get_display_feed` on connect, reconnect, `online`, `visibilitychange` and every 5 min.
- Show "updated Xs ago". After 30 s with no heartbeat, show a reconnect banner. After 5 min, show the full-screen OFFLINE state.
- Typography: NOW ≥ 96 px, NEXT ≥ 56 px, minimum 32 px. Use viewport-relative sizing, with no scrolling at 1920×1080.
- Contrast ≥ 7:1. RUSH, freshness and offline always pair color + icon + text.
- Respect `prefers-reduced-motion`.

## Station & control UX
- **Station:**
  - touch targets ≥ 64 px;
  - landscape tablet layout, 1024×600 minimum;
  - no typing in the core flow (keypad + presets);
  - a 10-second Undo after logging.
- **Control:**
  - targets ≥ 48 px;
  - works at 360 px wide with no horizontal scroll;
  - drag-and-drop has up/down button alternatives.

## i18n & accessibility
- **Every string goes through `t()`.** Add keys to `en.json` and `es.json` together; `ht.json` follows once Creole is confirmed.
- Set the `lang` attribute on mixed-language display elements.
- Meet WCAG 2.2 AA on control and station: labels, focus order, keyboard operation.

## Tests
- Vitest for logic: conversions, ordering, offline queue.
- Playwright for:
  - the display at 1920×1080 (screenshot + live-update check);
  - the station at 1024×600;
  - control at 390×844.
- Simulate offline in Playwright for the station sync tests.
