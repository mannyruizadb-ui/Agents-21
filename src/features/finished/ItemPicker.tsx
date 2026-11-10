import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { FINISH_GROUPS, finishGroupOf, type FinishGroup, type FinishItem } from './finishedLogic';
import { ItemSwatch } from './ItemSwatch';
import { useItemName } from './useItemName';

/**
 * "+ Add item": category chips (Napkins, Tablecloths, Sheets, Towels, Aprons & coats) and big item
 * buttons with the fabric colour. One tap pins the item to the "working on" bar and selects it.
 */
export function ItemPicker({
  items,
  pinned,
  onPick,
  onClose,
}: {
  items: readonly FinishItem[];
  pinned: readonly string[];
  onPick: (id: string) => void;
  onClose: (() => void) | null;
}) {
  const { t } = useTranslation();
  const nameOf = useItemName();
  const present = FINISH_GROUPS.filter((g) => items.some((i) => finishGroupOf(i) === g));
  const [chip, setChip] = useState<FinishGroup | null>(null);
  const active = chip && present.includes(chip) ? chip : (present[0] ?? null);
  const shown = items.filter((i) => finishGroupOf(i) === active);

  return (
    <section className="card fg-picker" aria-labelledby="fg-picker-title">
      <div className="fg-picker-head">
        <h2 id="fg-picker-title">{t('finished.pickTitle')}</h2>
        {onClose && (
          <button type="button" className="secondary" onClick={onClose}>
            {t('finished.closePicker')}
          </button>
        )}
      </div>
      {present.length === 0 ? (
        <p className="hint">{t('finished.noItems')}</p>
      ) : (
        <>
          <div className="cat-chips" role="group" aria-label={t('categories.label')}>
            {present.map((g) => (
              <button
                key={g}
                type="button"
                className="cat-chip"
                aria-pressed={active === g}
                onClick={() => setChip(g)}
              >
                {t(`finished.groups.${g}`)}
              </button>
            ))}
          </div>
          <ul className="fg-pick-grid">
            {shown.map((i) => {
              const isPinned = pinned.includes(i.id);
              return (
                <li key={i.id}>
                  <button type="button" className="fg-pick" onClick={() => onPick(i.id)}>
                    <ItemSwatch color={i.color_hex} size="lg" />
                    <span className="fg-pick-name">{nameOf(i)}</span>
                    {isPinned && <span className="fg-pick-pinned">{t('finished.pinned')}</span>}
                  </button>
                </li>
              );
            })}
          </ul>
        </>
      )}
    </section>
  );
}
