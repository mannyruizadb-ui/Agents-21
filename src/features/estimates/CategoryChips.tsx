import { useTranslation } from 'react-i18next';
import type { Chip } from './categories';

/**
 * Filter chips by category (owner 2026-11-09): real buttons with aria-pressed, a word on each and the
 * number of groups with work on it ("Napkins 3"). The pressed chip is also filled and bold, so the
 * choice is never shown by color alone.
 */
export function CategoryChips({
  chips,
  value,
  counts,
  onChange,
}: {
  chips: readonly Chip[];
  value: Chip;
  counts: ReadonlyMap<Chip, number>;
  onChange: (c: Chip) => void;
}) {
  const { t } = useTranslation();
  if (chips.length === 0) return null;
  return (
    <div className="cat-chips" role="group" aria-label={t('categories.label')}>
      {chips.map((c) => {
        const n = counts.get(c) ?? 0;
        return (
          <button
            key={c}
            type="button"
            className="cat-chip"
            aria-pressed={value === c}
            onClick={() => onChange(c)}
          >
            {t(`categories.${c}`)}
            {n > 0 && <span className="cat-chip-count mono"> {n}</span>}
          </button>
        );
      })}
    </div>
  );
}
