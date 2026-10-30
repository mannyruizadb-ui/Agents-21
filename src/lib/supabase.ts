import { createClient } from '@supabase/supabase-js';
import { env } from './env';

// The only Supabase client in the app (see .claude/rules/frontend.md).
// Typed with the generated Database type once the first schema migration lands (M1).
export const supabase = createClient(env.supabaseUrl, env.supabasePublishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});
