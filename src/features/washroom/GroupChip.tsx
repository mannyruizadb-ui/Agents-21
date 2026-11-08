import { safeColor, useLocalizedName } from './localizedName';
import type { I18nJson } from './washroomData';
import { CustomerBadge } from '../customers/CustomerBadge';
import './board.css';

/**
 * Wash group chip: a color stripe + the name (wraps, never truncated). Color is never alone. With
 * `washGroupId`, a customer's group (AA Linen) also shows the customer badge after the chip.
 */
export function GroupChip({
  name,
  nameI18n,
  colorHex,
  washGroupId,
}: {
  name: string | null;
  nameI18n: I18nJson | null;
  colorHex: string | null;
  washGroupId?: string | null;
}) {
  const localized = useLocalizedName();
  return (
    <>
      <span className="wb-chip" style={{ borderLeftColor: safeColor(colorHex) }}>
        {localized(name, nameI18n)}
      </span>
      {washGroupId && <CustomerBadge washGroupId={washGroupId} />}
    </>
  );
}
