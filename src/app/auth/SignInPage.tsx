import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { toLoginEmail } from '../../lib/loginId';
import { BRAND_LOGO_SRC } from '../../lib/brand';
import { LanguageSwitch } from './LanguageSwitch';
import '../../lib/forms.css';

type Status = 'idle' | 'signing-in' | 'wrong' | 'failed';

// Username + password (PRD A4, owner decision 2026-11-03). Magic links were dropped: they open in
// Safari, not the installed iOS PWA, so the session never reached the app.
export function SignInPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [status, setStatus] = useState<Status>('idle');

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    const email = toLoginEmail(username);
    // A value that can't be a username gets the same message as a wrong password.
    if (!email || password.length === 0) {
      setStatus('wrong');
      return;
    }
    setStatus('signing-in');
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (!error) {
      navigate('/control', { replace: true });
      return;
    }
    // 4xx = bad credentials (never says whether the user exists); anything else = try again.
    setStatus(
      error.status !== undefined && error.status >= 400 && error.status < 500 ? 'wrong' : 'failed',
    );
  }

  return (
    <main className="form-page theme-dark">
      <header className="brand">
        {/* The plant logo (one place: src/lib/brand.ts). Decorative: the names below are the text. */}
        <img className="brand-logo" src={BRAND_LOGO_SRC} alt="" width="360" height="84" />
        <div>
          <p className="brand-company">{t('brand.company')}</p>
          <p className="brand-product">{t('app.name')}</p>
        </div>
      </header>
      <LanguageSwitch />
      <h1>{t('auth.signInTitle')}</h1>
      <form onSubmit={onSubmit} noValidate>
        <div className="field">
          <label htmlFor="username">{t('auth.usernameLabel')}</label>
          <input
            id="username"
            name="username"
            type="text"
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            required
            aria-describedby="username-hint"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
          <p id="username-hint" className="hint">
            {t('auth.usernameHint')}
          </p>
        </div>
        <div className="field">
          <label htmlFor="password">{t('auth.passwordLabel')}</label>
          <input
            id="password"
            name="password"
            type={showPassword ? 'text' : 'password'}
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <div className="field check">
          <label>
            <input
              type="checkbox"
              checked={showPassword}
              onChange={(e) => setShowPassword(e.target.checked)}
            />
            {t('auth.showPassword')}
          </label>
        </div>
        <button type="submit" disabled={status === 'signing-in'}>
          {status === 'signing-in' ? t('auth.signingIn') : t('auth.signIn')}
        </button>
      </form>
      <p role="status" aria-live="polite" className="error">
        {(status === 'wrong' || status === 'failed') && (
          <span aria-hidden="true" className="error-icon">
            ⚠
          </span>
        )}
        {status === 'wrong' && t('auth.wrongCredentials')}
        {status === 'failed' && t('auth.signInFailed')}
      </p>
    </main>
  );
}
