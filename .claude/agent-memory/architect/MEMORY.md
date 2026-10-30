# Architect memory (rulings, 1 line each)

- 2026-10-30 Sprint Zero review (PR #2): PASS WITH NOTES; PRD v1.3 day-boundary escalated as ADR.
- Rows carrying shift_instance_id + area_id must FK (shift_instance_id, area_id) -> shift_instances(id, area_id) (needs unique (id, area_id)).
- i18n: src/lib/i18n.ts availableLocales = bundled translation files only; user-facing language pickers must come from `languages` + plant enabled_languages; profile.language overrides navigator.
- Surfaces (control/display/pair) must be route-level lazy in src/router.tsx (frontend.md code-split, <=250 KB initial).
- Schema `app` grants: no anon usage; revoke default EXECUTE on app functions from public in M1.
- Approved deps at Sprint Zero: React 19, React Router 8 (node >=22.22), Vite 8 (vite-plugin-pwa 2.x supports it), i18next 26, Vitest 5, supabase CLI devDep. Anything else = check tech-stack.md.
- Off-shift rows (null shift_instance_id) need a defined business_date or explicit "off-shift" bucket in day reports.
