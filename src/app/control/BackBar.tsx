import { useLocation, useNavigate } from 'react-router';
import { useTranslation } from 'react-i18next';
import { backTarget } from './backTarget';
import './backbar.css';

/**
 * One back button on every control screen that is not a bottom-nav tab. It goes back in the app's
 * own history when there is some, else to the screen's parent (a screen opened from a notification
 * has no history). Visible text = accessible name, so "tap Back" works with voice control.
 */
export function BackBar() {
  const { t } = useTranslation();
  const { pathname } = useLocation();
  const navigate = useNavigate();
  const parent = backTarget(pathname);
  if (!parent) return null;
  const onBack = () => {
    // React Router keeps its own history index; 0 = this is the first screen of the visit.
    const idx = (window.history.state as { idx?: number } | null)?.idx ?? 0;
    if (idx > 0) void navigate(-1);
    else void navigate(parent, { replace: true });
  };
  return (
    <nav className="back-bar" aria-label={t('common.back')}>
      <button type="button" className="back-button" onClick={onBack}>
        <span aria-hidden="true">‹</span> {t('common.back')}
      </button>
    </nav>
  );
}
