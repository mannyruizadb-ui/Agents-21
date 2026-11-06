import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import '../../lib/forms.css';

// "Alerts" tab (owner). The recent-alerts list needs a read RPC for alert_events (RPC-only table, no
// client read today); until it exists this page says where alerts arrive and links to the live screens.
export function AlertsPage() {
  const { t } = useTranslation();
  return (
    <main className="form-page">
      <h1>{t('nav.alerts')}</h1>
      <p className="notice">{t('alerts.placeholder')}</p>
      <ul className="hint">
        <li>{t('alerts.kindMachine')}</li>
        <li>{t('alerts.kindRoute')}</li>
        <li>{t('alerts.kindTask')}</li>
      </ul>
      <div className="actions">
        <Link className="button-link secondary" to="/control/machines">
          {t('machines.linkLabel')}
        </Link>
        <Link className="button-link secondary" to="/control/more">
          {t('notifications.title')}
        </Link>
      </div>
    </main>
  );
}
