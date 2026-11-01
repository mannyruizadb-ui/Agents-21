import { useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';

type Status = 'idle' | 'sending' | 'sent' | 'error';

export function SignInPage() {
  const { t } = useTranslation();
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState<Status>('idle');

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    setStatus('sending');
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${window.location.origin}/control`, shouldCreateUser: false },
    });
    setStatus(error ? 'error' : 'sent');
  }

  return (
    <main>
      <h1>{t('auth.signInTitle')}</h1>
      <form onSubmit={onSubmit}>
        <label htmlFor="email">{t('auth.emailLabel')}</label>
        <input
          id="email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
        <button type="submit" disabled={status === 'sending'}>
          {status === 'sending' ? t('auth.sending') : t('auth.sendLink')}
        </button>
      </form>
      <p role="status" aria-live="polite">
        {status === 'sent' && t('auth.linkSent')}
        {status === 'error' && t('auth.error')}
      </p>
    </main>
  );
}
