import type { I18nJson } from './washroomData';
import { safeColor, useLocalizedName } from './localizedName';

/**
 * Wash group color chip + name. The chip is decorative (aria-hidden); the name always carries the
 * meaning, so color is never the only cue.
 */
export function WashGroupLabel({
  name,
  nameI18n,
  colorHex,
  className,
}: {
  name: string | null | undefined;
  nameI18n: I18nJson | null | undefined;
  colorHex: string | null | undefined;
  className?: string;
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
    </span>
  );
}
