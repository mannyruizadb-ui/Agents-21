import { useState, type FormEvent, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants, type OwnerPlant } from '../admin/useOwnerPlants';
import { safeColor, useLocalizedName } from '../washroom/localizedName';
import { IconWarning } from '../washroom/Icons';
import { MoreInfo } from '../../lib/MoreInfo';
import { useCustomers } from '../deliveries/deliveriesData';
import { CategoryChips } from '../estimates/CategoryChips';
import {
  CATEGORIES,
  chipCounts,
  chipsFor,
  effectiveChip,
  inChip,
  narrowCategory,
  type Category,
  type Chip,
} from '../estimates/categories';
import { cleanName, setupErrorKey } from './setupErrors';
import {
  byFormulaNo,
  invalidateSetup,
  useSetupFormulas,
  useSetupLanguages,
  useSetupWashGroups,
  type SetupFormula,
  type SetupWashGroup,
} from './setupData';
import {
  binFactorMissing,
  factorProblems,
  fromNameI18n,
  nextSortOrder,
  numText,
  parseLoadsPer,
  toNameI18n,
  type EstimateUnit,
} from './setupForm';
import { NameFields } from './NameFields';
import '../../lib/forms.css';
import '../estimates/estimates.css';
import './setup.css';

// Setup → Wash groups (owner 2026-11-09, review item 8: "the root cause of the missing numbers").
// Our groups | each customer's (AA Linen), category chips (the estimates' CategoryChips), grouped
// by category. Each group: names per language, colour, category, formula (with its minutes), loads
// per basket and per bin, which containers estimates may use, the default unit, active. A visible
// "missing factor" warning where a blank factor makes loads unknown (customer groups: bins).
// Direct table writes through RLS + column grants + guards (owner only for customer groups and load
// factors); setupErrorKey() turns refusals into words. No deletes: deactivate.

type OnStatus = (ok: boolean, text: string) => void;
const UNITS: readonly EstimateUnit[] = ['load', 'basket', 'bin'];

interface Draft {
  name: string;
  names: Record<string, string>;
  color: string;
  category: Category;
  formulaId: string;
  perBasket: string;
  perBin: string;
  allowBasket: boolean;
  allowBin: boolean;
  unit: EstimateUnit;
}

function draftOf(g: SetupWashGroup | null, langs: string[], customer: boolean): Draft {
  return {
    name: g?.name ?? '',
    names: fromNameI18n(g?.name_i18n, langs),
    color: safeColor(g?.color_hex),
    category: narrowCategory(g?.category),
    formulaId: g?.wash_formula_id ?? '',
    perBasket: numText(g?.loads_per_basket),
    perBin: numText(g?.loads_per_bin),
    allowBasket: g?.allow_basket_estimates ?? false,
    allowBin: g?.allow_bin_estimates ?? customer,
    unit: g ? asUnit(g.default_estimate_unit) : customer ? 'bin' : 'load',
  };
}

function asUnit(u: string): EstimateUnit {
  return u === 'basket' || u === 'bin' ? u : 'load';
}

type Row = Pick<
  SetupWashGroup,
  | 'name'
  | 'color_hex'
  | 'category'
  | 'wash_formula_id'
  | 'loads_per_basket'
  | 'loads_per_bin'
  | 'allow_basket_estimates'
  | 'allow_bin_estimates'
  | 'default_estimate_unit'
> & { name_i18n: Record<string, string> };

/** Draft → row, or a message key. Mirrors the DB CHECKs; the DB stays the final validator. */
function readDraft(d: Draft, langs: string[]): Row | string {
  const name = cleanName(d.name);
  if (!name) return 'setup.errors.name';
  const map = toNameI18n(d.names, langs);
  if (!map) return 'setup.errors.name';
  if (!/^#[0-9A-Fa-f]{6}$/.test(d.color)) return 'setup.errors.invalid';
  const perBasket = parseLoadsPer(d.perBasket);
  const perBin = parseLoadsPer(d.perBin);
  if (perBasket === 'invalid' || perBin === 'invalid') return 'setup.errors.loadsPer';
  const row: Row = {
    name,
    name_i18n: map,
    color_hex: d.color.toUpperCase(),
    category: d.category,
    wash_formula_id: d.formulaId || null,
    loads_per_basket: perBasket,
    loads_per_bin: perBin,
    allow_basket_estimates: d.allowBasket,
    allow_bin_estimates: d.allowBin,
    default_estimate_unit: d.unit,
  };
  const problems = factorProblems({ ...row, default_estimate_unit: d.unit });
  return problems[0] ?? row;
}

function formulaText(t: (k: string, o?: Record<string, unknown>) => string, f: SetupFormula) {
  return f.cycle_minutes !== null
    ? t('washroom.formulaValue', { no: f.external_no, minutes: f.cycle_minutes })
    : t('washroom.formulaOnly', { no: f.external_no });
}

function GroupFields({
  idBase,
  draft,
  set,
  formulas,
  defaultLang,
  langs,
}: {
  idBase: string;
  draft: Draft;
  set: (d: Partial<Draft>) => void;
  formulas: SetupFormula[];
  defaultLang: string;
  langs: string[];
}) {
  const { t } = useTranslation();
  const choices = formulas.filter((f) => f.active || f.id === draft.formulaId).sort(byFormulaNo);
  const chosen = formulas.find((f) => f.id === draft.formulaId);
  return (
    <div className="setup-editor-grid">
      <NameFields
        idBase={idBase}
        defaultLang={defaultLang}
        langs={langs}
        name={draft.name}
        names={draft.names}
        onName={(name) => set({ name })}
        onNames={(names) => set({ names })}
      />
      <div className="field">
        <label htmlFor={`${idBase}-color`}>{t('setup.groups.color')}</label>
        <span className="setup-color">
          <input
            id={`${idBase}-color`}
            type="color"
            value={draft.color}
            onChange={(e) => set({ color: e.target.value })}
          />
          <span className="mono" aria-hidden="true">
            {draft.color.toUpperCase()}
          </span>
        </span>
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-cat`}>{t('setup.groups.category')}</label>
        <select
          id={`${idBase}-cat`}
          value={draft.category}
          onChange={(e) => set({ category: narrowCategory(e.target.value) })}
        >
          {CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {t(`categories.${c}`)}
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-formula`}>{t('setup.groups.formula')}</label>
        <select
          id={`${idBase}-formula`}
          value={draft.formulaId}
          aria-describedby={`${idBase}-formula-hint`}
          onChange={(e) => set({ formulaId: e.target.value })}
        >
          <option value="">{t('setup.groups.noFormula')}</option>
          {choices.map((f) => (
            <option key={f.id} value={f.id}>
              {formulaText(t, f)}
              {f.name ? ` · ${f.name}` : ''}
              {!f.active ? ` (${t('setup.formulas.retiredBadge')})` : ''}
            </option>
          ))}
        </select>
        <p className="hint" id={`${idBase}-formula-hint`}>
          {chosen
            ? chosen.cycle_minutes !== null
              ? t('setup.groups.formulaMinutes', { count: chosen.cycle_minutes })
              : t('setup.formulas.noMinutes')
            : t('setup.groups.formulaHint')}
        </p>
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-basket`}>{t('setup.groups.perBasket')}</label>
        <input
          id={`${idBase}-basket`}
          inputMode="decimal"
          autoComplete="off"
          value={draft.perBasket}
          aria-describedby={`${idBase}-per-hint`}
          onChange={(e) => set({ perBasket: e.target.value })}
        />
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-bin`}>{t('setup.groups.perBin')}</label>
        <input
          id={`${idBase}-bin`}
          inputMode="decimal"
          autoComplete="off"
          value={draft.perBin}
          aria-describedby={`${idBase}-per-hint`}
          onChange={(e) => set({ perBin: e.target.value })}
        />
      </div>
      <p className="hint setup-span" id={`${idBase}-per-hint`}>
        {t('setup.groups.perHint')}
      </p>
      <div className="field check setup-span">
        <label>
          <input
            type="checkbox"
            checked={draft.allowBasket}
            onChange={(e) => set({ allowBasket: e.target.checked })}
          />
          {t('setup.groups.allowBasket')}
        </label>
        <label>
          <input
            type="checkbox"
            checked={draft.allowBin}
            onChange={(e) => set({ allowBin: e.target.checked })}
          />
          {t('setup.groups.allowBin')}
        </label>
      </div>
      <div className="field">
        <label htmlFor={`${idBase}-unit`}>{t('setup.groups.defaultUnit')}</label>
        <select
          id={`${idBase}-unit`}
          value={draft.unit}
          onChange={(e) => set({ unit: asUnit(e.target.value) })}
        >
          {UNITS.map((u) => (
            <option key={u} value={u}>
              {t(`setup.groups.unit.${u}`)}
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}

function GroupEditor({
  group,
  formulas,
  defaultLang,
  langs,
  onClose,
  onStatus,
}: {
  group: SetupWashGroup;
  formulas: SetupFormula[];
  defaultLang: string;
  langs: string[];
  onClose: () => void;
  onStatus: OnStatus;
}) {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const qc = useQueryClient();
  const [draft, setDraft] = useState(() => draftOf(group, langs, group.customer_id !== null));
  const shown = localized(group.name, group.name_i18n);
  const idBase = `g-${group.id}`;

  const save = useMutation({
    mutationFn: async (patch: Partial<Row> & { active?: boolean }) => {
      const { error } = await supabase.from('wash_groups').update(patch).eq('id', group.id);
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
            : t('setup.savedNamed', { name: patch.name ?? shown }),
      );
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => invalidateSetup(qc),
  });

  function onSave(e: FormEvent) {
    e.preventDefault();
    const row = readDraft(draft, langs);
    if (typeof row === 'string') return onStatus(false, t(row));
    const patch: Partial<Row> = {};
    if (row.name !== group.name) patch.name = row.name;
    const before = fromNameI18n(group.name_i18n, langs);
    if (langs.some((l) => (before[l] ?? '').trim() !== (draft.names[l] ?? '').trim())) {
      const old =
        group.name_i18n && typeof group.name_i18n === 'object' && !Array.isArray(group.name_i18n)
          ? (group.name_i18n as Record<string, string>)
          : {};
      patch.name_i18n = {
        ...Object.fromEntries(Object.entries(old).filter(([k]) => !langs.includes(k))),
        ...row.name_i18n,
      };
    }
    if (row.color_hex.toUpperCase() !== group.color_hex.toUpperCase())
      patch.color_hex = row.color_hex;
    if (row.category !== group.category) patch.category = row.category;
    if (row.wash_formula_id !== group.wash_formula_id) patch.wash_formula_id = row.wash_formula_id;
    if (row.loads_per_basket !== group.loads_per_basket)
      patch.loads_per_basket = row.loads_per_basket;
    if (row.loads_per_bin !== group.loads_per_bin) patch.loads_per_bin = row.loads_per_bin;
    if (row.allow_basket_estimates !== group.allow_basket_estimates)
      patch.allow_basket_estimates = row.allow_basket_estimates;
    if (row.allow_bin_estimates !== group.allow_bin_estimates)
      patch.allow_bin_estimates = row.allow_bin_estimates;
    if (row.default_estimate_unit !== group.default_estimate_unit)
      patch.default_estimate_unit = row.default_estimate_unit;
    if (Object.keys(patch).length === 0) return onClose();
    save.mutate(patch);
  }

  return (
    <form onSubmit={onSave} noValidate className="setup-editor" aria-labelledby={`${idBase}-t`}>
      <h3 id={`${idBase}-t`} className="setup-editor-title">
        {t('setup.editNamed', { name: shown })}
      </h3>
      <GroupFields
        idBase={idBase}
        draft={draft}
        set={(d) => setDraft((p) => ({ ...p, ...d }))}
        formulas={formulas}
        defaultLang={defaultLang}
        langs={langs}
      />
      <div className="actions">
        <button type="submit" disabled={save.isPending}>
          {t('setup.save')}
        </button>
        <button type="button" className="secondary" onClick={onClose}>
          {t('common.cancel')}
        </button>
        {group.active ? (
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
      <MoreInfo>{t('setup.groups.deactivateHint')}</MoreInfo>
    </form>
  );
}

function AddGroup({
  plant,
  customerId,
  sortOrder,
  formulas,
  defaultLang,
  langs,
  onClose,
  onStatus,
}: {
  plant: OwnerPlant;
  customerId: string | null;
  sortOrder: number;
  formulas: SetupFormula[];
  defaultLang: string;
  langs: string[];
  onClose: () => void;
  onStatus: OnStatus;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const [draft, setDraft] = useState(() => draftOf(null, langs, customerId !== null));
  const add = useMutation({
    mutationFn: async (row: Row) => {
      const { error } = await supabase.from('wash_groups').insert({
        org_id: plant.org_id,
        plant_id: plant.id,
        customer_id: customerId,
        sort_order: sortOrder,
        ...row,
      });
      if (error) throw error;
      return row.name;
    },
    onSuccess: (n) => {
      onClose();
      onStatus(true, t('setup.machines.added', { name: n }));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => invalidateSetup(qc),
  });
  return (
    <section className="card setup-add" aria-labelledby="add-group">
      <h2 id="add-group">{t('setup.groups.addTitle')}</h2>
      <form
        noValidate
        onSubmit={(e) => {
          e.preventDefault();
          const row = readDraft(draft, langs);
          if (typeof row === 'string') return onStatus(false, t(row));
          add.mutate(row);
        }}
      >
        <GroupFields
          idBase="new-group"
          draft={draft}
          set={(d) => setDraft((p) => ({ ...p, ...d }))}
          formulas={formulas}
          defaultLang={defaultLang}
          langs={langs}
        />
        <div className="actions">
          <button type="submit" disabled={add.isPending}>
            {t('setup.groups.add')}
          </button>
          <button type="button" className="secondary" onClick={onClose}>
            {t('common.cancel')}
          </button>
        </div>
      </form>
    </section>
  );
}

function GroupRow({
  group,
  formula,
  open,
  onToggle,
  children,
}: {
  group: SetupWashGroup;
  formula: SetupFormula | undefined;
  open: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  const { t, i18n } = useTranslation();
  const localized = useLocalizedName();
  const shown = localized(group.name, group.name_i18n);
  const num = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 3 });
  const missing = binFactorMissing(group);
  const facts: string[] = [];
  if (group.loads_per_basket !== null)
    facts.push(t('setup.groups.basketFact', { n: num.format(group.loads_per_basket) }));
  if (group.loads_per_bin !== null)
    facts.push(t('setup.groups.binFact', { n: num.format(group.loads_per_bin) }));
  facts.push(
    t('setup.groups.estimatesIn', {
      unit: t(`setup.groups.unitIn.${asUnit(group.default_estimate_unit)}`),
    }),
  );
  return (
    <li className={group.active ? 'setup-row' : 'setup-row inactive'}>
      <div className="setup-row-head">
        <p className="setup-row-text">
          <span className="head setup-group-name">
            <span
              className="setup-swatch"
              aria-hidden="true"
              style={{ background: safeColor(group.color_hex) }}
            />
            {shown}
          </span>
          <span className="setup-kind">
            {!group.active && <span className="badge setup-off">{t('setup.inactive')}</span>}
            <span className="mono">
              {formula ? formulaText(t, formula) : t('setup.groups.noFormula')}
            </span>
            {' · '}
            {facts.join(' · ')}
          </span>
          {missing && (
            <span className="setup-missing">
              <IconWarning /> {t('setup.groups.missingBin')}
            </span>
          )}
        </p>
        <button
          type="button"
          className="secondary"
          aria-expanded={open}
          aria-label={`${open ? t('setup.close') : t('setup.edit')} ${shown}`}
          onClick={onToggle}
        >
          {open ? t('setup.close') : t('setup.edit')}
        </button>
      </div>
      {open && children}
    </li>
  );
}

export function SetupWashGroupsPage() {
  const { t } = useTranslation();
  const localized = useLocalizedName();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const groups = useSetupWashGroups(plant?.id);
  const formulas = useSetupFormulas(plant?.id);
  const customers = useCustomers(plant?.id);
  const { defaultLang, langs } = useSetupLanguages(plant?.id);
  const [view, setView] = useState<string>('ours'); // 'ours' or a customer id
  const [chip, setChip] = useState<Chip>('all');
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.groups.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }
  const onStatus: OnStatus = (ok, text) => setMessage({ ok, text });
  const all = groups.data ?? [];
  const formulaList = formulas.data ?? [];
  const formulaById = new Map(formulaList.map((f) => [f.id, f]));
  const custList = (customers.data ?? []).filter(
    (c) => c.active || all.some((g) => g.customer_id === c.id),
  );
  const customerId = custList.some((c) => c.id === view) ? view : null;
  const inView = all.filter((g) => g.customer_id === customerId);
  const categoryOf = new Map(inView.map((g) => [g.id, narrowCategory(g.category)]));
  const ids = inView.map((g) => g.id);
  const chips = chipsFor(ids, categoryOf);
  const active = effectiveChip(chip, chips);
  const counts = chipCounts(ids, categoryOf, () => true);
  const shown = inView.filter((g) => g.id === openId || inChip(g.id, active, categoryOf));
  const missingAll = all.filter(binFactorMissing);
  const customerName = (id: string | null) => {
    const c = custList.find((x) => x.id === id);
    return c ? localized(c.name, c.name_i18n) : '';
  };
  const sections = CATEGORIES.map((c) => ({
    cat: c,
    list: shown
      .filter((g) => categoryOf.get(g.id) === c)
      .sort((a, b) => Number(b.active) - Number(a.active) || a.sort_order - b.sort_order),
  })).filter((s) => s.list.length > 0);

  const pick = (v: string) => {
    setView(v);
    setOpenId(null);
    setAdding(false);
  };

  return (
    <main className="form-page setup-wide">
      <div className="setup-title">
        <h1>{t('setup.groups.title')}</h1>
        {!adding && (
          <button
            type="button"
            onClick={() => {
              setAdding(true);
              setOpenId(null);
            }}
          >
            {t('setup.groups.addButton')}
          </button>
        )}
      </div>
      {custList.length > 0 && (
        <div className="est-views setup-views" role="group" aria-label={t('estimates.viewLabel')}>
          <button type="button" aria-pressed={customerId === null} onClick={() => pick('ours')}>
            {t('setup.groups.ours')}
          </button>
          {custList.map((c) => (
            <button
              key={c.id}
              type="button"
              aria-pressed={customerId === c.id}
              onClick={() => pick(c.id)}
            >
              {localized(c.name, c.name_i18n)}
            </button>
          ))}
        </div>
      )}
      {missingAll.length > 0 && (
        <div className="notice setup-warn" role="note">
          <p>
            <IconWarning />{' '}
            <strong>{t('setup.groups.missingTitle', { count: missingAll.length })}</strong>
          </p>
          <ul>
            {missingAll.map((g) => (
              <li key={g.id}>
                {customerName(g.customer_id)} · {localized(g.name, g.name_i18n)}
              </li>
            ))}
          </ul>
          <p className="hint">{t('setup.groups.missingHint')}</p>
        </div>
      )}
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {adding && (
        <AddGroup
          plant={plant}
          customerId={customerId}
          sortOrder={nextSortOrder(inView.map((g) => g.sort_order))}
          formulas={formulaList}
          defaultLang={defaultLang}
          langs={langs}
          onClose={() => setAdding(false)}
          onStatus={onStatus}
        />
      )}
      {groups.isError && <p className="error">{t(setupErrorKey(groups.error))}</p>}
      <CategoryChips chips={chips} value={active} counts={counts} onChange={setChip} />
      {groups.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : sections.length === 0 ? (
        <p className="hint">{t('setup.groups.none')}</p>
      ) : (
        sections.map((s) => (
          <section key={s.cat} aria-labelledby={`cat-${s.cat}`}>
            <h2 id={`cat-${s.cat}`}>{t(`categories.${s.cat}`)}</h2>
            <ul className="setup-list setup-group-list">
              {s.list.map((g) => (
                <GroupRow
                  key={g.id}
                  group={g}
                  formula={g.wash_formula_id ? formulaById.get(g.wash_formula_id) : undefined}
                  open={openId === g.id}
                  onToggle={() => {
                    setOpenId(openId === g.id ? null : g.id);
                    setAdding(false);
                  }}
                >
                  <GroupEditor
                    group={g}
                    formulas={formulaList}
                    defaultLang={defaultLang}
                    langs={langs}
                    onClose={() => setOpenId(null)}
                    onStatus={onStatus}
                  />
                </GroupRow>
              ))}
            </ul>
          </section>
        ))
      )}
    </main>
  );
}
