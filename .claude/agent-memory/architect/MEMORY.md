# Architect memory (rulings, 1 line each)

- 2026-10-30 Sprint Zero review (PR #2): PASS WITH NOTES; PRD v1.3 day-boundary escalated as ADR.
- Rows carrying shift_instance_id + area_id must FK (shift_instance_id, area_id) -> shift_instances(id, area_id) (needs unique (id, area_id)).
- i18n: src/lib/i18n.ts availableLocales = bundled translation files only; user-facing language pickers must come from `languages` + plant enabled_languages; profile.language overrides navigator.
- Surfaces (control/display/pair) must be route-level lazy in src/router.tsx (frontend.md code-split, <=250 KB initial).
- Schema `app` grants: no anon usage; revoke default EXECUTE on app functions from public in M1.
- Approved deps at Sprint Zero: React 19, React Router 8 (node >=22.22), Vite 8 (vite-plugin-pwa 2.x supports it), i18next 26, Vitest 5, supabase CLI devDep. Anything else = check tech-stack.md.
- Off-shift rows (null shift_instance_id) need a defined business_date or explicit "off-shift" bucket in day reports.
- 2026-11-01 M1 DB plan review: PASS WITH NOTES; D8 (§4.7 direct C vs A8 staff session) escalated as ADR for M2.
- start_staff_session returns typed result (no raise) for PIN_INVALID/STAFF_LOCKED so the failed-attempt counter commits; other errors raise.
- entry_staff.pin_hash nullable + column grants (no SELECT/INSERT/UPDATE on pin_hash, failed_pin_attempts, locked_until); staff_sessions gets org_id + consumed_at.
- Home shift = all active shifts with same (area_id, name); if home area != entry area, fall back to entry area's clock shift.
- finished_goods_entries: no direct UPDATE policy (void only via RPC); apply_count_mode validates on INSERT or when count columns change, never on void.
- Reports convert finished goods via to_loads(item, pieces, 'piece'), never 'pack' (current pack_size != pack_size_used).
- Org-level rows (memberships plant_id null, audit_log, app_events) need app.has_org_role(org, roles); has_role(null plant) is false.
- Display RLS must require a non-revoked device (my_device()) as well as display membership; own-area via (select (app.my_device()).area_id).
- days_of_week uses extract(dow) 0=Sun; generate_shift_instances on conflict refreshes future unreferenced instances.
