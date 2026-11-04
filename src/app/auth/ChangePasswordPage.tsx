import { useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { SignOutButton } from './SignOutButton';
import { supabase } from '../../lib/supabase';
import { callManageUsers, ManageUsersError } from '../../features/admin/manageUsers';
import '../../lib/forms.css';

const MIN_CHARS = 10;
const MAX_BYTES = 72;

type ErrorKey = 'tooShort' | 'tooLong' | 'mismatch' | 'same' | 'failed';

/**
 * The only screen reachable while app_metadata.must_change_password is true (first sign-in with
 * a temporary password, or after an owner reset). Only manage-users clears the flag.
 */
export function ChangePasswordPage() {
  const { t } = useTranslation();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<ErrorKey | null>(null);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (password.length < MIN_CHARS) return setError('tooShort');
    if (new TextEncoder().encode(password).length > MAX_BYTES) return setError('tooLong');
    if (password !== confirm) return setError('mismatch');
    setError(null);
    setSaving(true);
    try {
      await callManageUsers({ action: 'change_own_password', new_password: password });
      // New token without the flag; RequireAuth re-renders from onAuthStateChange.
      await supabase.auth.refreshSession();
    } catch (e) {
      const reason = e instanceof ManageUsersError ? e.reason : undefined;
      setError(
        reason === 'same_password'
          ? 'same'
          : reason === 'password_too_short'
            ? 'tooShort'
            : reason === 'password_too_long'
              ? 'tooLong'
              : 'failed',
      );
      setSaving(false);
    }
  }

  return (
    <main className="form-page">
      <h1>{t('changePassword.title')}</h1>
      <p>{t('changePassword.intro', { count: MIN_CHARS })}</p>
      <form onSubmit={onSubmit} noValidate>
        <div className="field">
          <label htmlFor="new-password">{t('changePassword.newLabel')}</label>
          <input
            id="new-password"
            type={showPassword ? 'text' : 'password'}
            autoComplete="new-password"
            required
            minLength={MIN_CHARS}
            aria-invalid={error === 'tooShort' || error === 'tooLong' || error === 'same'}
            aria-describedby="change-password-status"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor="confirm-password">{t('changePassword.confirmLabel')}</label>
          <input
            id="confirm-password"
            type={showPassword ? 'text' : 'password'}
            autoComplete="new-password"
            required
            aria-invalid={error === 'mismatch'}
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
        <div className="actions">
          <button type="submit" disabled={saving}>
            {saving ? t('changePassword.saving') : t('changePassword.save')}
          </button>
          <SignOutButton canSend={false} />
        </div>
      </form>
      <p id="change-password-status" role="status" aria-live="polite" className="error">
        {error && t(`changePassword.errors.${error}`, { count: MIN_CHARS })}
      </p>
    </main>
  );
}
