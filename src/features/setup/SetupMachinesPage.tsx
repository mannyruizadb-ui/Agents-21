import { Fragment, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useLocalNames } from '../../lib/seededNames';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants, type OwnerPlant } from '../admin/useOwnerPlants';
import { useAreas, useMachineStatus, type AreaRow } from '../washroom/washroomData';
import { IconMachineDown, IconReady } from '../washroom/Icons';
import { MoreInfo } from '../../lib/MoreInfo';
import { cleanName, setupErrorKey } from './setupErrors';
import {
  invalidateSetup,
  useSetupLanguages,
  useSetupMachines,
  type MachineKind,
  type SetupMachine,
} from './setupData';
import { fromNameI18n, numText, parseLoadFactor, toNameI18n } from './setupForm';
import { NameFields } from './NameFields';
import '../../lib/forms.css';
import './setup.css';

// Setup → Machines (owner 2026-11-05; table rework, review 2026-11-09 item 8): one compact table
// Name | Kind | Area | Status | Load factor | Active, edited in place (the editor opens under the
// row), "+ Add machine" opens the add form. RLS: insert/update owner only. Kind and area are fixed
// once a machine has history (app.guard_setup_edit). No deletes: deactivate. Every read waits for
// the plant id (no `plant_id=eq.` 400). Phone: each row stacks as a small card with labels.

const KINDS: readonly MachineKind[] = [
  'washer',
  'dryer',
  'ironer',
  'folder',
  'wrapper',
  'utility',
  'other',
];

type Patch = Partial<
  Pick<SetupMachine, 'name' | 'kind' | 'area_id' | 'active' | 'load_factor'> & {
    name_i18n: Record<string, string>;
  }
>;
type OnStatus = (ok: boolean, text: string) => void;

/** Has the machine any history? Then its kind and area can't change. */
function useHasHistory(machineId: string, enabled: boolean) {
  return useQuery({
    queryKey: ['machine-history', machineId],
    enabled,
    queryFn: async (): Promise<boolean> => {
      const [cycles, queue] = await Promise.all([
        supabase
          .from('washer_cycles')
          .select('id', { count: 'exact', head: true })
          .eq('machine_id', machineId),
        supabase
          .from('queue_items')
          .select('id', { count: 'exact', head: true })
          .eq('assigned_machine_id', machineId),
      ]);
      if (cycles.error) throw cycles.error;
      if (queue.error) throw queue.error;
      return (cycles.count ?? 0) + (queue.count ?? 0) > 0;
    },
  });
}

function KindSelect({
  id,
  value,
  onChange,
  disabled,
}: {
  id: string;
  value: MachineKind;
  onChange: (k: MachineKind) => void;
  disabled?: boolean;
}) {
  const { t } = useTranslation();
  return (
    <select
      id={id}
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value as MachineKind)}
    >
      {KINDS.map((k) => (
        <option key={k} value={k}>
          {t(`setup.kinds.${k}`)}
        </option>
      ))}
    </select>
  );
}

function AreaSelect({
  id,
  areas,
  value,
  onChange,
  disabled,
}: {
  id: string;
  areas: AreaRow[];
  value: string;
  onChange: (a: string) => void;
  disabled?: boolean;
}) {
  const names = useLocalNames();
  return (
    <select id={id} value={value} disabled={disabled} onChange={(e) => onChange(e.target.value)}>
      {areas.map((a) => (
        <option key={a.id} value={a.id}>
          {names.area(a.name)}
        </option>
      ))}
    </select>
  );
}

function LoadFactorField({
  id,
  value,
  onChange,
}: {
  id: string;
  value: string;
  onChange: (v: string) => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="field">
      <label htmlFor={id}>{t('setup.machines.loadFactor')}</label>
      <input
        id={id}
        inputMode="decimal"
        value={value}
        autoComplete="off"
        aria-describedby={`${id}-hint`}
        onChange={(e) => onChange(e.target.value)}
      />
      <p className="hint" id={`${id}-hint`}>
        {t('setup.machines.loadFactorHint')}
      </p>
    </div>
  );
}

/** The editor under a row: names, kind, area, load factor (washers), deactivate. */
function MachineEditor({
  machine,
  areas,
  defaultLang,
  langs,
  onClose,
  onStatus,
}: {
  machine: SetupMachine;
  areas: AreaRow[];
  defaultLang: string;
  langs: string[];
  onClose: () => void;
  onStatus: OnStatus;
}) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const qc = useQueryClient();
  const [name, setName] = useState(machine.name);
  const [i18n, setI18n] = useState(() => fromNameI18n(machine.name_i18n, langs));
  const [kind, setKind] = useState<MachineKind>(machine.kind);
  const [areaId, setAreaId] = useState(machine.area_id);
  const [factor, setFactor] = useState(numText(machine.load_factor));
  const history = useHasHistory(machine.id, true);
  const locked = history.data !== false; // locked until we know there is no history
  const idBase = `m-${machine.id}`;
  const shown = names.machine(machine.name, machine.name_i18n);

  const save = useMutation({
    mutationFn: async (patch: Patch) => {
      const { error } = await supabase.from('machines').update(patch).eq('id', machine.id);
      if (error) throw error;
    },
    onSuccess: (_r, patch) => {
      onClose();
      onStatus(
        true,
        patch.active === false
          ? t('setup.machines.deactivated', { name: shown })
          : patch.active === true
            ? t('setup.machines.reactivated', { name: shown })
            : t('setup.savedNamed', { name: cleanName(name) ?? shown }),
      );
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => invalidateSetup(qc),
  });

  function onSave(e: FormEvent) {
    e.preventDefault();
    const clean = cleanName(name);
    if (!clean) return onStatus(false, t('setup.errors.name'));
    const map = toNameI18n(i18n, langs);
    if (!map) return onStatus(false, t('setup.errors.name'));
    const patch: Patch = {};
    if (clean !== machine.name) patch.name = clean;
    const before = fromNameI18n(machine.name_i18n, langs);
    if (langs.some((l) => (before[l] ?? '').trim() !== (i18n[l] ?? '').trim())) {
      // Keep the keys of languages not edited here (e.g. a language no longer enabled).
      const old =
        machine.name_i18n &&
        typeof machine.name_i18n === 'object' &&
        !Array.isArray(machine.name_i18n)
          ? (machine.name_i18n as Record<string, string>)
          : {};
      const merged: Record<string, string> = Object.fromEntries(
        Object.entries(old).filter(([k]) => !langs.includes(k)),
      );
      patch.name_i18n = { ...merged, ...map };
    }
    if (!locked && kind !== machine.kind) patch.kind = kind;
    if (!locked && areaId !== machine.area_id) patch.area_id = areaId;
    if (kind === 'washer') {
      const f = parseLoadFactor(factor);
      if (f === 'invalid') return onStatus(false, t('setup.errors.loadFactor'));
      if (f !== machine.load_factor) patch.load_factor = f;
    }
    if (Object.keys(patch).length === 0) return onClose();
    save.mutate(patch);
  }

  return (
    <form onSubmit={onSave} noValidate className="setup-editor" aria-labelledby={`${idBase}-title`}>
      <h3 id={`${idBase}-title`} className="setup-editor-title">
        {t('setup.editNamed', { name: shown })}
      </h3>
      <div className="setup-editor-grid">
        <NameFields
          idBase={idBase}
          defaultLang={defaultLang}
          langs={langs}
          name={name}
          names={i18n}
          onName={setName}
          onNames={setI18n}
        />
        <div className="field">
          <label htmlFor={`${idBase}-kind`}>{t('setup.machines.kind')}</label>
          <KindSelect id={`${idBase}-kind`} value={kind} onChange={setKind} disabled={locked} />
        </div>
        <div className="field">
          <label htmlFor={`${idBase}-area`}>{t('setup.machines.area')}</label>
          <AreaSelect
            id={`${idBase}-area`}
            areas={areas}
            value={areaId}
            onChange={setAreaId}
            disabled={locked}
          />
        </div>
        {kind === 'washer' && (
          <LoadFactorField id={`${idBase}-factor`} value={factor} onChange={setFactor} />
        )}
      </div>
      {history.isPending ? (
        <p className="hint">{t('common.loading')}</p>
      ) : (
        history.data && <p className="hint">{t('setup.machines.lockedHint')}</p>
      )}
      <div className="actions">
        <button type="submit" disabled={save.isPending}>
          {t('setup.save')}
        </button>
        <button type="button" className="secondary" onClick={onClose}>
          {t('common.cancel')}
        </button>
        {machine.active ? (
          <button
            type="button"
            className="danger"
            disabled={save.isPending}
            onClick={() => save.mutate({ active: false })}
          >
            {t('setup.deactivate')}
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
      {machine.active && <MoreInfo>{t('setup.machines.deactivateHint')}</MoreInfo>}
    </form>
  );
}

function AddMachine({
  plant,
  areas,
  defaultLang,
  langs,
  onClose,
  onStatus,
}: {
  plant: OwnerPlant;
  areas: AreaRow[];
  defaultLang: string;
  langs: string[];
  onClose: () => void;
  onStatus: OnStatus;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [name, setName] = useState('');
  const [i18n, setI18n] = useState<Record<string, string>>({});
  const [kind, setKind] = useState<MachineKind>('washer');
  const [areaId, setAreaId] = useState(areas[0]?.id ?? '');
  const [factor, setFactor] = useState('1');

  const add = useMutation({
    mutationFn: async (row: {
      name: string;
      name_i18n: Record<string, string>;
      load_factor: number;
    }) => {
      const { error } = await supabase.from('machines').insert({
        org_id: plant.org_id,
        plant_id: plant.id,
        area_id: areaId,
        kind,
        ...row,
      });
      if (error) throw error;
      return row.name;
    },
    onSuccess: (clean) => {
      onClose();
      onStatus(true, t('setup.machines.added', { name: clean }));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => invalidateSetup(qc),
  });

  return (
    <section className="card setup-add" aria-labelledby="add-machine">
      <h2 id="add-machine">{t('setup.machines.addTitle')}</h2>
      <form
        noValidate
        onSubmit={(e) => {
          e.preventDefault();
          const clean = cleanName(name);
          if (!clean) return onStatus(false, t('setup.errors.name'));
          const map = toNameI18n(i18n, langs);
          if (!map) return onStatus(false, t('setup.errors.name'));
          if (!areaId) return onStatus(false, t('setup.errors.area'));
          const f = kind === 'washer' ? parseLoadFactor(factor) : 1;
          if (f === 'invalid') return onStatus(false, t('setup.errors.loadFactor'));
          add.mutate({ name: clean, name_i18n: map, load_factor: f });
        }}
      >
        <div className="setup-editor-grid">
          <NameFields
            idBase="new-machine"
            defaultLang={defaultLang}
            langs={langs}
            name={name}
            names={i18n}
            onName={setName}
            onNames={setI18n}
          />
          <div className="field">
            <label htmlFor="new-machine-kind">{t('setup.machines.kind')}</label>
            <KindSelect id="new-machine-kind" value={kind} onChange={setKind} />
          </div>
          <div className="field">
            <label htmlFor="new-machine-area">{t('setup.machines.area')}</label>
            <AreaSelect id="new-machine-area" areas={areas} value={areaId} onChange={setAreaId} />
          </div>
          {kind === 'washer' && (
            <LoadFactorField id="new-machine-factor" value={factor} onChange={setFactor} />
          )}
        </div>
        <div className="actions">
          <button type="submit" disabled={add.isPending}>
            {t('setup.machines.add')}
          </button>
          <button type="button" className="secondary" onClick={onClose}>
            {t('common.cancel')}
          </button>
        </div>
      </form>
    </section>
  );
}

export function SetupMachinesPage() {
  const { t, i18n } = useTranslation();
  const names = useLocalNames();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const areas = useAreas();
  const plantAreas = (areas.data ?? []).filter((a) => a.plant_id === plant?.id);
  const machines = useSetupMachines(plant?.id);
  const status = useMachineStatus(plant?.id);
  const { defaultLang, langs } = useSetupLanguages(plant?.id);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.machines.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }

  const onStatus: OnStatus = (ok, text) => setMessage({ ok, text });
  const downIds = new Set(
    (status.data ?? []).filter((s) => s.status === 'down').map((s) => s.machine_id),
  );
  const areaName = new Map(plantAreas.map((a) => [a.id, names.area(a.name)]));
  const areaOrder = new Map(plantAreas.map((a, i) => [a.id, i]));
  const rows = [...(machines.data ?? [])].sort(
    (a, b) =>
      Number(b.active) - Number(a.active) ||
      (areaOrder.get(a.area_id) ?? 99) - (areaOrder.get(b.area_id) ?? 99) ||
      a.name.localeCompare(b.name, undefined, { numeric: true }),
  );
  const factorFmt = new Intl.NumberFormat(i18n.language, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });

  return (
    <main className="form-page setup-wide">
      <div className="setup-title">
        <h1>{t('setup.machines.title')}</h1>
        {!adding && plantAreas.length > 0 && (
          <button
            type="button"
            onClick={() => {
              setAdding(true);
              setOpenId(null);
            }}
          >
            {t('setup.machines.addButton')}
          </button>
        )}
      </div>
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {adding && (
        <AddMachine
          plant={plant}
          areas={plantAreas}
          defaultLang={defaultLang}
          langs={langs}
          onClose={() => setAdding(false)}
          onStatus={onStatus}
        />
      )}
      {machines.isError && <p className="error">{t(setupErrorKey(machines.error))}</p>}
      {machines.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : rows.length === 0 ? (
        <p className="hint">{t('setup.machines.noneAtAll')}</p>
      ) : (
        <table className="setup-table" aria-label={t('setup.machines.title')}>
          <thead>
            <tr>
              <th scope="col">{t('setup.machines.name')}</th>
              <th scope="col">{t('setup.machines.kind')}</th>
              <th scope="col">{t('setup.machines.area')}</th>
              <th scope="col">{t('setup.machines.status')}</th>
              <th scope="col">{t('setup.machines.loadFactor')}</th>
              <th scope="col">{t('setup.active')}</th>
              <th scope="col">
                <span className="visually-hidden">{t('setup.edit')}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((m) => {
              const shown = names.machine(m.name, m.name_i18n);
              const down = downIds.has(m.id);
              const open = openId === m.id;
              return (
                <Fragment key={m.id}>
                  <tr className={m.active ? undefined : 'inactive'}>
                    <th scope="row" className="setup-cell-name">
                      <span className="head">{shown}</span>
                      {shown !== m.name && (
                        <span className="setup-sub" lang={defaultLang}>
                          {m.name}
                        </span>
                      )}
                    </th>
                    <td data-label={t('setup.machines.kind')}>{t(`setup.kinds.${m.kind}`)}</td>
                    <td data-label={t('setup.machines.area')}>{areaName.get(m.area_id) ?? '—'}</td>
                    <td
                      data-label={t('setup.machines.status')}
                      className={m.active ? undefined : 'setup-na'}
                    >
                      {!m.active ? (
                        <span className="setup-status">—</span>
                      ) : down ? (
                        <span className="setup-status down">
                          <IconMachineDown /> {t('setup.machines.statusDown')}
                        </span>
                      ) : (
                        <span className="setup-status up">
                          <IconReady /> {t('setup.machines.statusUp')}
                        </span>
                      )}
                    </td>
                    <td
                      data-label={t('setup.machines.loadFactor')}
                      className={m.kind === 'washer' ? 'mono' : 'mono setup-na'}
                    >
                      {m.kind === 'washer' ? factorFmt.format(m.load_factor) : '—'}
                    </td>
                    <td
                      data-label={t('setup.active')}
                      className={m.active ? 'setup-na' : undefined}
                    >
                      {m.active ? (
                        <span className="setup-yes">✓ {t('setup.yes')}</span>
                      ) : (
                        <span className="badge setup-off">{t('setup.inactive')}</span>
                      )}
                    </td>
                    <td className="setup-cell-action">
                      <button
                        type="button"
                        className="secondary"
                        aria-expanded={open}
                        aria-label={`${open ? t('setup.close') : t('setup.edit')} ${shown}`}
                        onClick={() => {
                          setOpenId(open ? null : m.id);
                          setAdding(false);
                        }}
                      >
                        {open ? t('setup.close') : t('setup.edit')}
                      </button>
                    </td>
                  </tr>
                  {open && (
                    <tr className="setup-editor-row">
                      <td colSpan={7}>
                        <MachineEditor
                          machine={m}
                          areas={plantAreas}
                          defaultLang={defaultLang}
                          langs={langs}
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
