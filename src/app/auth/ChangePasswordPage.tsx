import { useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { SignOutButton } from './SignOutButton';
import { NewPasswordField } from './NewPasswordField';
import { changePasswordProblem, type Problem } from './changePasswordErrors';
import { readSignInPrefs } from './signInPrefs';
import { supabase } from '../../lib/supabase';
import { passwordProblem, passwordProblemKey } from '../../lib/passwordRules';
import { callManageUsers } from '../../features/admin/manageUsers';
import { callSignIn } from './signInApi';
import '../../lib/forms.css';
import './signin.css';

/**
 * The only screen reachable while app_metadata.must_change_password is true (first sign-in with
 * a temporary password, or after an owner reset). Only manage-users clears the flag; it checks the
 * current password through the sign-in lockout first (2026-11-07). Big and simple, like sign-in.
 *
 * `voluntary` (review 2026-11-09: "Change my password" in More): the same form inside the app, for
 * anyone signed in; it stays on the page and says when the password is saved.
 */
export function ChangePasswordPage({ voluntary = false }: { voluntary?: boolean }) {
  const { t } = useTranslation();
  const [saved, setSaved] = useState(false);
  const [current, setCurrent] = useState('');
  // Temporary passwords the app generates have letters; the sign-in screen remembers the choice.
  const [currentLetters, setCurrentLetters] = useState(() => readSignInPrefs().letters);
  const [password, setPassword] = useState('');
  const [letters, setLetters] = useState(false);
  const [confirm, setConfirm] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [saving, setSaving] = useState(false);
  const [problem, setProblem] = useState<Problem | null>(null);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (current.length === 0) return setProblem({ kind: 'currentRequired' });
    const rule = passwordProblem(password);
    if (rule !== null) return setProblem({ kind: 'rule', key: passwordProblemKey(rule) });
    if (password !== confirm) return setProblem({ kind: 'mismatch' });
    if (password === current) return setProblem({ kind: 'same' });
    setProblem(null);
    setSaved(false);
    setSaving(true);
    try {
      // The login, read while the current session is still valid.
      const login = (await supabase.auth.getSession()).data.session?.user.email ?? null;
      await callManageUsers({
        action: 'change_own_password',
        current_password: current,
        new_password: password,
      });
      // Owner 2026-11-10 ("the page gets stuck"): changing a password ends every session of the
      // account on the server, so the old session can't be refreshed. Sign in again with the new
      // password and hand that session to the app; if that fails, sign out cleanly so the sign-in
      // screen shows (never a page stuck on "Saving…").
      const fresh = login ? await callSignIn(login, password) : null;
      if (fresh?.kind === 'ok') {
        const { error } = await supabase.auth.setSession({
          access_token: fresh.accessToken,
          refresh_token: fresh.refreshToken,
        });
        if (error) await supabase.auth.signOut({ scope: 'local' });
      } else {
        await supabase.auth.signOut({ scope: 'local' });
      }
      if (voluntary) {
        setCurrent('');
        setPassword('');
        setConfirm('');
        setSaved(true);
        setSaving(false);
      }
    } catch (e) {
      setProblem(changePasswordProblem(e));
      setSaving(false);
    }
  }

  const message =
    problem === null
      ? null
      : problem.kind === 'rule'
        ? t(`password.problems.${problem.key}`)
        : problem.kind === 'locked'
          ? t('auth.locked', { count: problem.minutes })
          : problem.kind === 'rateLimited'
            ? t('auth.rateLimited')
            : t(`changePassword.errors.${problem.kind}`);

  return (
    <main className={voluntary ? 'form-page' : 'form-page theme-dark signin-page'}>
      <h1>{t(voluntary ? 'changePassword.myTitle' : 'changePassword.title')}</h1>
      <p>{t(voluntary ? 'changePassword.myIntro' : 'changePassword.intro')}</p>
      <form onSubmit={onSubmit} noValidate>
        <NewPasswordField
          id="current-password"
          label={t('changePassword.currentLabel')}
          value={current}
          onChange={setCurrent}
          letters={currentLetters}
          onLettersChange={setCurrentLetters}
          shown={showPassword}
          rule={false}
          autoComplete="current-password"
          invalid={problem?.kind === 'wrongCurrent' || problem?.kind === 'currentRequired'}
          describedBy="change-password-status"
        />
        <NewPasswordField
          id="new-password"
          label={t('changePassword.newLabel')}
          value={password}
          onChange={setPassword}
          letters={letters}
          onLettersChange={setLetters}
          shown={showPassword}
          invalid={problem?.kind === 'rule' || problem?.kind === 'same'}
          describedBy="change-password-status"
        />
        <div className="field">
          <label htmlFor="confirm-password">{t('changePassword.confirmLabel')}</label>
          <input
            id="confirm-password"
            type={showPassword ? 'text' : 'password'}
            autoComplete="new-password"
            inputMode={letters ? 'text' : 'numeric'}
            {...(letters ? {} : { pattern: '[0-9]*' })}
            required
            aria-invalid={problem?.kind === 'mismatch'}
            aria-describedby="change-password-status"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
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
        <button type="submit" className="signin-submit" disabled={saving}>
          {saving ? t('changePassword.saving') : t('changePassword.save')}
        </button>
      </form>
      <p
        id="change-password-status"
        role="status"
        aria-live="polite"
        className={saved && message === null ? 'notice' : 'error'}
      >
        {saved && message === null && t('changePassword.saved')}
        {message !== null && (
          <span aria-hidden="true" className="error-icon">
            ⚠
          </span>
        )}
        {message}
      </p>
      {!voluntary && (
        <div className="actions">
          <SignOutButton canSend={false} />
        </div>
      )}
    </main>
  );
}
