import { createClient } from '@supabase/supabase-js';
import { env } from './env';
import type { Database } from '../types/database';

// The only Supabase client in the app (see .claude/rules/frontend.md).
// Typed with the generated Database type (src/types/database.ts, regenerated after every migration).
// detectSessionInUrl is off: sign-in is username + password only (PRD A4, 2026-11-03), so no
// session ever arrives in a URL (no magic links, no OAuth redirects).
export const supabase = createClient<Database>(env.supabaseUrl, env.supabasePublishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});
