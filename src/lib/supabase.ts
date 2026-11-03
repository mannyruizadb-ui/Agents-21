import { createClient } from '@supabase/supabase-js';
import { env } from './env';

// The only Supabase client in the app (see .claude/rules/frontend.md).
// Typed with the generated Database type once the first schema migration lands (M1).
// detectSessionInUrl is off: sign-in is username + password only (PRD A4, 2026-11-03), so no
// session ever arrives in a URL (no magic links, no OAuth redirects).
export const supabase = createClient(env.supabaseUrl, env.supabasePublishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});
