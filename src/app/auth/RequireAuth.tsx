import type { ReactNode } from 'react';
import { Navigate } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useSession } from './useSession';

export function RequireAuth({ children }: { children: ReactNode }) {
  const session = useSession();
  const { t } = useTranslation();

  if (session === undefined) return <p role="status">{t('common.loading')}</p>;
  if (session === null) return <Navigate to="/sign-in" replace />;
  return children;
}
