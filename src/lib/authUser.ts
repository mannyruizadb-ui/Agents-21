import { supabase } from './supabase';

/**
 * True only while `userId` is the signed-in account (security H1): every background sender checks
 * this right before sending, so nothing is sent after sign-out or under another account.
 */
export async function isSignedInAs(userId: string): Promise<boolean> {
  try {
    const { data } = await supabase.auth.getSession();
    return !!userId && data.session?.user.id === userId;
  } catch {
    return false;
  }
}
