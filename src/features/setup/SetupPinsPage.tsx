import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { availableLocales } from '../../lib/i18n';
import { supabase } from '../../lib/supabase';
import { useShiftOptions } from '../admin/useManagerSchedule';
import { useOwnerPlants, type OwnerPlant } from '../admin/useOwnerPlants';
import { unwrap } from '../washroom/rpcError';
import { pinErrorKey, pinProblem } from './pinRules';
import { cleanName, setupErrorKey } from './setupErrors';
import '../../lib/forms.css';
import './setup.css';

// Setup → Entry PINs (owner 2026-11-06: "how do I create PINs? … editable in the app"). The people who
// confirm entries (estimates, finished goods) with their name + a 4-digit PIN (PRD A8). PINs are
// attribution, not security. The owner adds a person, sets or resets their PIN, edits name / language
// / home shift and deactivates (never deletes: history points at them). The PIN is sent once to
// set_staff_pin (bcrypt on the server) and never read back; the list only shows "PIN set" yes/no.
// Writes go through RLS (owner, or a manager the owner allowed to manage staff).

const LANGS = ['en', ...availableLocales.filter((l) => l !== 'en').sort()];

interface StaffRow {
  id: string;
  display_name: string;
  language: string;
  home_shift_id: string | null;
  has_pin: boolean;
  active: boolean;
}

const staffKey = (plantId: string) => ['entry-staff-admin', plantId] as const;

function useStaffList(plantId: string | undefined) {
  return useQuery({
    queryKey: staffKey(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<StaffRow[]> =>
      (unwrap(
        await supabase
          .from('entry_staff_public')
          .select('id, display_name, language, home_shift_id, has_pin, active')
          .eq('plant_id', plantId ?? '')
          .order('active', { ascending: false })
          .order('display_name'),
      ) ?? []) as StaffRow[],
  });
}

function PinFields({
  idBase,
  onSubmit,
  busy,
  submitLabel,
}: {
  idBase: string;
  onSubmit: (pin: string) => void;
  busy: boolean;
  submitLabel: string;
}) {
  const { t } = useTranslation();
  const [pin, setPin] = useState('');
  const [again, setAgain] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  return (
    <form
      noValidate
      onSubmit={(e) => {
        e.preventDefault();
        const p = pinProblem(pin, again);
        if (p) return setProblem(t(`setup.pins.errors.${p}`));
        setProblem(null);
        onSubmit(pin);
        setPin('');
        setAgain('');
      }}
    >
      <div className="field">
        <label htmlFor={`${idBase}-pin`}>{t('setup.pins.pin')}</label>
        <input
          id={`${idBase}-pin`}
          type="password"
          inputMode="numeric"
          autoComplete="off"
          maxLength={4}
          value={pin}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
          aria-describedby={`${idBase}-pin-hint`}
        />
        <p id={`${idBase}-pin-hint`} className="hint">
          {t('setup.pins.pinHint')}
        </p>
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-again`}>{t('setup.pins.pinAgain')}</label>
        <input
          id={`${idBase}-again`}
          type="password"
          inputMode="numeric"
          autoComplete="off"
          maxLength={4}
          value={again}
          onChange={(e) => setAgain(e.target.value.replace(/\D/g, ''))}
        />
      </div>
      {problem && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
      <button type="submit" disabled={busy}>
        {submitLabel}
      </button>
    </form>
  );
}

function StaffItem({
  plant,
  person,
  shiftName,
  shifts,
  onStatus,
}: {
  plant: OwnerPlant;
  person: StaffRow;
  shiftName: string;
  shifts: { id: string; label: string }[];
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [mode, setMode] = useState<'view' | 'edit' | 'pin'>('view');
  const [name, setName] = useState(person.display_name);
  const [lang, setLang] = useState(person.language);
  const [shift, setShift] = useState(person.home_shift_id ?? '');
  const refresh = () => {
    void qc.invalidateQueries({ queryKey: staffKey(plant.id) });
    void qc.invalidateQueries({ queryKey: ['entry-staff'] });
  };

  const save = useMutation({
    mutationFn: async (patch: Partial<Omit<StaffRow, 'id' | 'has_pin'>>) => {
      const { error } = await supabase.from('entry_staff').update(patch).eq('id', person.id);
      if (error) throw error;
    },
    onSuccess: () => {
      setMode('view');
      onStatus(true, t('setup.saved'));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: refresh,
  });
  const setPin = useMutation({
    mutationFn: async (pin: string) =>
      unwrap(await supabase.rpc('set_staff_pin', { p_staff_id: person.id, p_pin: pin })),
    onSuccess: () => {
      setMode('view');
      onStatus(true, t('setup.pins.pinSaved', { name: person.display_name }));
    },
    onError: (e) => onStatus(false, t(pinErrorKey(e))),
    onSettled: refresh,
  });
  const busy = save.isPending || setPin.isPending;

  return (
    <li className={person.active ? 'setup-row' : 'setup-row inactive'}>
      <div className="setup-row-head">
        <p className="setup-row-text">
          <strong className="head">{person.display_name}</strong>
          <span className="setup-kind">
            {!person.active && <span className="badge setup-off">{t('setup.inactive')}</span>}
            {person.has_pin ? t('setup.pins.hasPin') : t('setup.pins.noPin')}
            {shiftName && ` · ${shiftName}`}
          </span>
        </p>
        {mode === 'view' && (
          <span className="setup-row-actions">
            {person.active && (
              <button type="button" className="secondary" onClick={() => setMode('pin')}>
                {person.has_pin ? t('setup.pins.resetPin') : t('setup.pins.setPin')}
              </button>
            )}
            <button type="button" className="secondary" onClick={() => setMode('edit')}>
              {t('setup.edit')}
            </button>
          </span>
        )}
      </div>
      {mode === 'pin' && (
        <div className="setup-editor">
          <PinFields
            idBase={`pin-${person.id}`}
            busy={busy}
            submitLabel={t('setup.pins.savePin')}
            onSubmit={(pin) => setPin.mutate(pin)}
          />
          <button type="button" className="secondary" onClick={() => setMode('view')}>
            {t('common.cancel')}
          </button>
        </div>
      )}
      {mode === 'edit' && (
        <div className="setup-editor">
          <div className="field">
            <label htmlFor={`name-${person.id}`}>{t('setup.pins.name')}</label>
            <input
              id={`name-${person.id}`}
              value={name}
              maxLength={60}
              autoComplete="off"
              onChange={(e) => setName(e.target.value)}
            />
          </div>
          <LanguageAndShift
            idBase={`p-${person.id}`}
            lang={lang}
            setLang={setLang}
            shift={shift}
            setShift={setShift}
            shifts={shifts}
          />
          <div className="actions">
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                const n = cleanName(name);
                if (!n) return onStatus(false, t('setup.pins.errors.name'));
                save.mutate({ display_name: n, language: lang, home_shift_id: shift || null });
              }}
            >
              {t('setup.save')}
            </button>
            <button type="button" className="secondary" onClick={() => setMode('view')}>
              {t('common.cancel')}
            </button>
            {person.active ? (
              <button
                type="button"
                className="danger"
                disabled={busy}
                onClick={() => save.mutate({ active: false })}
              >
                {t('setup.deactivate')}
              </button>
            ) : (
              <button
                type="button"
                className="secondary"
                disabled={busy}
                onClick={() => save.mutate({ active: true })}
              >
                {t('setup.reactivate')}
              </button>
            )}
          </div>
          {person.active && <p className="hint">{t('setup.pins.deactivateHint')}</p>}
        </div>
      )}
    </li>
  );
}

function LanguageAndShift({
  idBase,
  lang,
  setLang,
  shift,
  setShift,
  shifts,
}: {
  idBase: string;
  lang: string;
  setLang: (v: string) => void;
  shift: string;
  setShift: (v: string) => void;
  shifts: { id: string; label: string }[];
}) {
  const { t } = useTranslation();
  return (
    <>
      <div className="field">
        <label htmlFor={`${idBase}-lang`}>{t('setup.pins.language')}</label>
        <select id={`${idBase}-lang`} value={lang} onChange={(e) => setLang(e.target.value)}>
          {LANGS.map((l) => (
            <option key={l} value={l}>
              {t(`setup.languages.${l}`, { defaultValue: l })}
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-shift`}>{t('setup.pins.homeShift')}</label>
        <select id={`${idBase}-shift`} value={shift} onChange={(e) => setShift(e.target.value)}>
          <option value="">{t('setup.pins.noShift')}</option>
          {shifts.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
        <p className="hint">{t('setup.pins.homeShiftHint')}</p>
      </div>
    </>
  );
}

function AddPerson({
  plant,
  shifts,
  onStatus,
}: {
  plant: OwnerPlant;
  shifts: { id: string; label: string }[];
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [name, setName] = useState('');
  const [lang, setLang] = useState('es');
  const [shift, setShift] = useState('');
  const [problem, setProblem] = useState<string | null>(null);

  const add = useMutation({
    mutationFn: async (v: { name: string; pin: string }) => {
      const { data, error } = await supabase
        .from('entry_staff')
        .insert({
          org_id: plant.org_id,
          plant_id: plant.id,
          display_name: v.name,
          language: lang,
          home_shift_id: shift || null,
        })
        .select('id')
        .single();
      if (error) throw error;
      // The person exists even if the PIN is refused (too easy / in use): set it again from the list.
      const pin = await supabase.rpc('set_staff_pin', { p_staff_id: data.id, p_pin: v.pin });
      if (pin.error) return { name: v.name, pinError: pin.error as unknown };
      return { name: v.name, pinError: null };
    },
    onSuccess: (r) => {
      setName('');
      setShift('');
      if (r.pinError) {
        onStatus(
          false,
          `${t('setup.pins.addedNoPin', { name: r.name })} ${t(pinErrorKey(r.pinError))}`,
        );
      } else {
        onStatus(true, t('setup.pins.added', { name: r.name }));
      }
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: staffKey(plant.id) });
      void qc.invalidateQueries({ queryKey: ['entry-staff'] });
    },
  });

  return (
    <section className="card" aria-labelledby="add-person">
      <h2 id="add-person">{t('setup.pins.addTitle')}</h2>
      <div className="field">
        <label htmlFor="new-person-name">{t('setup.pins.name')}</label>
        <input
          id="new-person-name"
          value={name}
          maxLength={60}
          autoComplete="off"
          onChange={(e) => setName(e.target.value)}
        />
      </div>
      <LanguageAndShift
        idBase="new-person"
        lang={lang}
        setLang={setLang}
        shift={shift}
        setShift={setShift}
        shifts={shifts}
      />
      {problem && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
      <PinFields
        idBase="new-person"
        busy={add.isPending}
        submitLabel={t('setup.pins.add')}
        onSubmit={(pin) => {
          const n = cleanName(name);
          if (!n) return setProblem(t('setup.pins.errors.name'));
          setProblem(null);
          add.mutate({ name: n, pin });
        }}
      />
    </section>
  );
}

export function SetupPinsPage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const staff = useStaffList(plant?.id);
  const shiftOptions = useShiftOptions(plant?.id);
  const [status, setStatus] = useState<{ ok: boolean; text: string } | null>(null);
  const onStatus = (ok: boolean, text: string) => setStatus({ ok, text });
  const shifts = (shiftOptions.data ?? []).map((s) => ({
    id: s.id,
    label: `${s.area_name} · ${s.name}`,
  }));
  const shiftLabel = (id: string | null) => shifts.find((s) => s.id === id)?.label ?? '';

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.pins.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }

  const list = staff.data ?? [];
  return (
    <main className="form-page">
      <h1>{t('setup.pins.title')}</h1>
      <p className="hint">{t('setup.pins.intro')}</p>
      <div role="status" aria-live="polite">
        {status && <p className={status.ok ? 'notice' : 'error'}>{status.text}</p>}
      </div>
      {staff.isError && <p className="error">{t(setupErrorKey(staff.error))}</p>}
      {staff.isSuccess && list.length === 0 && <p className="notice">{t('setup.pins.none')}</p>}
      <ul className="setup-list">
        {list.map((p) => (
          <StaffItem
            key={p.id}
            plant={plant}
            person={p}
            shiftName={shiftLabel(p.home_shift_id)}
            shifts={shifts}
            onStatus={onStatus}
          />
        ))}
      </ul>
      <AddPerson plant={plant} shifts={shifts} onStatus={onStatus} />
    </main>
  );
}
