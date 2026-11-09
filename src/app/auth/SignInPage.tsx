import { useEffect, useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { toLoginEmail } from '../../lib/loginId';
import { callSignIn } from './signInApi';
import { BRAND_LOGO_SRC } from '../../lib/brand';
import { LanguageSwitch } from './LanguageSwitch';
import { readSignInPrefs, saveSignInPrefs, usesNumberPad } from './signInPrefs';
import '../../lib/forms.css';
import './signin.css';

type Status =
  | { kind: 'idle' }
  | { kind: 'signing-in' }
  | { kind: 'wrong' }
  | { kind: 'locked'; minutes: number }
  | { kind: 'rate_limited' }
  | { kind: 'failed' };

// Username + password (PRD A4, owner decision 2026-11-03). Magic links were dropped: they open in
// Safari, not the installed iOS PWA, so the session never reached the app.
// 2026-11-07: the password is checked by the `sign-in` Edge Function (lockout after 5 wrong passwords,
// password pepper); it returns the session, which is handed to supabase.auth.setSession.
// Big and simple (owner 2026-11-06: older managers): large text and buttons, the last username is
// remembered on this phone, and managers' 6-digit passwords get the number pad. A username with "@"
// (the owners' email sign-in) or "my password has letters" switches to the normal keyboard.
export function SignInPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [prefs] = useState(readSignInPrefs);
  const [username, setUsername] = useState(prefs.lastUsername);
  const [letters, setLetters] = useState(prefs.letters);
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [status, setStatus] = useState<Status>({ kind: 'idle' });

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    // A value that can't be a username gets the same message as a wrong password.
    if (!toLoginEmail(username) || password.length === 0) {
      setStatus({ kind: 'wrong' });
      return;
    }
    setStatus({ kind: 'signing-in' });
    const result = await callSignIn(username.trim(), password);
    if (result.kind === 'ok') {
      const { error } = await supabase.auth.setSession({
        access_token: result.accessToken,
        refresh_token: result.refreshToken,
      });
      if (error) {
        setStatus({ kind: 'failed' });
        return;
      }
      saveSignInPrefs({ lastUsername: username.trim(), letters });
      void navigate('/control', { replace: true });
      return;
    }
    setStatus(result);
  }

  const message =
    status.kind === 'wrong'
      ? t('auth.wrongCredentials')
      : status.kind === 'locked'
        ? t('auth.locked', { count: status.minutes })
        : status.kind === 'rate_limited'
          ? t('auth.rateLimited')
          : status.kind === 'failed'
            ? t('auth.signInFailed')
            : null;

  const numberPad = usesNumberPad(username, letters);
  useEffect(() => {
    // A remembered username: go straight to the password.
    if (prefs.lastUsername) document.getElementById('password')?.focus();
  }, [prefs.lastUsername]);

  return (
    <main className="form-page theme-dark signin-page">
      <header className="brand">
        {/* The ADB logo (one place: src/lib/brand.ts). It carries the company name, so it is the text. */}
        <img
          className="brand-logo"
          src={BRAND_LOGO_SRC}
          alt={t('brand.company')}
          width="1058"
          height="871"
        />
        <p className="brand-product">{t('app.name')}</p>
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
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor="password">{t('auth.passwordLabel')}</label>
          <input
            id="password"
            name="password"
            type={showPassword ? 'text' : 'password'}
            autoComplete="current-password"
            inputMode={numberPad ? 'numeric' : 'text'}
            {...(numberPad ? { pattern: '[0-9]*' } : {})}
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
        {!username.includes('@') && (
          <button
            type="button"
            className="secondary signin-keyboard"
            aria-pressed={letters}
            onClick={() => {
              setLetters((l) => !l);
              document.getElementById('password')?.focus();
            }}
          >
            {letters ? t('auth.useNumbers') : t('auth.useLetters')}
          </button>
        )}
        <button type="submit" className="signin-submit" disabled={status.kind === 'signing-in'}>
          {status.kind === 'signing-in' ? t('auth.signingIn') : t('auth.signIn')}
        </button>
      </form>
      <p role="status" aria-live="polite" className="error">
        {message !== null && (
          <span aria-hidden="true" className="error-icon">
            ⚠
          </span>
        )}
        {message}
      </p>
    </main>
  );
}
