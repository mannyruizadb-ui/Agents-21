import { createContext, useContext } from 'react';
import type { Session } from '@supabase/supabase-js';

/** The signed-in session, provided by RequireAuth to everything behind it. */
export const SessionContext = createContext<Session | null>(null);

export function useRequiredSession(): Session {
  const session = useContext(SessionContext);
  if (!session) throw new Error('useRequiredSession must be used inside RequireAuth');
  return session;
}

/** Set by manage-users on create/reset; only manage-users change_own_password clears it. */
export function mustChangePassword(session: Session): boolean {
  return session.user.app_metadata?.must_change_password === true;
}
