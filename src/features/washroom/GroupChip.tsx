import { safeColor, useLocalizedName } from './localizedName';
import type { I18nJson } from './washroomData';
import './board.css';

/** Wash group chip: a color stripe + the name (wraps, never truncated). Color is never alone. */
export function GroupChip({
  name,
  nameI18n,
  colorHex,
}: {
  name: string | null;
  nameI18n: I18nJson | null;
  colorHex: string | null;
}) {
  const localized = useLocalizedName();
  return (
    <span className="wb-chip" style={{ borderLeftColor: safeColor(colorHex) }}>
      {localized(name, nameI18n)}
    </span>
  );
}
