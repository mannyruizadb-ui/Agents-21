import type { CSSProperties } from 'react';
import { safeColor, useLocalizedName } from './localizedName';
import { secondColor } from './groupColor';
import type { I18nJson } from './washroomData';
import { CustomerBadge } from '../customers/CustomerBadge';
import './board.css';

/**
 * Wash group chip: a color stripe + the name (wraps, never truncated). Color is never alone. A mixed
 * group with a second colour shows a split stripe (top half / bottom half). With `washGroupId`, a
 * customer's group (AA Linen) also shows the customer badge after the chip.
 */
export function GroupChip({
  name,
  nameI18n,
  colorHex,
  colorHex2,
  washGroupId,
}: {
  name: string | null;
  nameI18n: I18nJson | null;
  colorHex: string | null;
  colorHex2?: string | null;
  washGroupId?: string | null;
}) {
  const localized = useLocalizedName();
  const c2 = secondColor(colorHex2);
  // Custom properties feed the split-stripe background in board.css.
  const style: CSSProperties = c2
    ? ({ '--wg-c1': safeColor(colorHex), '--wg-c2': c2 } as CSSProperties)
    : { borderLeftColor: safeColor(colorHex) };
  return (
    <>
      <span className={c2 ? 'wb-chip wb-chip-split' : 'wb-chip'} style={style}>
        {localized(name, nameI18n)}
      </span>
      {washGroupId && <CustomerBadge washGroupId={washGroupId} />}
    </>
  );
}
