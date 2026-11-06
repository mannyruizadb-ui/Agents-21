import { useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useLocalNames } from '../../lib/seededNames';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants, type OwnerPlant } from '../admin/useOwnerPlants';
import { useAreas, type AreaRow } from '../washroom/washroomData';
import { cleanName, setupErrorKey } from './setupErrors';
import '../../lib/forms.css';
import './setup.css';

// Setup → Machines (owner 2026-11-05): the owner adds, renames, changes kind/area and deactivates
// machines. RLS: insert/update owner only. Kind and area are fixed once a machine has history (washer
// cycles or queue items; app.guard_setup_edit enforces it). No deletes: deactivate.

type Machine = Pick<
  Database['public']['Tables']['machines']['Row'],
  'id' | 'name' | 'kind' | 'area_id' | 'active'
>;
type Kind = Machine['kind'];
const KINDS: readonly Kind[] = [
  'washer',
  'dryer',
  'ironer',
  'folder',
  'wrapper',
  'utility',
  'other',
];

function useAllMachines(plantId: string) {
  return useQuery({
    queryKey: ['setup-machines', plantId],
    queryFn: async (): Promise<Machine[]> => {
      const { data, error } = await supabase
        .from('machines')
        .select('id, name, kind, area_id, active')
        .eq('plant_id', plantId)
        .order('name');
      if (error) throw error;
      return data ?? [];
    },
  });
}

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
  value: Kind;
  onChange: (k: Kind) => void;
  disabled?: boolean;
}) {
  const { t } = useTranslation();
  return (
    <select
      id={id}
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value as Kind)}
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

function MachineRow({
  machine,
  areas,
  onStatus,
}: {
  machine: Machine;
  areas: AreaRow[];
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t } = useTranslation();
  const names = useLocalNames();
  const qc = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(machine.name);
  const [kind, setKind] = useState<Kind>(machine.kind);
  const [areaId, setAreaId] = useState(machine.area_id);
  const history = useHasHistory(machine.id, editing);
  const locked = history.data !== false; // locked until we know there is no history
  const idBase = `m-${machine.id}`;

  const save = useMutation({
    mutationFn: async (patch: Partial<Pick<Machine, 'name' | 'kind' | 'area_id' | 'active'>>) => {
      const { error } = await supabase.from('machines').update(patch).eq('id', machine.id);
      if (error) throw error;
    },
    onSuccess: (_r, patch) => {
      setEditing(false);
      onStatus(
        true,
        patch.active === false
          ? t('setup.machines.deactivated', { name: names.machine(machine.name) })
          : patch.active === true
            ? t('setup.machines.reactivated', { name: names.machine(machine.name) })
            : t('setup.saved'),
      );
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: ['setup-machines'] });
      void qc.invalidateQueries({ queryKey: ['machine-status'] });
      void qc.invalidateQueries({ queryKey: ['washroom-board'] });
      void qc.invalidateQueries({ queryKey: ['washers'] });
    },
  });

  function onSave(e: FormEvent) {
    e.preventDefault();
    const clean = cleanName(name);
    if (!clean) return onStatus(false, t('setup.errors.name'));
    const patch: Partial<Pick<Machine, 'name' | 'kind' | 'area_id'>> = {};
    if (clean !== machine.name) patch.name = clean;
    if (!locked && kind !== machine.kind) patch.kind = kind;
    if (!locked && areaId !== machine.area_id) patch.area_id = areaId;
    if (Object.keys(patch).length === 0) return setEditing(false);
    save.mutate(patch);
  }

  return (
    <li className={machine.active ? 'setup-row' : 'setup-row inactive'}>
      <div className="setup-row-head">
        <p className="setup-row-text">
          <strong className="head">{names.machine(machine.name)}</strong>
          <span className="setup-kind">
            {t(`setup.kinds.${machine.kind}`)}
            {!machine.active && <span className="badge setup-off">{t('setup.inactive')}</span>}
          </span>
        </p>
        {!editing && (
          <button type="button" className="secondary" onClick={() => setEditing(true)}>
            {t('setup.edit')}
          </button>
        )}
      </div>
      {editing && (
        <form onSubmit={onSave} noValidate className="setup-editor">
          <div className="field">
            <label htmlFor={`${idBase}-name`}>{t('setup.machines.name')}</label>
            <input
              id={`${idBase}-name`}
              value={name}
              maxLength={60}
              autoComplete="off"
              onChange={(e) => setName(e.target.value)}
            />
          </div>
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
          <p className="hint">
            {history.isPending
              ? t('common.loading')
              : history.data
                ? t('setup.machines.lockedHint')
                : t('setup.machines.unlockedHint')}
          </p>
          <div className="actions">
            <button type="submit" disabled={save.isPending}>
              {t('setup.save')}
            </button>
            <button
              type="button"
              className="secondary"
              onClick={() => {
                setEditing(false);
                setName(machine.name);
                setKind(machine.kind);
                setAreaId(machine.area_id);
              }}
            >
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
          {machine.active && <p className="hint">{t('setup.machines.deactivateHint')}</p>}
        </form>
      )}
    </li>
  );
}

function AddMachine({
  plant,
  areas,
  onStatus,
}: {
  plant: OwnerPlant;
  areas: AreaRow[];
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [name, setName] = useState('');
  const [kind, setKind] = useState<Kind>('washer');
  const [areaId, setAreaId] = useState(areas[0]?.id ?? '');

  const add = useMutation({
    mutationFn: async (clean: string) => {
      const { error } = await supabase.from('machines').insert({
        org_id: plant.org_id,
        plant_id: plant.id,
        area_id: areaId,
        name: clean,
        kind,
      });
      if (error) throw error;
      return clean;
    },
    onSuccess: (clean) => {
      setName('');
      onStatus(true, t('setup.machines.added', { name: clean }));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => void qc.invalidateQueries({ queryKey: ['setup-machines'] }),
  });

  return (
    <section className="card" aria-labelledby="add-machine">
      <h2 id="add-machine">{t('setup.machines.addTitle')}</h2>
      <form
        noValidate
        onSubmit={(e) => {
          e.preventDefault();
          const clean = cleanName(name);
          if (!clean) return onStatus(false, t('setup.errors.name'));
          if (!areaId) return onStatus(false, t('setup.errors.area'));
          add.mutate(clean);
        }}
      >
        <div className="field">
          <label htmlFor="new-machine-name">{t('setup.machines.name')}</label>
          <input
            id="new-machine-name"
            value={name}
            maxLength={60}
            autoComplete="off"
            onChange={(e) => setName(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor="new-machine-kind">{t('setup.machines.kind')}</label>
          <KindSelect id="new-machine-kind" value={kind} onChange={setKind} />
        </div>
        <div className="field">
          <label htmlFor="new-machine-area">{t('setup.machines.area')}</label>
          <AreaSelect id="new-machine-area" areas={areas} value={areaId} onChange={setAreaId} />
        </div>
        <button type="submit" disabled={add.isPending}>
          {t('setup.machines.add')}
        </button>
      </form>
    </section>
  );
}

export function SetupMachinesPage() {
  const { t } = useTranslation();
  const names = useLocalNames();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const areas = useAreas();
  const plantAreas = (areas.data ?? []).filter((a) => a.plant_id === plant?.id);
  const machines = useAllMachines(plant?.id ?? '');
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.machines.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }

  const onStatus = (ok: boolean, text: string) => setStatus({ ok, text });

  return (
    <main className="form-page">
      <h1>{t('setup.machines.title')}</h1>
      <p className="hint">{t('setup.machines.intro')}</p>
      <div role="status" aria-live="polite">
        {status && <p className={status.ok ? 'notice' : 'error'}>{status.text}</p>}
      </div>
      {machines.isError && <p className="error">{t(setupErrorKey(machines.error))}</p>}
      {plantAreas.map((area) => {
        const list = (machines.data ?? []).filter((m) => m.area_id === area.id);
        return (
          <section key={area.id} aria-labelledby={`area-${area.id}`}>
            <h2 id={`area-${area.id}`}>{names.area(area.name)}</h2>
            {list.length === 0 ? (
              <p className="hint">{t('setup.machines.none')}</p>
            ) : (
              <ul className="setup-list">
                {list.map((m) => (
                  <MachineRow key={m.id} machine={m} areas={plantAreas} onStatus={onStatus} />
                ))}
              </ul>
            )}
          </section>
        );
      })}
      {plantAreas.length > 0 && <AddMachine plant={plant} areas={plantAreas} onStatus={onStatus} />}
    </main>
  );
}
