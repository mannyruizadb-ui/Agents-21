import { Fragment, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants, type OwnerPlant } from '../admin/useOwnerPlants';
import { useLocalizedName } from '../washroom/localizedName';
import { MoreInfo } from '../../lib/MoreInfo';
import { cleanName, setupErrorKey } from './setupErrors';
import {
  byFormulaNo,
  invalidateSetup,
  useSetupFormulas,
  useSetupWashGroups,
  type SetupFormula,
} from './setupData';
import { cleanFormulaNo, numText, parseMinutes } from './setupForm';
import '../../lib/forms.css';
import './setup.css';

// Setup → Formulas (owner 2026-11-09, review item 8): the washer programs (Milnor / Accu-Flow
// formula numbers) with their run time. Number | Name | Cycle minutes | Wash groups | Active,
// edited in place; "+ Add formula". Direct table writes through RLS + column grants; no deletes:
// a formula is retired (inactive), and the DB refuses that while an active wash group uses it.

type OnStatus = (ok: boolean, text: string) => void;
type Patch = Partial<Pick<SetupFormula, 'external_no' | 'name' | 'cycle_minutes' | 'active'>>;

function FormulaFields({
  idBase,
  no,
  name,
  minutes,
  setNo,
  setName,
  setMinutes,
}: {
  idBase: string;
  no: string;
  name: string;
  minutes: string;
  setNo: (v: string) => void;
  setName: (v: string) => void;
  setMinutes: (v: string) => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="setup-editor-grid">
      <div className="field">
        <label htmlFor={`${idBase}-no`}>{t('setup.formulas.number')}</label>
        <input
          id={`${idBase}-no`}
          value={no}
          maxLength={20}
          autoComplete="off"
          inputMode="numeric"
          onChange={(e) => setNo(e.target.value)}
        />
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-name`}>
          {t('setup.formulas.name')} ({t('setup.optional')})
        </label>
        <input
          id={`${idBase}-name`}
          value={name}
          maxLength={60}
          autoComplete="off"
          onChange={(e) => setName(e.target.value)}
        />
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-min`}>{t('setup.formulas.minutes')}</label>
        <input
          id={`${idBase}-min`}
          value={minutes}
          inputMode="numeric"
          autoComplete="off"
          aria-describedby={`${idBase}-min-hint`}
          onChange={(e) => setMinutes(e.target.value)}
        />
        <p className="hint" id={`${idBase}-min-hint`}>
          {t('setup.formulas.minutesHint')}
        </p>
      </div>
    </div>
  );
}

/** Validates the three fields; returns the row or a message key. */
function readFields(
  no: string,
  name: string,
  minutes: string,
): { external_no: string; name: string | null; cycle_minutes: number | null } | string {
  const cleanNo = cleanFormulaNo(no);
  if (!cleanNo) return 'setup.errors.formulaNo';
  const cleanN = name.trim() === '' ? null : cleanName(name);
  if (name.trim() !== '' && !cleanN) return 'setup.errors.name';
  const m = parseMinutes(minutes);
  if (m === 'invalid') return 'setup.errors.minutes';
  return { external_no: cleanNo, name: cleanN, cycle_minutes: m };
}

function FormulaEditor({
  formula,
  usedBy,
  onClose,
  onStatus,
}: {
  formula: SetupFormula;
  usedBy: number;
  onClose: () => void;
  onStatus: OnStatus;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [no, setNo] = useState(formula.external_no);
  const [name, setName] = useState(formula.name ?? '');
  const [minutes, setMinutes] = useState(numText(formula.cycle_minutes));
  const idBase = `f-${formula.id}`;
  const label = t('washroom.formulaOnly', { no: formula.external_no });

  const save = useMutation({
    mutationFn: async (patch: Patch) => {
      const { error } = await supabase.from('wash_formulas').update(patch).eq('id', formula.id);
      if (error) throw error;
    },
    onSuccess: (_r, patch) => {
      onClose();
      onStatus(
        true,
        patch.active === false
          ? t('setup.formulas.retired', { name: label })
          : patch.active === true
            ? t('setup.machines.reactivated', { name: label })
            : t('setup.savedNamed', {
                name: t('washroom.formulaOnly', { no: patch.external_no ?? formula.external_no }),
              }),
      );
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => invalidateSetup(qc),
  });

  function onSave(e: FormEvent) {
    e.preventDefault();
    const row = readFields(no, name, minutes);
    if (typeof row === 'string') return onStatus(false, t(row));
    const patch: Patch = {};
    if (row.external_no !== formula.external_no) patch.external_no = row.external_no;
    if (row.name !== formula.name) patch.name = row.name;
    if (row.cycle_minutes !== formula.cycle_minutes) patch.cycle_minutes = row.cycle_minutes;
    if (Object.keys(patch).length === 0) return onClose();
    save.mutate(patch);
  }

  return (
    <form onSubmit={onSave} noValidate className="setup-editor" aria-labelledby={`${idBase}-t`}>
      <h3 id={`${idBase}-t`} className="setup-editor-title">
        {t('setup.editNamed', { name: label })}
      </h3>
      <FormulaFields
        idBase={idBase}
        no={no}
        name={name}
        minutes={minutes}
        setNo={setNo}
        setName={setName}
        setMinutes={setMinutes}
      />
      <div className="actions">
        <button type="submit" disabled={save.isPending}>
          {t('setup.save')}
        </button>
        <button type="button" className="secondary" onClick={onClose}>
          {t('common.cancel')}
        </button>
        {formula.active ? (
          <button
            type="button"
            className="danger"
            disabled={save.isPending || usedBy > 0}
            aria-describedby={usedBy > 0 ? `${idBase}-inuse` : undefined}
            onClick={() => save.mutate({ active: false })}
          >
            {t('setup.formulas.retire')}
          </button>
        ) : (
          <button
            type="button"
            className="secondary"
            disabled={save.isPending}
            onClick={() => save.mutate({ active: true })}
          >
            {t('setup.reactivate')}
          </button>
        )}
      </div>
      {formula.active && usedBy > 0 && (
        <p className="hint" id={`${idBase}-inuse`}>
          {t('setup.formulas.inUseHint', { count: usedBy })}
        </p>
      )}
      <MoreInfo>{t('setup.formulas.retireHint')}</MoreInfo>
    </form>
  );
}

function AddFormula({
  plant,
  onClose,
  onStatus,
}: {
  plant: OwnerPlant;
  onClose: () => void;
  onStatus: OnStatus;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [no, setNo] = useState('');
  const [name, setName] = useState('');
  const [minutes, setMinutes] = useState('');
  const add = useMutation({
    mutationFn: async (row: {
      external_no: string;
      name: string | null;
      cycle_minutes: number | null;
    }) => {
      const { error } = await supabase
        .from('wash_formulas')
        .insert({ org_id: plant.org_id, plant_id: plant.id, ...row });
      if (error) throw error;
      return row.external_no;
    },
    onSuccess: (n) => {
      onClose();
      onStatus(true, t('setup.machines.added', { name: t('washroom.formulaOnly', { no: n }) }));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => invalidateSetup(qc),
  });
  return (
    <section className="card setup-add" aria-labelledby="add-formula">
      <h2 id="add-formula">{t('setup.formulas.addTitle')}</h2>
      <form
        noValidate
        onSubmit={(e) => {
          e.preventDefault();
          const row = readFields(no, name, minutes);
          if (typeof row === 'string') return onStatus(false, t(row));
          add.mutate(row);
        }}
      >
        <FormulaFields
          idBase="new-formula"
          no={no}
          name={name}
          minutes={minutes}
          setNo={setNo}
          setName={setName}
          setMinutes={setMinutes}
        />
        <div className="actions">
          <button type="submit" disabled={add.isPending}>
            {t('setup.formulas.add')}
          </button>
          <button type="button" className="secondary" onClick={onClose}>
            {t('common.cancel')}
          </button>
        </div>
      </form>
    </section>
  );
}

export function SetupFormulasPage() {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const formulas = useSetupFormulas(plant?.id);
  const groups = useSetupWashGroups(plant?.id);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.formulas.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }
  const onStatus: OnStatus = (ok, text) => setMessage({ ok, text });
  const activeGroups = (groups.data ?? []).filter((g) => g.active);
  const usedBy = (id: string) => activeGroups.filter((g) => g.wash_formula_id === id);
  const rows = [...(formulas.data ?? [])].sort(
    (a, b) => Number(b.active) - Number(a.active) || byFormulaNo(a, b),
  );

  return (
    <main className="form-page setup-wide">
      <div className="setup-title">
        <h1>{t('setup.formulas.title')}</h1>
        {!adding && (
          <button
            type="button"
            onClick={() => {
              setAdding(true);
              setOpenId(null);
            }}
          >
            {t('setup.formulas.addButton')}
          </button>
        )}
      </div>
      <p className="hint">{t('setup.formulas.intro')}</p>
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {adding && <AddFormula plant={plant} onClose={() => setAdding(false)} onStatus={onStatus} />}
      {formulas.isError && <p className="error">{t(setupErrorKey(formulas.error))}</p>}
      {formulas.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : rows.length === 0 ? (
        <p className="hint">{t('setup.formulas.none')}</p>
      ) : (
        <table className="setup-table" aria-label={t('setup.formulas.title')}>
          <thead>
            <tr>
              <th scope="col">{t('setup.formulas.number')}</th>
              <th scope="col">{t('setup.formulas.name')}</th>
              <th scope="col">{t('setup.formulas.minutes')}</th>
              <th scope="col">{t('setup.formulas.groups')}</th>
              <th scope="col">{t('setup.active')}</th>
              <th scope="col">
                <span className="visually-hidden">{t('setup.edit')}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((f) => {
              const open = openId === f.id;
              const used = usedBy(f.id);
              const label = t('washroom.formulaOnly', { no: f.external_no });
              return (
                <Fragment key={f.id}>
                  <tr className={f.active ? undefined : 'inactive'}>
                    <th scope="row" className="setup-cell-name">
                      <span className="head">{label}</span>
                    </th>
                    <td
                      data-label={t('setup.formulas.name')}
                      className={f.name ? undefined : 'setup-na'}
                    >
                      {f.name ?? '—'}
                    </td>
                    <td data-label={t('setup.formulas.minutes')} className="mono">
                      {f.cycle_minutes === null ? (
                        <span className="setup-missing">
                          <span aria-hidden="true">⚠ </span>
                          {t('setup.formulas.noMinutes')}
                        </span>
                      ) : (
                        t('setup.formulas.minutesValue', { count: f.cycle_minutes })
                      )}
                    </td>
                    <td data-label={t('setup.formulas.groups')}>
                      {used.length === 0
                        ? '—'
                        : used.map((g) => localized(g.name, g.name_i18n)).join(', ')}
                    </td>
                    <td
                      data-label={t('setup.active')}
                      className={f.active ? 'setup-na' : undefined}
                    >
                      {f.active ? (
                        <span className="setup-yes">✓ {t('setup.yes')}</span>
                      ) : (
                        <span className="badge setup-off">{t('setup.formulas.retiredBadge')}</span>
                      )}
                    </td>
                    <td className="setup-cell-action">
                      <button
                        type="button"
                        className="secondary"
                        aria-expanded={open}
                        aria-label={`${open ? t('setup.close') : t('setup.edit')} ${label}`}
                        onClick={() => {
                          setOpenId(open ? null : f.id);
                          setAdding(false);
                        }}
                      >
                        {open ? t('setup.close') : t('setup.edit')}
                      </button>
                    </td>
                  </tr>
                  {open && (
                    <tr className="setup-editor-row">
                      <td colSpan={6}>
                        <FormulaEditor
                          formula={f}
                          usedBy={used.length}
                          onClose={() => setOpenId(null)}
                          onStatus={onStatus}
                        />
                      </td>
                    </tr>
                  )}
                </Fragment>
              );
            })}
          </tbody>
        </table>
      )}
    </main>
  );
}
