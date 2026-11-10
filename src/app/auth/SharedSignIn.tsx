import { useEffect, useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import {
  deviceSignIn,
  fetchDevicePeople,
  readWaiting,
  rememberWho,
  setWaiting,
  takeIdleSignOut,
  writeLastActive,
  type DevicePerson,
  type SharedDevice,
} from './sharedDevice';

type Status =
  | { kind: 'idle' }
  | { kind: 'signing-in' }
  | { kind: 'wrong' }
  | { kind: 'locked'; minutes: number }
  | { kind: 'rate_limited' }
  | { kind: 'failed' };

// Shared plant iPad sign-in (owner 2026-11-10): tap your name, type your own 6-digit password.
// The list comes from the sign-in function and only for this registered device. Owners are never
// listed; they use "Sign in another way" (the normal username sign-in).
export function SharedSignIn({
  device,
  onOtherWay,
}: {
  device: SharedDevice;
  onOtherWay: () => void;
}) {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();
  const [idleNotice] = useState(takeIdleSignOut);
  const [waiting] = useState(readWaiting);
  const [person, setPerson] = useState<DevicePerson | null>(null);
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [status, setStatus] = useState<Status>({ kind: 'idle' });

  const people = useQuery({
    queryKey: ['shared-device-people', device.id, i18n.language],
    queryFn: () => fetchDevicePeople(device.token, i18n.language),
    staleTime: 60_000,
    retry: 1,
  });

  useEffect(() => {
    if (person) document.getElementById('device-password')?.focus();
  }, [person]);

  function pick(p: DevicePerson | null) {
    setPerson(p);
    setPassword('');
    setStatus({ kind: 'idle' });
  }

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (!person) return;
    if (password.length === 0) {
      setStatus({ kind: 'wrong' });
      return;
    }
    setStatus({ kind: 'signing-in' });
    const result = await deviceSignIn(device.token, person.id, password);
    if (result.kind === 'ok') {
      // A fresh start for the 10-minute idle sign-out (the last person's time is not carried over).
      writeLastActive(Date.now());
      rememberWho(person.name);
      // Their entries left on this device send now that they are back; the notice goes.
      setWaiting(person.name, 0);
      const { error } = await supabase.auth.setSession({
        access_token: result.accessToken,
        refresh_token: result.refreshToken,
      });
      if (error) {
        setStatus({ kind: 'failed' });
        return;
      }
      void navigate('/control', { replace: true });
      return;
    }
    setPassword('');
    setStatus(result);
  }

  const message =
    status.kind === 'wrong'
      ? t('sharedDevice.wrongPassword')
      : status.kind === 'locked'
        ? t('auth.locked', { count: status.minutes })
        : status.kind === 'rate_limited'
          ? t('auth.rateLimited')
          : status.kind === 'failed'
            ? t('auth.signInFailed')
            : null;

  if (person) {
    return (
      <>
        <h1>{t('sharedDevice.hello', { name: person.name })}</h1>
        <form onSubmit={onSubmit} noValidate>
          <div className="field">
            <label htmlFor="device-password">{t('sharedDevice.passwordLabel')}</label>
            <input
              id="device-password"
              name="password"
              type={showPassword ? 'text' : 'password'}
              autoComplete="off"
              inputMode="numeric"
              pattern="[0-9]*"
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
          <button type="submit" className="signin-submit" disabled={status.kind === 'signing-in'}>
            {status.kind === 'signing-in' ? t('auth.signingIn') : t('auth.signIn')}
          </button>
          <button type="button" className="secondary" onClick={() => pick(null)}>
            {t('sharedDevice.notMe')}
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
      </>
    );
  }

  const list = people.data ?? [];
  return (
    <>
      <h1>{t('sharedDevice.whoTitle')}</h1>
      {idleNotice && (
        <p className="notice" role="status">
          {t('sharedDevice.idleSignedOut')}
        </p>
      )}
      {waiting.map((w) => (
        <p key={w.name} className="notice">
          {t('sharedDevice.waiting', { name: w.name, count: w.count })}
        </p>
      ))}
      {people.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : people.isError ? (
        <div role="alert">
          <p className="error">{t('sharedDevice.loadFailed')}</p>
          <button type="button" className="secondary" onClick={() => void people.refetch()}>
            {t('sharedDevice.retry')}
          </button>
        </div>
      ) : list.length === 0 ? (
        <p className="notice">{t('sharedDevice.nobody')}</p>
      ) : (
        <ul className="device-people" aria-label={t('sharedDevice.whoTitle')}>
          {list.map((p) => (
            <li key={p.id}>
              <button type="button" onClick={() => pick(p)}>
                {p.name}
              </button>
            </li>
          ))}
        </ul>
      )}
      <button type="button" className="secondary device-other" onClick={onOtherWay}>
        {t('sharedDevice.otherWay')}
      </button>
    </>
  );
}
