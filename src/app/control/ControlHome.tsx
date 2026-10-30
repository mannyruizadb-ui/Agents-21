import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';

export function ControlHome() {
  const { t } = useTranslation();
  return (
    <main>
      <h1>{t('app.name')}</h1>
      <p>{t('control.placeholder')}</p>
      <button type="button" onClick={() => supabase.auth.signOut()}>
        {t('auth.signOut')}
      </button>
    </main>
  );
}
