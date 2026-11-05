import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { userStore } from '../../lib/scopedStore';
import { supabase } from '../../lib/supabase';
import { useNow } from '../../lib/useNow';
import { IconWarning } from './Icons';
import { unwrap } from './rpcError';
import { ackAlarm, readAcked, tapAlarms } from './tapAlarms';
import { useTapSync } from './useTapSync';

// Loud, persistent "Tap not recorded" alarm (owner 2026-11-05) on the station, the washer board and
// Control home. Shown until dismissed; dismissing only hides it, the tap is never dropped.

function useMachineNames(ids: readonly string[]) {
  const key = [...new Set(ids)].sort();
  return useQuery({
    queryKey: ['machine-names', key],
    enabled: key.length > 0,
    queryFn: async (): Promise<Map<string, string>> => {
      const rows = unwrap(await supabase.from('machines').select('id, name').in('id', key)) ?? [];
      return new Map(rows.map((r) => [r.id, r.name]));
    },
    staleTime: 5 * 60_000,
  });
}

export function TapAlarmBanner({ variant = 'light' }: { variant?: 'light' | 'dark' }) {
  const { t, i18n } = useTranslation();
  const userId = useRequiredSession().user.id;
  const taps = useTapSync();
  const now = useNow(15_000);
  const [ackVersion, setAckVersion] = useState(0);
  // Re-read the acknowledgements after each dismiss (ackVersion) or account change.
  // eslint-disable-next-line react-hooks/exhaustive-deps -- ackVersion is the refresh trigger
  const acked = useMemo(() => readAcked(userStore(userId)), [userId, ackVersion]);
  const alarms = tapAlarms(taps.pending, taps.rejected, acked, now);
  const names = useMachineNames(alarms.map((a) => a.machineId));

  if (alarms.length === 0) return null;
  const allIds = [...taps.pending.map((p) => p.clientId), ...taps.rejected.map((r) => r.clientId)];
  const time = (iso: string) =>
    new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
      new Date(iso),
    );

  return (
    <div className={`tap-alarm tap-alarm-${variant}`} role="alert">
      <p className="tap-alarm-title">
        <IconWarning size="1.4em" />
        <strong>{t('tapAlarm.title')}</strong>
      </p>
      <ul>
        {alarms.map((a) => (
          <li key={a.clientId}>
            <p>
              <strong>{names.data?.get(a.machineId) ?? t('tapAlarm.aWasher')}</strong>
              {' · '}
              {t('tapAlarm.tappedAt', { time: time(a.tappedAt) })}
            </p>
            <p>
              {a.kind === 'late'
                ? t('tapAlarm.late')
                : t('tapAlarm.stuck', { count: a.waitingMinutes ?? 20 })}
            </p>
            <button
              type="button"
              onClick={() => {
                ackAlarm(userStore(userId), a.clientId, allIds);
                setAckVersion((v) => v + 1);
              }}
            >
              {t('tapAlarm.dismiss')}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
