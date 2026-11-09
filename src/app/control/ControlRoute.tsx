import { Outlet } from 'react-router';
import { useTranslation } from 'react-i18next';
import { RequireAuth } from '../auth/RequireAuth';
import { AppNav } from './AppNav';
import { BackBar } from './BackBar';
import { UpdateBanner } from './UpdateBanner';
import './appnav.css';

/**
 * The control surface, behind sign-in. One nav (AppNav) laid out by screen WIDTH (owner 2026-11-09):
 * a bottom bar on phones and tablets in portrait, a left side menu from 1024 px. The nav comes first
 * in the DOM (so focus order matches the side menu's place), with a skip link to the content.
 */
export function ControlRoute() {
  const { t } = useTranslation();
  return (
    <RequireAuth>
      <a className="skip-link" href="#app-content">
        {t('nav.skipToContent')}
      </a>
      <AppNav />
      <div id="app-content" className="app-main" tabIndex={-1}>
        <UpdateBanner />
        <BackBar />
        <Outlet />
      </div>
    </RequireAuth>
  );
}
