import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { availableLocales } from '../../lib/i18n';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants, type OwnerPlant } from '../admin/useOwnerPlants';
import { IconDown, IconUp } from '../washroom/Icons';
import { useDownReasons, useReasonLabeler, type DownReasonRow } from '../washroom/downReasons';
import { asLabelMap, codeFromLabel, reorderUpdates } from '../washroom/machineReason';
import { cleanName, setupErrorKey } from './setupErrors';
import '../../lib/forms.css';
import './setup.css';
import { MoreInfo } from '../../lib/MoreInfo';

// Setup → Down reasons (owner 2026-11-05): the plant's machine-down reasons are data. The owner adds
// reasons, edits their labels (one per language the app has, English required), reorders and
// deactivates them. "other" is fixed (always there, always asks for details). The code is set once
// from the English label and never changes (history points at it). RLS: owner only.

/** English first, then the other locale files the app ships (languages are data, not hard-coded). */
const LANGS = ['en', ...availableLocales.filter((l) => l !== 'en').sort()];

type Labels = Record<string, string>;

/** Labels → label_i18n: English required, empty languages left out; null if English is missing. */
function toLabelI18n(labels: Labels): Record<string, string> | null {
  const out: Record<string, string> = {};
  for (const lang of LANGS) {
    const v = cleanName(labels[lang] ?? '');
    if (v) out[lang] = v;
  }
  return out.en ? out : null;
}

function LabelFields({
  idBase,
  labels,
  onChange,
}: {
  idBase: string;
  labels: Labels;
  onChange: (l: Labels) => void;
}) {
  const { t } = useTranslation();
  return (
    <>
      {LANGS.map((lang) => (
        <div className="field" key={lang}>
          <label htmlFor={`${idBase}-${lang}`}>
            {t('setup.reasons.labelIn', {
              language: t(`setup.languages.${lang}`, { defaultValue: lang }),
            })}
            {lang === 'en' ? ` (${t('setup.required')})` : ''}
          </label>
          <input
            id={`${idBase}-${lang}`}
            lang={lang}
            value={labels[lang] ?? ''}
            maxLength={60}
            autoComplete="off"
            onChange={(e) => onChange({ ...labels, [lang]: e.target.value })}
          />
        </div>
      ))}
    </>
  );
}

function ReasonRow({
  reason,
  isFirst,
  isLast,
  busy,
  onSave,
  onMove,
}: {
  reason: DownReasonRow;
  isFirst: boolean;
  isLast: boolean;
  busy: boolean;
  onSave: (
    patch: Partial<Pick<DownReasonRow, 'label_i18n' | 'active' | 'requires_details'>>,
  ) => void;
  onMove: (dir: 'up' | 'down') => void;
}) {
  const { t } = useTranslation();
  const labelOf = useReasonLabeler();
  const [editing, setEditing] = useState(false);
  const [labels, setLabels] = useState<Labels>(
    () => ({ ...(asLabelMap(reason.label_i18n) ?? {}) }) as Labels,
  );
  const fixed = reason.code === 'other';
  const name = labelOf(reason.code, reason.label_i18n);

  return (
    <li className={reason.active ? 'setup-row' : 'setup-row inactive'}>
      <div className="setup-row-head">
        <p className="setup-row-text">
          <strong className="head">{name}</strong>
          <span className="setup-kind">
            {fixed && <span className="badge setup-fixed">{t('setup.reasons.fixed')}</span>}
            {!reason.active && <span className="badge setup-off">{t('setup.inactive')}</span>}
            {fixed
              ? t('setup.reasons.alwaysAsks')
              : reason.requires_details && t('setup.reasons.needsDetails')}
          </span>
        </p>
        <span className="setup-row-actions">
          {!fixed && (
            <>
              <button
                type="button"
                className="secondary setup-icon"
                disabled={busy || isFirst}
                aria-label={t('home.moveUp', { name })}
                title={t('home.moveUp', { name })}
                onClick={() => onMove('up')}
              >
                <IconUp />
              </button>
              <button
                type="button"
                className="secondary setup-icon"
                disabled={busy || isLast}
                aria-label={t('home.moveDown', { name })}
                title={t('home.moveDown', { name })}
                onClick={() => onMove('down')}
              >
                <IconDown />
              </button>
            </>
          )}
          {!fixed && !editing && (
            <button type="button" className="secondary" onClick={() => setEditing(true)}>
              {t('setup.edit')}
            </button>
          )}
        </span>
      </div>
      {editing && !fixed && (
        <div className="setup-editor">
          <LabelFields idBase={`r-${reason.id}`} labels={labels} onChange={setLabels} />
          <div className="field check">
            <label>
              <input
                type="checkbox"
                checked={reason.requires_details}
                disabled={busy}
                onChange={(e) => onSave({ requires_details: e.target.checked })}
              />
              {t('setup.reasons.requireDetails')}
            </label>
          </div>
          <div className="actions">
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                const l = toLabelI18n(labels);
                if (!l) return onSave({});
                onSave({ label_i18n: l });
                setEditing(false);
              }}
            >
              {t('setup.save')}
            </button>
            <button type="button" className="secondary" onClick={() => setEditing(false)}>
              {t('common.cancel')}
            </button>
            {reason.active ? (
              <button
                type="button"
                className="danger"
                disabled={busy}
                onClick={() => onSave({ active: false })}
              >
                {t('setup.deactivate')}
              </button>
            ) : (
              <button
                type="button"
                className="secondary"
                disabled={busy}
                onClick={() => onSave({ active: true })}
              >
                {t('setup.reactivate')}
              </button>
            )}
          </div>
          {reason.active && <MoreInfo>{t('setup.reasons.deactivateHint')}</MoreInfo>}
        </div>
      )}
    </li>
  );
}

function AddReason({
  plant,
  reasons,
  onStatus,
}: {
  plant: OwnerPlant;
  reasons: DownReasonRow[];
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [labels, setLabels] = useState<Labels>({});
  const [needsDetails, setNeedsDetails] = useState(false);

  const add = useMutation({
    mutationFn: async (labelI18n: Record<string, string>) => {
      // New reasons go after the others and before "other", which stays last.
      const other = reasons.find((r) => r.code === 'other');
      const sort =
        Math.max(0, ...reasons.filter((r) => r.code !== 'other').map((r) => r.sort_order)) + 10;
      const { error } = await supabase.from('machine_down_reasons').insert({
        org_id: plant.org_id,
        plant_id: plant.id,
        code: codeFromLabel(
          labelI18n.en ?? '',
          reasons.map((r) => r.code),
        ),
        label_i18n: labelI18n,
        sort_order: sort,
        requires_details: needsDetails,
      });
      if (!error && other && other.sort_order <= sort) {
        const bump = await supabase
          .from('machine_down_reasons')
          .update({ sort_order: sort + 10 })
          .eq('id', other.id);
        if (bump.error) throw bump.error;
      }
      if (error) throw error;
      return labelI18n.en ?? '';
    },
    onSuccess: (name) => {
      setLabels({});
      setNeedsDetails(false);
      onStatus(true, t('setup.reasons.added', { name }));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['down-reasons'] }),
  });

  return (
    <section className="card" aria-labelledby="add-reason">
      <h2 id="add-reason">{t('setup.reasons.addTitle')}</h2>
      <form
        noValidate
        onSubmit={(e) => {
          e.preventDefault();
          const l = toLabelI18n(labels);
          if (!l) return onStatus(false, t('setup.errors.englishLabel'));
          add.mutate(l);
        }}
      >
        <LabelFields idBase="new-reason" labels={labels} onChange={setLabels} />
        <div className="field check">
          <label>
            <input
              type="checkbox"
              checked={needsDetails}
              onChange={(e) => setNeedsDetails(e.target.checked)}
            />
            {t('setup.reasons.requireDetails')}
          </label>
        </div>
        <MoreInfo>{t('machines.detailsHint', { max: 200 })}</MoreInfo>
        <button type="submit" disabled={add.isPending}>
          {t('setup.reasons.add')}
        </button>
      </form>
    </section>
  );
}

export function SetupReasonsPage() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const reasons = useDownReasons(plant?.id);
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);
  const onStatus = (ok: boolean, text: string) => setStatus({ ok, text });
  const list = reasons.data ?? [];

  const save = useMutation({
    mutationFn: async (v: {
      id: string;
      patch: Partial<Pick<DownReasonRow, 'label_i18n' | 'active' | 'requires_details'>>;
    }) => {
      if (Object.keys(v.patch).length === 0)
        throw { message: 'VALIDATION_FAILED', details: 'label_i18n' };
      const { error } = await supabase.from('machine_down_reasons').update(v.patch).eq('id', v.id);
      if (error) throw error;
    },
    onSuccess: () => onStatus(true, t('setup.saved')),
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['down-reasons'] }),
  });

  const move = useMutation({
    mutationFn: async (v: { id: string; dir: 'up' | 'down' }) => {
      for (const u of reorderUpdates(list, v.id, v.dir)) {
        const { error } = await supabase
          .from('machine_down_reasons')
          .update({ sort_order: u.sort_order })
          .eq('id', u.id);
        if (error) throw error;
      }
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['down-reasons'] }),
  });

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.reasons.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }

  return (
    <main className="form-page">
      <h1>{t('setup.reasons.title')}</h1>
      <div role="status" aria-live="polite">
        {status && <p className={status.ok ? 'notice' : 'error'}>{status.text}</p>}
      </div>
      {reasons.isError && <p className="error">{t(setupErrorKey(reasons.error))}</p>}
      <ol className="setup-list">
        {list.map((r, i) => (
          <ReasonRow
            key={r.id}
            reason={r}
            isFirst={i === 0}
            isLast={i === list.length - 1}
            busy={save.isPending || move.isPending}
            onSave={(patch) => save.mutate({ id: r.id, patch })}
            onMove={(dir) => move.mutate({ id: r.id, dir })}
          />
        ))}
      </ol>
      <AddReason plant={plant} reasons={list} onStatus={onStatus} />
    </main>
  );
}
