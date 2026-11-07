import type { I18nJson } from './washroomData';
import { safeColor, useLocalizedName } from './localizedName';
import { CustomerBadge } from '../customers/CustomerBadge';

/**
 * Wash group color chip + name. The chip is decorative (aria-hidden); the name always carries the
 * meaning, so color is never the only cue. With `washGroupId`, a customer's group (AA Linen) also
 * shows the customer badge.
 */
export function WashGroupLabel({
  name,
  nameI18n,
  colorHex,
  className,
  washGroupId,
}: {
  name: string | null | undefined;
  nameI18n: I18nJson | null | undefined;
  colorHex: string | null | undefined;
  className?: string;
  washGroupId?: string | null;
}) {
  const localized = useLocalizedName();
  return (
    <span className={className ? `group-label ${className}` : 'group-label'}>
      <span
        className="group-chip"
        style={{ backgroundColor: safeColor(colorHex) }}
        aria-hidden="true"
      />
      <span className="group-name">{localized(name, nameI18n)}</span>
      {washGroupId && <CustomerBadge washGroupId={washGroupId} />}
    </span>
  );
}
