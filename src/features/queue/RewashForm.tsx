import { useRef, useState, type FormEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { groupOptionText } from '../customers/customerLookup';
import { useCustomerNameOf } from '../customers/useCustomerLookup';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import { useLocalizedName } from '../washroom/localizedName';
import {
  CONTAINER_PICKS,
  fractionText,
  pluralCount,
  previewLoads,
  rewashUnits,
  type Unit,
} from '../washroom/qtyFormat';
import { errorMessageKey, unwrap } from '../washroom/rpcError';
import { useWashGroups, washroomKeys } from '../washroom/washroomData';
import { parseLoads } from './queueOrder';
import { MoreInfo } from '../../lib/MoreInfo';

// "Add rewash" (owner 2026-11-04, manager exception 2): finishing sends goods back. A rewash item is
// never RUSH and never assigned to a washer; it lands at the bottom of the normal items. Amount in
// loads, or in baskets / bins (¼ ½ ¾ Full or a number) where the group allows that container.

export function RewashForm({
  areaId,
  plantId,
  onDone,
}: {
  areaId: string;
  plantId: string;
  onDone: (message: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const localized = useLocalizedName();
  const customerOf = useCustomerNameOf();
  const groups = useWashGroups(plantId);
  const [groupId, setGroupId] = useState('');
  const [unit, setUnit] = useState<Unit>('load');
  const [amount, setAmount] = useState('1');
  const [fieldError, setFieldError] = useState<string | null>(null);
  const clientId = useRef<string | null>(null);
  const nf = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 2 });
  const fmt = (n: number) => nf.format(n);

  const group = groups.data?.find((g) => g.id === groupId);
  const units = group ? rewashUnits(group) : (['load'] as Unit[]);
  const qty = parseLoads(amount);
  const preview =
    group && qty !== null && unit !== 'load'
      ? previewLoads(qty, unit, group.loads_per_basket, group.loads_per_bin)
      : null;

  const create = useMutation({
    mutationFn: async (q: number) => {
      clientId.current ??= crypto.randomUUID();
      return unwrap(
        await supabase.rpc('create_queue_item', {
          p_area_id: areaId,
          p_qty: q,
          p_unit: unit,
          p_client_id: clientId.current,
          p_wash_group_id: groupId,
          p_is_rewash: true,
          p_is_rush: false,
        }),
      );
    },
    onSuccess: (_r, q) => {
      clientId.current = null;
      onDone(
        t('rewash.added', {
          group: group ? localized(group.name, group.name_i18n) : '',
          amount: t(`units.${unit}`, { count: pluralCount(q), n: fractionText(q, fmt) }),
        }),
      );
      setAmount('1');
      setUnit('load');
    },
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: washroomKeys.queue(areaId) });
      void qc.invalidateQueries({ queryKey: ['washroom-board'] });
    },
  });

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (!groupId) return setFieldError(t('queue.errors.chooseGroup'));
    if (qty === null) return setFieldError(t('rewash.errors.amount'));
    setFieldError(null);
    create.mutate(qty);
  }

  function change(fn: () => void) {
    fn();
    clientId.current = null;
  }

  return (
    <section className="card" aria-labelledby="rewash-title">
      <h2 id="rewash-title">{t('rewash.title')}</h2>
      <MoreInfo>{t('rewash.intro')}</MoreInfo>
      <form onSubmit={onSubmit} noValidate>
        <div className="field">
          <label htmlFor="rw-group">{t('queue.groupLabel')}</label>
          <select
            id="rw-group"
            value={groupId}
            onChange={(e) =>
              change(() => {
                setGroupId(e.target.value);
                setUnit('load');
              })
            }
          >
            <option value="">{t('queue.choose')}</option>
            {(groups.data ?? []).map((g) => (
              <option key={g.id} value={g.id}>
                {groupOptionText(localized(g.name, g.name_i18n), customerOf(g.id))}
              </option>
            ))}
          </select>
        </div>

        <fieldset className="field" style={{ border: 0, padding: 0, margin: '0 0 1rem' }}>
          <legend>
            <strong>{t('rewash.unitLabel')}</strong>
          </legend>
          <ul className="pick-list">
            {units.map((u) => (
              <li key={u}>
                <button
                  type="button"
                  aria-pressed={unit === u}
                  onClick={() => change(() => setUnit(u))}
                >
                  {t(`rewash.unit.${u}`)}
                </button>
              </li>
            ))}
          </ul>
        </fieldset>

        {unit !== 'load' && (
          <fieldset className="field" style={{ border: 0, padding: 0, margin: '0 0 0.5rem' }}>
            <legend>
              <strong>{t('rewash.howFull')}</strong>
            </legend>
            <ul className="pick-list">
              {CONTAINER_PICKS.map((p) => (
                <li key={p}>
                  <button
                    type="button"
                    aria-pressed={qty === p}
                    onClick={() => change(() => setAmount(String(p)))}
                  >
                    {p === 1 ? t('rewash.full') : fractionText(p, fmt)}
                  </button>
                </li>
              ))}
            </ul>
          </fieldset>
        )}

        <div className="field">
          <label htmlFor="rw-amount">{t(`rewash.amountLabel.${unit}`)}</label>
          <input
            id="rw-amount"
            inputMode="decimal"
            autoComplete="off"
            value={amount}
            onChange={(e) => change(() => setAmount(e.target.value))}
            aria-describedby={unit === 'load' ? undefined : 'rw-preview'}
          />
          {unit !== 'load' && (
            <p id="rw-preview" className="hint">
              {preview !== null
                ? t('rewash.preview', { count: pluralCount(preview), n: fmt(preview) })
                : t('rewash.noFactor')}
            </p>
          )}
        </div>

        <div role="alert">
          {fieldError && <p className="error">{fieldError}</p>}
          {create.isError && <p className="error">{t(errorMessageKey(create.error))}</p>}
        </div>
        <button type="submit" disabled={create.isPending}>
          {create.isPending ? t('queue.adding') : t('rewash.add')}
        </button>
      </form>
    </section>
  );
}
