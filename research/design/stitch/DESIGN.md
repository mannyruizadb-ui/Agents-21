---
name: PlantBoard Industrial Telemetry
colors:
  surface: '#0b1326'
  surface-dim: '#0b1326'
  surface-bright: '#31394d'
  surface-container-lowest: '#060e20'
  surface-container-low: '#131b2e'
  surface-container: '#171f33'
  surface-container-high: '#222a3d'
  surface-container-highest: '#2d3449'
  on-surface: '#dae2fd'
  on-surface-variant: '#bacbb9'
  inverse-surface: '#dae2fd'
  inverse-on-surface: '#283044'
  outline: '#859585'
  outline-variant: '#3b4a3d'
  surface-tint: '#00e475'
  primary: '#75ff9e'
  on-primary: '#003918'
  primary-container: '#00e676'
  on-primary-container: '#00612e'
  inverse-primary: '#006d35'
  secondary: '#ffd799'
  on-secondary: '#432c00'
  secondary-container: '#feb300'
  on-secondary-container: '#6a4800'
  tertiary: '#dbe4ff'
  on-tertiary: '#002e6a'
  tertiary-container: '#b0c8ff'
  on-tertiary-container: '#0050ad'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#62ff96'
  primary-fixed-dim: '#00e475'
  on-primary-fixed: '#00210b'
  on-primary-fixed-variant: '#005226'
  secondary-fixed: '#ffdeac'
  secondary-fixed-dim: '#ffba38'
  on-secondary-fixed: '#281900'
  on-secondary-fixed-variant: '#604100'
  tertiary-fixed: '#d8e2ff'
  tertiary-fixed-dim: '#adc6ff'
  on-tertiary-fixed: '#001a42'
  on-tertiary-fixed-variant: '#004395'
  background: '#0b1326'
  on-background: '#dae2fd'
  surface-variant: '#2d3449'
typography:
  headline-xl:
    fontFamily: Barlow Condensed
    fontSize: 44px
    fontWeight: '700'
    lineHeight: 48px
    letterSpacing: 0.02em
  headline-xl-mobile:
    fontFamily: Barlow Condensed
    fontSize: 36px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: 0.02em
  headline-lg:
    fontFamily: Barlow Condensed
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 36px
    letterSpacing: 0.03em
  headline-lg-mobile:
    fontFamily: Barlow Condensed
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 32px
    letterSpacing: 0.03em
  headline-md:
    fontFamily: Barlow Condensed
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: 0.02em
  display-timer:
    fontFamily: JetBrains Mono
    fontSize: 40px
    fontWeight: '700'
    lineHeight: 44px
    letterSpacing: -0.02em
  display-timer-mobile:
    fontFamily: JetBrains Mono
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 36px
    letterSpacing: -0.02em
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '600'
    lineHeight: 26px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '500'
    lineHeight: 24px
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-telemetry:
    fontFamily: JetBrains Mono
    fontSize: 15px
    fontWeight: '600'
    lineHeight: 20px
    letterSpacing: 0.05em
  label-bilingual:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: '700'
    lineHeight: 16px
    letterSpacing: 0.06em
  label-micro:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '500'
    lineHeight: 14px
    letterSpacing: 0.08em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  gutter: 0.75rem
  margin: 1rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2.5rem
---

## Brand & Style

This design system is engineered for high-throughput, harsh-environment shop floors: humid, fast-paced commercial laundry facilities operated by multi-generational, bilingual teams. The visual identity fuses the mission-critical legibility of airport terminal split-flap departure boards with rugged industrial hardware interfaces.

### Core Tenets
- **High-Velocity Scannability:** Key information (machine state, cycle countdowns, wash classifications) must be decipherable from a 3-meter distance under fluctuating plant lighting.
- **Rugged Tactility:** Wet, gloved, or soapy hands demand exaggerated interaction envelopes, explicit physical boundaries, and immediate visual confirmation. Zero micro-interactions or frail gestures.
- **Dual-State Clarity (Never Color Alone):** Every critical status pairs high-intensity chromatic indicators with structural geometry, heavy status pills, and standardized icons to ensure WCAG AAA accessibility across shifts.
- **Bilingual Functional Parity:** Parallel English/Spanish labelling treated as first-class UI architecture, not an afterthought truncation risk.

### Design Movement
**Industrial Brutalism & Flight Board Utility:** Deep matte charcoal substrates, hairline grid seams, crisp high-voltage status accents, modular split-flap-inspired typography blocks, and zero non-functional decoration.

## Colors

The system uses a dark slate base to eliminate glare from fluorescent warehouse tubes and stainless equipment, punctuated by luminous safety signal colors. All critical signals maintain a minimum 7:1 contrast ratio against their ambient container surfaces.

### Surface Architecture
- **Base Substrate (`#020617` to `#0B0F19`):** Foundation canvas; total darkness absorbing environmental reflections.
- **Machine Module Surface (`#111827`):** Core component surface, distinct from background canvas.
- **Elevated Interactive Surface (`#1F2937`):** Touch panels, oversized buttons, and interactive trays.
- **Border / Mechanical Seam (`#374151`):** Structural partition color, ensuring strict physical container definitions.

### Signal Accents (Hardware States)
- **Signal Emerald (`#00E676` base / `#059669` muted):** Machine Active / Cycle Normal / Passed Inspection.
- **Safety Amber (`#FFB300` base / `#D97706` muted):** Warning / Cycle Ending (<5 min) / Queue Pending / Lint Trap Check.
- **Signal Emergency Red (`#EF4444` base / `#991B1B` container):** E-Stop Engaged / Out of Service / Chemical Feed Failure.
- **Industrial Steel Blue (`#3B82F6` base / `#1D4ED8` container):** Programmed / Scheduled / Water Fill Phase.

### Wash Classification Badges
Each textile line uses strict signature markers that pair high-contrast backgrounds with explicit typographic labels:
- **Black Floor Mats:** Solid Carbon `#0F172A` with `#94A3B8` border and white text.
- **Colored Mats:** Industrial Ochre `#D97706` with `#451A03` border.
- **White Linen:** Pure Stark `#F8FAFC` chip with `#0F172A` bold text and `#475569` outer rim.
- **Food & Beverage Napkins:** Deep Electric Violet `#8B5CF6`.
- **Kitchen Bar Towels:** High-Visibility Cyan `#06B6D4`.
- **Butcher Coats / Bloodborne Barrier:** Hazard Magenta `#EC4899`.

## Typography

The typographic hierarchy prioritizes rapid character disambiguation and tabular tracking. 

### Structural Hierarchy
- **Primary Data / Timers (`JetBrains Mono`):** Fixed-width tabular numeric data prevents layout shifts during countdown transitions. Used exclusively for machine IDs (`WASHER-04`, `DRY-02`), water temperatures, cycle timers (`18:42`), and chemical flow rates.
- **Flight-Board Headers (`Barlow Condensed`):** Condensed, punchy, uppercase headline treatment maximizing horizontal space on 390px-wide screens while providing monumental legibility.
- **Operational Copy (`Inter`):** Clean, high-legibility sans-serif with tall x-height designed for instant recognition of procedures and bilingual status terms.

### Bilingual Typographic Rule
All interface controls, alerts, and state indicators present English as the primary label and Spanish as the direct sub-anchor using the `label-bilingual` style in uppercase muted tones:
- Example: `CYCLE RUNNING` / `CICLO EN CURSO`
- Example: `LOAD CHEMICALS` / `CARGAR QUÍMICOS`
Spanish sub-labels must never be rendered below 12px or truncated with ellipses.

## Layout & Spacing

Designed phone-first targeting a 390x844px base viewport (iPhone / industrial ruggedised Android handhelds like Zebra and Honeywell devices). The layout relies on an inflexible mechanical grid where structural containers fill horizontal space without fragile nested margins.

### Touch Target Mandates
- **Standard Action Targets:** 56px minimum height (toggles, list navigation, batch selects).
- **Primary Floor Actions:** 96px minimum height (Emergency Stop, Complete Unload, Start Cycle, Acknowledge Alarm).
- **Inter-Element Spacing:** Minimum 8px gap between secondary touch targets; 16px gap between destructive and standard controls to eliminate accidental activation by operators wearing nitrile or heavy thermal gloves.

### Layout Philosophy
- **Split-Flap Matrix Grid:** Cards use edge-to-edge modular cells with 1px internal dividers simulating industrial instrument panels.
- **Sticky Flight Bar:** Key metrics (total machines active, active e-stops, urgent cycles) lock to a persistent high-contrast top rail.
- **Reflow Architecture:** At tablet/desktop (wall display mode), the 390px single-column feed tiles into a dense 3-to-4 column departure-board dashboard with synchronized real-time countdown tickers.

## Elevation & Depth

This system avoids decorative drop shadows, blurred ambient penumbras, and layered transparency, which fail in dusty shop environments under bright overhead lighting. Depth is rendered strictly through tonal grouping, mechanical recessed bezels, and bold industrial borders.

### Surface Tiers
- **Tier 0 (Floor Chassis):** `#0B0F19` — The base machine canvas.
- **Tier 1 (Instrument Tray):** `#111827` bordered by `#374151` — Card modules, machine bay housings.
- **Tier 2 (Control Actuators):** `#1F2937` with an active bottom-edge offset border — Buttons, toggles, interactive triggers.
- **Tier 3 (Active Emergency / Override Layer):** `#000000` sheet overlay with a 4px perimeter border in `#EF4444` or `#FFB300`.

### Physical Metaphor
Depth indicates actionability:
- **Inactive / Status Display:** Flat surfaces bordered by 1px solid `#374151`.
- **Actionable Controls:** 2px solid perimeter with a raised 3px bottom edge (`#4B5563`), compressing 2px downward on touch active state to simulate physical heavy-duty micro-switches.
- **Critical Status Flash:** Active alarm states cycle between full-bleed solid color and 3px internal high-visibility border pulses.

## Shapes

The design uses tight, precise corners (`roundedness: 1` — 4px / `0.25rem`) echoing stamped sheet-metal machinery panels, terminal keypads, and modular relay hardware. Completely rounded pills are forbidden except for live numerical badges. Sharp, reliable geometry reinforces precision, structural rigidity, and professional durability.

## Components

### 1. Actuator Buttons (Primary / Emergency)
- **Primary Floor Button (96px Target):**
  - Full-width block. Dark slate background (`#1F2937`) with a 3px border in Signal Emerald (`#00E676`) or Steel Blue (`#3B82F6`).
  - Contains icon (32px), primary text in `Barlow Condensed` bold, and bilingual subtitle in `Inter` bold.
  - Active tap depression state drops 3px down, giving tactile feedback.
- **Emergency Stop / Out-of-Service (E-Stop):**
  - 96px minimum height. High-visibility diagonal hazard border pattern (`#EF4444` / `#000000`) or solid crimson block `#EF4444` with white text. Requires a sustained 1.5s press-and-hold interaction with tabular countdown ring.

### 2. Machine Departure-Board Cards
- Modular rectangular chassis with a split layout:
  - **Left Header:** Machine Identifier (`WASHER 03`) set in `JetBrains Mono` 20px, flanked by physical icon (Washer drum, Dryer tumbler, Tunnel belt).
  - **Right Indicator:** Machine State Pill + Tabular Remaining Timer (`12:44 MIN`).
  - **Sub-strip:** Wash Group Color Chip with textual textile code (e.g., `WHITE LINEN / SÁBANAS BLANCAS`).

### 3. Textile Group Chips
- Compact rectangular badges (min 36px height) with full-coverage color coding:
  - Must display a tactile 4px left-swatch stripe of the group color, paired with a high-contrast dark interior container and high-contrast text.
  - Never display color alone: Always paired with an explicit icon (e.g., napkin fold icon, apron icon, towel roll icon) and bilingual code (`NAP / SERV`).

### 4. Machine Status Chips
- **Running:** Emerald background tint `#064E3B`, `#00E676` border and text, rotating mechanical gear icon.
- **Needs Attention:** Amber tint `#78350F`, `#FFB300` border and text, warning triangle icon.
- **Out of Service:** Red tint `#7F1D1D`, `#EF4444` border and text, wrench / lock-out icon.
- **Queue / Idle:** Slate tint `#1E293B`, `#94A3B8` border and text, pause icon.

### 5. Input Fields & Manual Counter Steppers
- Designed for finger taps rather than mobile virtual keyboards wherever possible.
- Quantitative inputs (e.g., water temp target, load weight in lbs) use large split-button counter modules:
  - Decrement `[-]` 56x56px button on left, tabular value centered in `JetBrains Mono` 28px, Increment `[+]` 56x56px button on right.
  - High-contrast border `#4B5563` with highlighted focus frame `#3B82F6` (2px).

### 6. List Items & Queue Arrays
- High-density list strips with 64px row height.
- Alternating subtle row backgrounds (`#0F172A` / `#141E33`) to prevent line-slipping when tracking items visually across the shop floor.
- Right-aligned drag handle or direct oversized action trigger (e.g., `LOAD NEXT / CARGAR`).