import { safeColor } from './localizedName';

// Two-colour wash groups (owner 2026-11-10): a mixed group (e.g. two fabrics washed together) has an
// optional second colour, wash_groups.color_hex_2. Every swatch then shows both colours, split
// half/half (diagonal for squares and dots, top/bottom for stripes and bars), always outlined by its
// own CSS. Colour is decorative: the group's name is always shown next to it.

const HEX = /^#[0-9A-Fa-f]{6}$/;

/** The second colour when it is a valid #RRGGBB, else null (one colour). */
export function secondColor(hex2: string | null | undefined): string | null {
  return hex2 && HEX.test(hex2) ? hex2 : null;
}

/**
 * CSS `background` for a swatch: the solid first colour, or both colours split half/half.
 * `split`: 'diagonal' (squares, dots) or 'vertical' (a thin stripe or a bar: top half / bottom half).
 */
export function swatchBackground(
  hex: string | null | undefined,
  hex2: string | null | undefined,
  split: 'diagonal' | 'vertical' = 'diagonal',
): string {
  const c1 = safeColor(hex);
  const c2 = secondColor(hex2);
  if (!c2) return c1;
  const dir = split === 'diagonal' ? '135deg' : 'to bottom';
  return `linear-gradient(${dir}, ${c1} 0 50%, ${c2} 50% 100%)`;
}
