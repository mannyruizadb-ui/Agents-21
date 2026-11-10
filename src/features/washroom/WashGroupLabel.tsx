import type { I18nJson } from './washroomData';
import { useLocalizedName } from './localizedName';
import { swatchBackground } from './groupColor';
import { CustomerBadge } from '../customers/CustomerBadge';

/**
 * Wash group color chip + name. The chip is decorative (aria-hidden); the name always carries the
 * meaning, so color is never the only cue. With `washGroupId`, a customer's group (AA Linen) also
 * shows the customer badge. A mixed group with a second colour shows both, split diagonally.
 */
export function WashGroupLabel({
  name,
  nameI18n,
  colorHex,
  colorHex2,
  className,
  washGroupId,
}: {
  name: string | null | undefined;
  nameI18n: I18nJson | null | undefined;
  colorHex: string | null | undefined;
  colorHex2?: string | null;
  className?: string;
  washGroupId?: string | null;
}) {
  const localized = useLocalizedName();
  return (
    <span className={className ? `group-label ${className}` : 'group-label'}>
      <span
        className="group-chip"
        style={{ background: swatchBackground(colorHex, colorHex2) }}
        aria-hidden="true"
      />
      <span className="group-name">{localized(name, nameI18n)}</span>
      {washGroupId && <CustomerBadge washGroupId={washGroupId} />}
    </span>
  );
}
