import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import { flushTaps, pendingTapCount } from '../../features/washroom/useTapSync';
import { flushEstimates, pendingEstimateCount } from '../../features/estimates/useEstimateOutbox';
import { removeThisDevicePush } from '../../features/notifications/pushClient';
import { pendingTotal, signOutWith, type PendingSource, type SignOutChoice } from './signOutFlow';

// Guarded sign-out (security review 2026-11-04, H1). With nothing pending it signs out at once.
// With taps or estimates waiting in this account's storage it asks: "Send now" (send, then sign out)
// or "Keep for next time" (sign out, leave them for this account). `canSend` is false while the
// account must change its password: the server refuses every write until then.
// Every sign-out first removes this device's push subscription, so the next person on the phone
// doesn't get the last person's machine-down alerts.

async function signOutDevice(): Promise<void> {
  await removeThisDevicePush();
  await supabase.auth.signOut();
}

function sourcesFor(userId: string): PendingSource[] {
  return [
    { count: () => pendingTapCount(userId), flush: () => flushTaps(userId) },
    { count: () => pendingEstimateCount(userId), flush: () => flushEstimates(userId) },
  ];
}

export function SignOutButton({ canSend = true }: { canSend?: boolean }) {
  const { t } = useTranslation();
  const [asking, setAsking] = useState<{ userId: string; count: number } | null>(null);
  const [busy, setBusy] = useState(false);

  async function currentUserId(): Promise<string | null> {
    const { data } = await supabase.auth.getSession();
    return data.session?.user.id ?? null;
  }

  async function onSignOut() {
    const userId = await currentUserId();
    const count = userId ? pendingTotal(sourcesFor(userId)) : 0;
    if (!userId || count === 0) {
      await signOutDevice();
      return;
    }
    setAsking({ userId, count });
  }

  async function choose(choice: SignOutChoice) {
    if (!asking) return;
    setBusy(true);
    try {
      await signOutWith(choice, sourcesFor(asking.userId), signOutDevice);
    } finally {
      setBusy(false);
      setAsking(null);
    }
  }

  if (!asking) {
    return (
      <button type="button" className="secondary" onClick={() => void onSignOut()}>
        {t('auth.signOut')}
      </button>
    );
  }
  return (
    <div className="confirm-box" role="group" aria-labelledby="signout-pending">
      <p id="signout-pending">
        <strong>{t('signOut.pending', { count: asking.count })}</strong>
      </p>
      {!canSend && <p className="hint">{t('signOut.cantSendYet')}</p>}
      <div className="actions">
        {canSend && (
          <button type="button" disabled={busy} onClick={() => void choose('send')}>
            {busy ? t('signOut.sending') : t('signOut.sendNow')}
          </button>
        )}
        <button
          type="button"
          className="secondary"
          disabled={busy}
          onClick={() => void choose('keep')}
        >
          {t('signOut.keep')}
        </button>
        <button type="button" className="secondary" disabled={busy} onClick={() => setAsking(null)}>
          {t('common.cancel')}
        </button>
      </div>
    </div>
  );
}
