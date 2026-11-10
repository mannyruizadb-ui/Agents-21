import { useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useRequiredSession } from '../../app/auth/sessionContext';
import { useOwnerPlants } from '../admin/useOwnerPlants';
import { safeColor } from '../washroom/localizedName';
import { unwrap } from '../washroom/rpcError';
import { ItemSwatch } from '../finished/ItemSwatch';
import { useItemName } from '../finished/useItemName';
import { finishedKeys } from '../finished/finishedData';
import { setupErrorKey } from './setupErrors';
import { numText } from './setupForm';
import { itemPatch, PRESET_COLORS, type ItemDraft, type ItemNumbers } from './setupItemsForm';
import '../../lib/forms.css';
import '../washroom/washroom.css';
import './setup.css';
import '../finished/finished.css';

// Setup → Items (owner 2026-11-10: "edit all such numbers in the app"). Items grouped by category; per
// item: pack size, bin size (the finishing screen's "+1 bin"), stock owned (the "more than we own"
// check), fabric colour (colour input + presets), pieces per load (+ counted / derived) and active.
// Direct table writes through RLS + column grants; bin size and stock are owner-only in the DB
// (app.guard_item_owner_fields). No deletes: deactivate. Errors through setupErrorKey().

const CATS = ['linen', 'towel', 'apparel', 'mat', 'mop', 'other'] as const;

interface SetupItem extends ItemNumbers {
  id: string;
  name: string;
  name_i18n: unknown;
  category: string;
  sort_order: number;
}

function useSetupItems(plantId: string | undefined) {
  return useQuery({
    queryKey: ['setup-items', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<SetupItem[]> =>
      unwrap(
        await supabase
          .from('item_types')
          .select(
            'id, name, name_i18n, category, sort_order, count_mode, pack_size, bin_size, stock_qty, pieces_per_load, pieces_per_load_source, color_hex, active',
          )
          .eq('plant_id', plantId ?? '')
          .order('sort_order')
          .order('name'),
      ) ?? [],
  });
}

function draftOf(i: SetupItem): ItemDraft {
  return {
    packSize: numText(i.pack_size),
    binSize: numText(i.bin_size),
    stock: numText(i.stock_qty),
    perLoad: numText(i.pieces_per_load),
    perLoadSource: i.pieces_per_load_source === 'derived' ? 'derived' : 'counted',
    color: safeColor(i.color_hex),
    active: i.active,
  };
}

function ItemEditor({
  item,
  onClose,
  onStatus,
}: {
  item: SetupItem;
  onClose: () => void;
  onStatus: (ok: boolean, text: string) => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const nameOf = useItemName();
  const shown = nameOf(item);
  const [d, setD] = useState<ItemDraft>(() => draftOf(item));
  const set = (p: Partial<ItemDraft>) => setD((x) => ({ ...x, ...p }));
  const idBase = `it-${item.id}`;

  const save = useMutation({
    mutationFn: async (patch: Partial<ItemNumbers>) => {
      const { error } = await supabase.from('item_types').update(patch).eq('id', item.id);
      if (error) throw error;
    },
    onSuccess: () => {
      onClose();
      onStatus(true, t('setup.savedNamed', { name: shown }));
    },
    onError: (e) => onStatus(false, t(setupErrorKey(e))),
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: ['setup-items'] });
      void qc.invalidateQueries({ queryKey: finishedKeys.all });
    },
  });

  function onSave(e: FormEvent) {
    e.preventDefault();
    const patch = itemPatch(item, d);
    if (typeof patch === 'string') return onStatus(false, t(patch));
    if (Object.keys(patch).length === 0) return onClose();
    save.mutate(patch);
  }

  return (
    <form onSubmit={onSave} noValidate className="setup-editor" aria-labelledby={`${idBase}-t`}>
      <h3 id={`${idBase}-t`} className="setup-editor-title">
        {t('setup.editNamed', { name: shown })}
      </h3>
      <div className="setup-editor-grid">
        {item.count_mode === 'pack' && (
          <div className="field">
            <label htmlFor={`${idBase}-pack`}>{t('setup.items.packSize')}</label>
            <input
              id={`${idBase}-pack`}
              inputMode="numeric"
              autoComplete="off"
              value={d.packSize}
              onChange={(e) => set({ packSize: e.target.value })}
            />
          </div>
        )}
        <div className="field">
          <label htmlFor={`${idBase}-bin`}>{t('setup.items.binSize')}</label>
          <input
            id={`${idBase}-bin`}
            inputMode="numeric"
            autoComplete="off"
            value={d.binSize}
            aria-describedby={`${idBase}-bin-hint`}
            onChange={(e) => set({ binSize: e.target.value })}
          />
          <p className="hint" id={`${idBase}-bin-hint`}>
            {t('setup.items.binHint')}
          </p>
        </div>
        <div className="field">
          <label htmlFor={`${idBase}-stock`}>{t('setup.items.stock')}</label>
          <input
            id={`${idBase}-stock`}
            inputMode="numeric"
            autoComplete="off"
            value={d.stock}
            aria-describedby={`${idBase}-stock-hint`}
            onChange={(e) => set({ stock: e.target.value })}
          />
          <p className="hint" id={`${idBase}-stock-hint`}>
            {t('setup.items.stockHint')}
          </p>
        </div>
        <div className="field">
          <label htmlFor={`${idBase}-perload`}>{t('setup.items.perLoad')}</label>
          <input
            id={`${idBase}-perload`}
            inputMode="decimal"
            autoComplete="off"
            value={d.perLoad}
            onChange={(e) => set({ perLoad: e.target.value })}
          />
        </div>
        <div className="field">
          <label htmlFor={`${idBase}-src`}>{t('setup.items.perLoadSource')}</label>
          <select
            id={`${idBase}-src`}
            value={d.perLoadSource}
            onChange={(e) =>
              set({ perLoadSource: e.target.value === 'derived' ? 'derived' : 'counted' })
            }
          >
            <option value="counted">{t('setup.items.counted')}</option>
            <option value="derived">{t('setup.items.derived')}</option>
          </select>
        </div>
        <div className="field setup-span">
          <label htmlFor={`${idBase}-color`}>{t('setup.items.color')}</label>
          <span className="setup-color">
            <input
              id={`${idBase}-color`}
              type="color"
              value={d.color}
              onChange={(e) => set({ color: e.target.value })}
            />
            <span className="mono">{d.color.toUpperCase()}</span>
          </span>
          <div className="setup-presets" role="group" aria-label={t('setup.items.presets')}>
            {PRESET_COLORS.map((c) => (
              <button
                key={c}
                type="button"
                className="secondary setup-preset"
                aria-pressed={d.color.toUpperCase() === c}
                onClick={() => set({ color: c })}
              >
                <ItemSwatch color={c} />
                {t(`setup.items.colors.${c.slice(1)}`)}
              </button>
            ))}
          </div>
        </div>
        <div className="field check setup-span">
          <label>
            <input
              type="checkbox"
              checked={d.active}
              onChange={(e) => set({ active: e.target.checked })}
            />
            {t('setup.items.active')}
          </label>
        </div>
      </div>
      <div className="actions">
        <button type="submit" disabled={save.isPending}>
          {t('setup.save')}
        </button>
        <button type="button" className="secondary" onClick={onClose}>
          {t('common.cancel')}
        </button>
      </div>
    </form>
  );
}

export function SetupItemsPage() {
  const { t, i18n } = useTranslation();
  const nameOf = useItemName();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const plant = ownerPlants.data?.[0];
  const items = useSetupItems(plant?.id);
  const [openId, setOpenId] = useState<string | null>(null);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const num = new Intl.NumberFormat(i18n.language);

  if (ownerPlants.isPending) return <p role="status">{t('common.loading')}</p>;
  if (!plant) {
    return (
      <main className="form-page">
        <h1>{t('setup.items.title')}</h1>
        <p className="notice">{t('setup.ownerOnly')}</p>
      </main>
    );
  }
  const all = items.data ?? [];
  const sections = CATS.map((c) => ({
    cat: c,
    list: all.filter((i) =>
      (CATS as readonly string[]).includes(i.category) ? i.category === c : c === 'other',
    ),
  })).filter((s) => s.list.length > 0);

  return (
    <main className="form-page setup-wide">
      <h1>{t('setup.items.title')}</h1>
      <p className="hint">{t('setup.items.intro')}</p>
      <div role="status" aria-live="polite">
        {message && <p className={message.ok ? 'notice' : 'error'}>{message.text}</p>}
      </div>
      {items.isError && <p className="error">{t(setupErrorKey(items.error))}</p>}
      {items.isPending ? (
        <p role="status">{t('common.loading')}</p>
      ) : (
        sections.map((s) => (
          <section key={s.cat} aria-labelledby={`icat-${s.cat}`}>
            <h2 id={`icat-${s.cat}`}>{t(`setup.items.cats.${s.cat}`)}</h2>
            <ul className="setup-list setup-group-list">
              {s.list.map((i) => {
                const shown = nameOf(i);
                const open = openId === i.id;
                const facts: string[] = [];
                facts.push(
                  i.count_mode === 'pack' && i.pack_size !== null
                    ? t('setup.items.packFact', { n: num.format(i.pack_size) })
                    : t('setup.items.unitFact'),
                );
                if (i.bin_size !== null)
                  facts.push(t('setup.items.binFact', { n: num.format(i.bin_size) }));
                facts.push(
                  i.stock_qty !== null
                    ? t('setup.items.stockFact', { n: num.format(i.stock_qty) })
                    : t('setup.items.stockUnknown'),
                );
                if (i.pieces_per_load !== null)
                  facts.push(t('setup.items.perLoadFact', { n: num.format(i.pieces_per_load) }));
                return (
                  <li key={i.id} className={i.active ? 'setup-row' : 'setup-row inactive'}>
                    <div className="setup-row-head">
                      <p className="setup-row-text">
                        <span className="head setup-group-name">
                          <ItemSwatch color={i.color_hex} />
                          {shown}
                        </span>
                        <span className="setup-kind">
                          {!i.active && (
                            <span className="badge setup-off">{t('setup.inactive')}</span>
                          )}
                          {facts.join(' · ')}
                        </span>
                      </p>
                      <button
                        type="button"
                        className="secondary"
                        aria-expanded={open}
                        aria-label={`${open ? t('setup.close') : t('setup.edit')} ${shown}`}
                        onClick={() => setOpenId(open ? null : i.id)}
                      >
                        {open ? t('setup.close') : t('setup.edit')}
                      </button>
                    </div>
                    {open && (
                      <ItemEditor
                        item={i}
                        onClose={() => setOpenId(null)}
                        onStatus={(ok, text) => setMessage({ ok, text })}
                      />
                    )}
                  </li>
                );
              })}
            </ul>
          </section>
        ))
      )}
    </main>
  );
}
