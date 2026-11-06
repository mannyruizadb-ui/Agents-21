import { useRef, useState } from 'react';
import { useSearchParams } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { DataAge } from './DataAge';
import { useReasonLabeler, useReasonOptions } from './downReasons';
import { IconMachineDown, IconReady } from './Icons';
import { buildDownReason, REASON_MAX, reasonText, type ReasonCode } from './machineReason';
import { errorMessageKey, unwrap } from './rpcError';
import { useMyRoles } from './useMyRoles';
import { estimateServerNow, minutesSinceEnd } from './washerTime';
import { useAreas, useMachineStatus, type MachineStatusRow } from './washroomData';
import '../../lib/forms.css';
import './washroom.css';

// Machine down / back up (owner 2026-11-04): owner and managers mark any machine down with a reason,
// or back up with one tap + confirm (set_machine_status, append-only history). Others see the list.
// Reachable from the washer board and every station screen (?machine=<id> preselects).

export function MachineStatusPage() {
  const names = useLocalNames();
  const { t, i18n } = useTranslation();
  const session = useRequiredSession();
  const qc = useQueryClient();
  const now = useNow(1000);
  const [params, setParams] = useSearchParams();
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const status = useMachineStatus(plantId);
  useLiveRefetch(status.refetch, !!plantId);
  const roles = useMyRoles(session.user.id);
  const myRoles = roles.rolesFor(plantId);
  const canEdit = myRoles.has('owner') || myRoles.has('manager');

  const machineId = params.get('machine') ?? '';
  const machine = status.data?.find((m) => m.machine_id === machineId);
  const [pick, setPick] = useState<ReasonCode | null>(null);
  const [details, setDetails] = useState('');
  const [confirming, setConfirming] = useState(false);
  const [confirmingUp, setConfirmingUp] = useState<string | null>(null);
  const reasonLabeler = useReasonLabeler();
  const [formError, setFormError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const clientId = useRef<string | null>(null);
  const serverNow = estimateServerNow(status.data?.[0]?.server_time, status.dataUpdatedAt, now);
  const down = (status.data ?? []).filter((m) => m.status === 'down');

  function reset() {
    setPick(null);
    setDetails('');
    setConfirming(false);
    setConfirmingUp(null);
    setFormError(null);
    clientId.current = null;
  }

  const setStatus = useMutation({
    mutationFn: async (v: {
      m: MachineStatusRow;
      to: 'down' | 'up';
      code?: ReasonCode;
      details?: string | null;
    }) => {
      clientId.current ??= crypto.randomUUID();
      return unwrap(
        await supabase.rpc('set_machine_status', {
          p_machine_id: v.m.machine_id,
          p_status: v.to,
          p_client_id: clientId.current,
          ...(v.code ? { p_reason_code: v.code } : {}),
          ...(v.details ? { p_reason: v.details } : {}),
        }),
      );
    },
    onSuccess: (_r, v) => {
      setDone(
        v.to === 'down'
          ? t('machines.markedDown', { name: names.machine(v.m.machine_name) })
          : t('machines.markedUp', { name: names.machine(v.m.machine_name) }),
      );
      reset();
    },
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: ['machine-status'] });
      void qc.invalidateQueries({ queryKey: ['washroom-board'] });
      void qc.invalidateQueries({ queryKey: ['queue'] });
    },
  });

  // Reasons are plant data (Setup → Down reasons); locale labels are only the fallback.
  const reasonOptions = useReasonOptions(plantId);
  const picked = reasonOptions.options.find((o) => o.code === pick);
  const built = buildDownReason(pick, details, picked?.requiresDetails ?? pick === 'other');
  const label = (c: ReasonCode) => reasonOptions.options.find((o) => o.code === c)?.label ?? c;

  function onReview() {
    if (!built.ok) {
      setFormError(
        built.error === 'pick'
          ? t('machines.errors.pick')
          : built.error === 'details'
            ? t('machines.errors.details')
            : t('machines.errors.tooLong', { max: REASON_MAX }),
      );
      return;
    }
    setFormError(null);
    setConfirming(true);
  }

  const areaSummary = (areas.data ?? []).map((a) => ({
    id: a.id,
    name: names.area(a.name),
    down: down.filter((m) => m.area_id === a.id).length,
  }));
  const upByArea = (areas.data ?? [])
    .map((a) => ({
      area: a,
      machines: (status.data ?? []).filter(
        (m) => m.area_id === a.id && m.status === 'up' && m.active,
      ),
    }))
    .filter((g) => g.machines.length > 0);
  const outFor = (since: string | null) => {
    const mins = minutesSinceEnd(since, serverNow);
    if (mins === null) return null;
    if (mins < 1) return t('common.justNow');
    return mins >= 60
      ? t('home.hm', { h: Math.floor(mins / 60), m: mins % 60 })
      : t('home.m', { m: mins });
  };
  const clock = (iso: string | null) =>
    iso
      ? new Intl.DateTimeFormat(i18n.language, { hour: 'numeric', minute: '2-digit' }).format(
          new Date(iso),
        )
      : '';

  return (
    <main className="form-page md-page">
      <div className="md-head">
        <h1>{t('machines.title')}</h1>
        {status.data && (
          <span className={down.length > 0 ? 'status-pill danger' : 'status-pill ok'}>
            {down.length > 0 ? <IconMachineDown /> : <IconReady />}{' '}
            {down.length > 0
              ? t('machines.downCount', { count: down.length })
              : t('machines.allUp')}
          </span>
        )}
      </div>
      <DataAge updatedAt={status.dataUpdatedAt} now={now} isFetching={status.isFetching} />
      {areaSummary.length > 0 && status.data && (
        <ul className="md-areas">
          {areaSummary.map((a) => (
            <li key={a.id} className={a.down > 0 ? 'down' : undefined}>
              <span className="md-area-name">{a.name}</span>
              <span className={a.down > 0 ? 'md-area-state danger' : 'md-area-state'}>
                {a.down > 0 ? <IconMachineDown /> : <IconReady />}{' '}
                {a.down > 0 ? t('machines.downCount', { count: a.down }) : t('machines.allUp')}
              </span>
            </li>
          ))}
        </ul>
      )}
      <div role="status" aria-live="polite">
        {done && (
          <p className="notice">
            <IconReady /> {done}
          </p>
        )}
      </div>
      {status.isError && <p className="error">{t(errorMessageKey(status.error))}</p>}

      <h2>{t('machines.downNow')}</h2>
      {status.data && down.length === 0 && (
        <p className="md-none">
          <IconReady /> {t('machines.noneDown')}
        </p>
      )}
      <ul className="md-list">
        {down.map((m) => {
          const why = m.reason_code ? reasonLabeler(m.reason_code, m.reason_label_i18n) : null;
          const fixing = canEdit && confirmingUp === m.machine_id;
          return (
            <li
              key={m.machine_id}
              id={`md-${m.machine_id}`}
              className={
                m.machine_id === machineId
                  ? 'md-card stripes-danger focus'
                  : 'md-card stripes-danger'
              }
            >
              <div className="md-card-head">
                <div>
                  <h3 className="head">{names.machine(m.machine_name)}</h3>
                  <p className="md-area">{names.area(m.area_name)}</p>
                </div>
                <span className="status-pill danger">
                  <IconMachineDown /> {t('board.pill.down')}
                </span>
              </div>
              <div className="md-out">
                <span className="md-out-label">{t('machines.outFor')}</span>
                <span className="md-out-time mono">{outFor(m.since)}</span>
              </div>
              {why && <p className="md-reason">{why}</p>}
              {m.reason && m.reason !== why && <p className="md-detail">{m.reason}</p>}
              {m.since && (
                <p className="md-since">{t('machines.downSinceTime', { time: clock(m.since) })}</p>
              )}
              {canEdit &&
                (fixing ? (
                  <div className="confirm-box" role="group" aria-labelledby={`up-${m.machine_id}`}>
                    <p id={`up-${m.machine_id}`}>
                      <strong>
                        {t('machines.confirmUp', { name: names.machine(m.machine_name) })}
                      </strong>
                    </p>
                    <div className="actions">
                      <button
                        type="button"
                        className="md-fixed"
                        disabled={setStatus.isPending}
                        onClick={() => setStatus.mutate({ m, to: 'up' })}
                      >
                        {t('machines.yesUp')}
                      </button>
                      <button
                        type="button"
                        className="secondary"
                        onClick={() => setConfirmingUp(null)}
                      >
                        {t('common.back')}
                      </button>
                    </div>
                  </div>
                ) : (
                  <button
                    type="button"
                    className="md-fixed"
                    onClick={() => {
                      setConfirmingUp(m.machine_id);
                      clientId.current = null;
                      setDone(null);
                    }}
                  >
                    <IconReady /> {t('machines.backUp')}
                  </button>
                ))}
            </li>
          );
        })}
      </ul>

      {!canEdit && roles.isSuccess && <p className="notice">{t('machines.readOnly')}</p>}
      {canEdit && (
        <section className="md-report" aria-labelledby="change-title">
          <h2 id="change-title">
            <IconMachineDown /> {t('machines.reportTitle')}
          </h2>
          <div className="field">
            <label htmlFor="m-machine">{t('machines.machineLabel')}</label>
            <select
              id="m-machine"
              value={machine?.status === 'up' ? machineId : ''}
              onChange={(e) => {
                setParams(e.target.value ? { machine: e.target.value } : {}, { replace: true });
                reset();
                setDone(null);
              }}
            >
              <option value="">{t('machines.choose')}</option>
              {upByArea.map((g) => (
                <optgroup key={g.area.id} label={names.area(g.area.name)}>
                  {g.machines.map((m) => (
                    <option key={m.machine_id} value={m.machine_id}>
                      {names.machine(m.machine_name)}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          </div>

          {machine?.status === 'up' && !confirming && (
            <>
              <fieldset className="field" style={{ border: 0, padding: 0, margin: 0 }}>
                <legend>
                  <strong>{t('machines.reasonLabel')}</strong>
                </legend>
                <ul className="pick-list md-reasons">
                  {reasonOptions.options.map(({ code: p, label: pLabel }) => (
                    <li key={p}>
                      <button
                        type="button"
                        aria-pressed={pick === p}
                        onClick={() => {
                          setPick(p);
                          clientId.current = null;
                        }}
                      >
                        {pLabel}
                      </button>
                    </li>
                  ))}
                </ul>
              </fieldset>
              <div className="field">
                <label htmlFor="m-details">
                  {picked?.requiresDetails
                    ? t('machines.detailsRequired')
                    : t('machines.detailsOptional')}
                </label>
                <textarea
                  id="m-details"
                  maxLength={REASON_MAX}
                  value={details}
                  onChange={(e) => {
                    setDetails(e.target.value);
                    clientId.current = null;
                  }}
                />
                <p className="hint">{t('machines.detailsHint', { max: REASON_MAX })}</p>
              </div>
              <div role="alert">{formError && <p className="error">{formError}</p>}</div>
              <button type="button" className="danger md-mark" onClick={onReview}>
                <IconMachineDown /> {t('machines.markDown')}
              </button>
            </>
          )}

          {machine?.status === 'up' && confirming && built.ok && (
            <div className="confirm-box" role="group" aria-labelledby="confirm-down">
              <p id="confirm-down">
                <strong>
                  {t('machines.confirmDown', { name: names.machine(machine.machine_name) })}
                </strong>
              </p>
              <p>
                {t('machines.reasonValue', {
                  reason: reasonText(built.code, built.details, label),
                })}
              </p>
              {machine.kind === 'washer' && <p className="hint">{t('machines.downEffect')}</p>}
              <div className="actions">
                <button
                  type="button"
                  className="danger"
                  disabled={setStatus.isPending}
                  onClick={() =>
                    setStatus.mutate({
                      m: machine,
                      to: 'down',
                      code: built.code,
                      details: built.details,
                    })
                  }
                >
                  {t('machines.yesDown')}
                </button>
                <button type="button" className="secondary" onClick={() => setConfirming(false)}>
                  {t('common.back')}
                </button>
              </div>
            </div>
          )}
        </section>
      )}
      <div role="alert">
        {setStatus.isError && <p className="error">{t(errorMessageKey(setStatus.error))}</p>}
      </div>
    </main>
  );
}
