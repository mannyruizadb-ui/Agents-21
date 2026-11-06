// Quantities for the queue and board. Containers (basket, bin) are owner estimates, so their load
// conversion is always approximate and shown with "≈" (CLAUDE.md measurement model). Pure module.

export type Unit = 'load' | 'basket' | 'bin' | 'piece' | 'pack';

const FRACTIONS: Record<string, string> = { '0.25': '¼', '0.5': '½', '0.75': '¾' };

/** 0.5 → "½", 1.75 → "1¾", 2 → "2", 1.3 → format(1.3). */
export function fractionText(qty: number, format: (n: number) => string): string {
  const whole = Math.floor(qty);
  const frac = Math.round((qty - whole) * 100) / 100;
  const sym = FRACTIONS[String(frac)];
  if (sym) return whole > 0 ? `${format(whole)}${sym}` : sym;
  return format(qty);
}

/** Is the load count derived from an estimate (not counted in loads)? */
export function isApproximateUnit(unit: Unit | null | undefined): boolean {
  return unit !== 'load';
}

/** Count for i18n plurals: "½ bin", "1 bin", "2 bins" (anything up to 1 reads singular). */
export function pluralCount(qty: number): number {
  return qty <= 1 ? 1 : qty;
}

/** Client-side preview of loads for a container amount (the DB's app.to_loads is authoritative). */
export function previewLoads(
  qty: number,
  unit: Unit,
  loadsPerBasket: number | null,
  loadsPerBin: number | null,
): number | null {
  if (unit === 'load') return qty;
  if (unit === 'basket')
    return loadsPerBasket ? Math.round(qty * loadsPerBasket * 100) / 100 : null;
  if (unit === 'bin') return loadsPerBin ? Math.round(qty * loadsPerBin * 100) / 100 : null;
  return null;
}

/** Units a rewash can be entered in for a group: loads always; basket / bin only where allowed. */
export function rewashUnits(group: {
  allow_basket_estimates: boolean;
  allow_bin_estimates: boolean;
}): Unit[] {
  return [
    'load',
    ...(group.allow_basket_estimates ? (['basket'] as const) : []),
    ...(group.allow_bin_estimates ? (['bin'] as const) : []),
  ];
}

/** Quick picks for a container amount: ¼ ½ ¾ Full. */
export const CONTAINER_PICKS = [0.25, 0.5, 0.75, 1] as const;
