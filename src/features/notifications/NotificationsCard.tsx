import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { env } from '../../lib/env';
import { IconReady, IconWarning } from '../washroom/Icons';
import {
  currentPermission,
  currentSubscription,
  readPushEnv,
  turnOffPush,
  turnOnPush,
} from './pushClient';
import { pushSupport } from './pushSupport';
import { MoreInfo } from '../../lib/MoreInfo';

// "Notifications" card on Control home (owner and managers): machine-down alerts by Web Push
// (owner 2026-11-04: push approved, not SMS). Shows what they get, whether this phone can get it
// (iPhone: only after "Add to Home Screen", iOS 16.4+), and Turn on / Turn off.

type Status = 'checking' | 'on' | 'off';

export function NotificationsCard({ plantId }: { plantId: string }) {
  const { t } = useTranslation();
  const [support] = useState(() => pushSupport(readPushEnv()));
  const [permission, setPermission] = useState(currentPermission);
  const [status, setStatus] = useState<Status>('checking');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const vapid = env.vapidPublicKey;

  useEffect(() => {
    let alive = true;
    if (support !== 'supported') return;
    void currentSubscription().then((sub) => {
      if (alive) setStatus(sub && currentPermission() === 'granted' ? 'on' : 'off');
    });
    return () => {
      alive = false;
    };
  }, [support]);

  if (!vapid) {
    return <p className="hint">{t('notifications.notSetUp')}</p>;
  }

  async function onTurnOn() {
    if (!vapid) return;
    setBusy(true);
    setMessage(null);
    try {
      const r = await turnOnPush(plantId, vapid);
      setPermission(currentPermission());
      if (r.ok) {
        setStatus('on');
        setMessage({ ok: true, text: t('notifications.turnedOn') });
      } else if (r.reason === 'subscribe-failed') {
        setMessage({ ok: false, text: t('notifications.subscribeFailed') });
      } else if (r.reason === 'save-failed') {
        setMessage({ ok: false, text: t('notifications.saveFailed') });
      } else if (r.reason === 'dismissed') {
        setMessage({ ok: false, text: t('notifications.dismissed') });
      }
    } catch {
      setMessage({ ok: false, text: t('notifications.saveFailed') });
    } finally {
      setBusy(false);
    }
  }

  async function onTurnOff() {
    setBusy(true);
    setMessage(null);
    try {
      await turnOffPush();
      setStatus('off');
      setMessage({ ok: true, text: t('notifications.turnedOff') });
    } catch {
      setMessage({ ok: false, text: t('notifications.offFailed') });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card" aria-labelledby="notif-title">
      <h2 id="notif-title">{t('notifications.title')}</h2>
      <MoreInfo>{t('notifications.what')}</MoreInfo>

      {support === 'ios-install' && (
        <div className="notice">
          <p>
            <strong>{t('notifications.iosInstallTitle')}</strong>
          </p>
          <ol>
            <li>{t('notifications.iosStep1')}</li>
            <li>{t('notifications.iosStep2')}</li>
            <li>{t('notifications.iosStep3')}</li>
          </ol>
        </div>
      )}
      {support === 'ios-update' && <p className="notice">{t('notifications.iosUpdate')}</p>}
      {support === 'unsupported' && <p className="notice">{t('notifications.unsupported')}</p>}

      {support === 'supported' && permission === 'denied' && (
        <div className="notice" role="alert">
          <p>
            <IconWarning /> <strong>{t('notifications.deniedTitle')}</strong>
          </p>
          <p>{t('notifications.deniedIphone')}</p>
          <p>{t('notifications.deniedAndroid')}</p>
        </div>
      )}

      {support === 'supported' && permission !== 'denied' && status !== 'checking' && (
        <>
          <p>
            {status === 'on' ? (
              <>
                <IconReady /> {t('notifications.isOn')}
              </>
            ) : (
              t('notifications.isOff')
            )}
          </p>
          <div className="actions">
            {status === 'off' ? (
              <button type="button" disabled={busy} onClick={() => void onTurnOn()}>
                {busy ? t('notifications.working') : t('notifications.turnOn')}
              </button>
            ) : (
              <button
                type="button"
                className="secondary"
                disabled={busy}
                onClick={() => void onTurnOff()}
              >
                {busy ? t('notifications.working') : t('notifications.turnOff')}
              </button>
            )}
          </div>
        </>
      )}
      <p role="status" aria-live="polite" className={message && !message.ok ? 'error' : undefined}>
        {message?.text}
      </p>
    </section>
  );
}
