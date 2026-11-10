import { safeColor } from '../washroom/localizedName';

/**
 * The fabric colour of an item, as a decorative square next to its name (never colour alone). Always
 * outlined, so white (#FFFFFF) and black (#000000) both read on the dark theme.
 */
export function ItemSwatch({ color, size = 'md' }: { color: string; size?: 'sm' | 'md' | 'lg' }) {
  return (
    <span
      className={`fg-swatch fg-swatch-${size}`}
      style={{ backgroundColor: safeColor(color) }}
      aria-hidden="true"
    />
  );
}
