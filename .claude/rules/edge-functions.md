---
paths:
  - "supabase/functions/**"
---

# Edge Function rules (Supabase, TypeScript/Deno)

Specs are in `research/PRD.md` §5.4: `invite-user`, `revoke-user`, `pair-device`, `revoke-device`, `import-washer-file`, `dispatch-alerts`, `accuflow-sync`.

- One folder per function: `supabase/functions/<kebab-name>/index.ts`. Put shared code in `supabase/functions/_shared/`.
- **Authorize first.**
  - Verify the caller's JWT.
  - Look up their membership/role with a user-scoped client.
  - Create a service-role client only after the check passes, and only for the step that needs it.
- `pair-device` is the only public function.
  - Rate-limit it to 10 attempts per IP per 10 min.
  - Compare codes in constant time.
  - Codes are single-use and expire after 15 min.
- Validate every request body with Zod. Return errors as `{ code, message }` using the PRD §5.1 codes, with correct HTTP status codes.
- **Imports (`import-washer-file`):**
  - Two-step flow: `preview`, then `commit`.
  - Store the raw file in Storage and dedupe by `file_sha256` and `(plant_id, source, external_id)`.
  - Unknown machines or formulas are flagged, never dropped.
  - **Don't write the Accu-Flow parser without a real sample export from Diamond Chemical.**
- Scheduled functions (`dispatch-alerts`) are invoked by pg_cron. Dedupe alerts through `alert_events` (one per subject per shift).
- Never log secrets, tokens or full request bodies.
- Read secrets from `Deno.env` only. Variable names are listed in `.claude/CLAUDE.md`.
