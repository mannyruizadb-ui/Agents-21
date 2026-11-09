import { useTranslation } from 'react-i18next';
import { useAppUpdate } from '../../lib/useAppUpdate';
import './updatebanner.css';

/** "New version available — Update" (owner 2026-11-09). One tap reloads the app. */
export function UpdateBanner() {
  const { t } = useTranslation();
  const available = useAppUpdate();
  if (!available) return null;
  return (
    <div className="update-banner" role="status">
      <span>{t('app.updateAvailable')}</span>
      <button type="button" onClick={() => window.location.reload()}>
        {t('app.updateNow')}
      </button>
    </div>
  );
}
