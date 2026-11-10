import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useRequiredSession } from '../../app/auth/sessionContext';
import {
  clearSharedDevice,
  readSharedDevice,
  saveSharedDevice,
  writeLastActive,
} from '../../app/auth/sharedDevice';
import { useOwnerPlants } from '../admin/useOwnerPlants';
import { useAgo } from '../../lib/useAgo';
import { useNow } from '../../lib/useNow';
import { setupErrorKey } from './setupErrors';
import '../../lib/forms.css';
import './setup.css';

// Setup → Plant iPad (owner 2026-11-10). "Make this the plant iPad" on the device itself: from then on
// its sign-in screen lists the managers and leads by name, each signs in with their own 6-digit
// password, and it signs out after 10 minutes without use. Owners still sign in the normal way. The
// owner can remove any plant iPad here (it goes back to the normal sign-in for good). Owner only
// (RLS on shared_devices and the RPCs re-check the owner role).

interface DeviceRow {
  id: string;
  label: string;
  created_at: string;
  last_used_at: string | null;
}

export function SetupPlantIpadPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const ago = useAgo();
  const [thisDevice, setThisDevice] = useState(readSharedDevice);
  const [label, setLabel] = useState(() => t('sharedDevice.defaultLabel'));
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);

  const devices = useQuery({
    queryKey: ['shared-devices', plant?.id],
    enabled: Boolean(plant),
    queryFn: async (): Promise<DeviceRow[]> => {
      const plantId = plant?.id;
      if (!plantId) return [];
      const { data, error } = await supabase
        .from('shared_devices')
        .select('id, label, created_at, last_used_at')
        .eq('plant_id', plantId)
        .is('revoked_at', null)
        .order('created_at');
      if (error) throw error;
      return data ?? [];
    },
  });

  const register = useMutation({
    mutationFn: async () => {
      if (!plant) throw { message: 'VALIDATION_FAILED' };
      const { data, error } = await supabase.rpc('register_shared_device', {
        p_plant_id: plant.id,
        p_label: label.trim(),
      });
      if (error) throw error;
      const row = data?.[0];
      if (!row) throw new Error('no device');
      const device = { id: row.id, token: row.token, label: label.trim() };
      // The owner's own session on this device now times out too, counting from now (review L3).
      writeLastActive(Date.now());
      if (!saveSharedDevice(device)) {
        // This browser can't keep it: undo on the server so no orphan device is left.
        await supabase.rpc('revoke_shared_device', { p_id: row.id });
        throw { message: 'STORAGE' };
      }
      return device;
    },
    onSuccess: (d) => {
      setThisDevice(d);
      setStatus({ ok: true, text: t('sharedDevice.registered') });
    },
    onError: (e) =>
      setStatus({
        ok: false,
        text:
          (e as { message?: string }).message === 'STORAGE'
            ? t('sharedDevice.storageBlocked')
            : t(setupErrorKey(e)),
      }),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['shared-devices'] }),
  });

  const revoke = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('revoke_shared_device', { p_id: id });
      if (error) throw error;
      return id;
    },
    onSuccess: (id) => {
      if (thisDevice?.id === id) {
        clearSharedDevice();
        setThisDevice(null);
      }
      setStatus({ ok: true, text: t('sharedDevice.removed') });
    },
    onError: (e) => setStatus({ ok: false, text: t(setupErrorKey(e)) }),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['shared-devices'] }),
  });

  const list = devices.data ?? [];
  const now = useNow(60_000);

  return (
    <main className="form-page setup-page">
      <h1>{t('sharedDevice.setupTitle')}</h1>
      <p>{t('sharedDevice.setupIntro')}</p>

      <section className="card" aria-labelledby="this-device">
        <h2 id="this-device">{t('sharedDevice.thisDevice')}</h2>
        {thisDevice ? (
          <>
            <p>{t('sharedDevice.isPlantIpad', { label: thisDevice.label })}</p>
            <button
              type="button"
              className="secondary"
              disabled={revoke.isPending}
              onClick={() => revoke.mutate(thisDevice.id)}
            >
              {t('sharedDevice.stopThis')}
            </button>
          </>
        ) : (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              setStatus(null);
              register.mutate();
            }}
          >
            <div className="field">
              <label htmlFor="device-label">{t('sharedDevice.labelField')}</label>
              <input
                id="device-label"
                value={label}
                maxLength={40}
                onChange={(e) => setLabel(e.target.value)}
              />
            </div>
            <button
              type="submit"
              disabled={!plant || register.isPending || label.trim().length === 0}
            >
              {t('sharedDevice.makeThis')}
            </button>
          </form>
        )}
      </section>

      <section className="card" aria-labelledby="all-devices">
        <h2 id="all-devices">{t('sharedDevice.allTitle')}</h2>
        {devices.isPending ? (
          <p role="status">{t('common.loading')}</p>
        ) : list.length === 0 ? (
          <p>{t('sharedDevice.none')}</p>
        ) : (
          <ul className="setup-list">
            {list.map((d) => (
              <li key={d.id}>
                <p>
                  <strong>{d.label}</strong>
                  {thisDevice?.id === d.id && ` · ${t('sharedDevice.thisOne')}`}
                </p>
                <p className="hint">
                  {d.last_used_at
                    ? t('sharedDevice.lastUsed', { ago: ago(Date.parse(d.last_used_at), now) })
                    : t('sharedDevice.neverUsed')}
                </p>
                <button
                  type="button"
                  className="secondary"
                  disabled={revoke.isPending}
                  onClick={() => revoke.mutate(d.id)}
                >
                  {t('sharedDevice.remove', { label: d.label })}
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      <p role="status" aria-live="polite" className={status?.ok ? 'ok' : 'error'}>
        {status?.text}
      </p>
    </main>
  );
}
