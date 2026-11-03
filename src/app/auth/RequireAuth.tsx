import type { ReactNode } from 'react';
import { Navigate } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useSession } from './useSession';
import { mustChangePassword, SessionContext } from './sessionContext';
import { ChangePasswordPage } from './ChangePasswordPage';

export function RequireAuth({ children }: { children: ReactNode }) {
  const session = useSession();
  const { t } = useTranslation();

  if (session === undefined) return <p role="status">{t('common.loading')}</p>;
  if (session === null) return <Navigate to="/sign-in" replace />;
  // Temporary password (new account or owner reset): nothing else is reachable until changed.
  if (mustChangePassword(session)) return <ChangePasswordPage />;
  return <SessionContext.Provider value={session}>{children}</SessionContext.Provider>;
}
