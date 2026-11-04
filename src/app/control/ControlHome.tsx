import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { useRequiredSession } from '../auth/sessionContext';
import { useOwnerPlants } from '../../features/admin/useOwnerPlants';
import '../../lib/forms.css';

export function ControlHome() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);

  return (
    <main className="form-page">
      <h1>{t('app.name')}</h1>
      <p>{t('control.placeholder')}</p>
      <div className="actions">
        <Link className="button-link" to="/control/washers">
          {t('control.washerBoard')}
        </Link>
        <Link className="button-link" to="/control/queue">
          {t('control.queue')}
        </Link>
        {(ownerPlants.data?.length ?? 0) > 0 && (
          <Link className="button-link" to="/control/people">
            {t('people.title')}
          </Link>
        )}
        <button type="button" className="secondary" onClick={() => supabase.auth.signOut()}>
          {t('auth.signOut')}
        </button>
      </div>
    </main>
  );
}
