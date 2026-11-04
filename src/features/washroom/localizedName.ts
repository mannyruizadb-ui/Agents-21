import { useTranslation } from 'react-i18next';
import { localize, type I18nMap } from '../../lib/localize';
import type { I18nJson } from './washroomData';

/** jsonb name_i18n → the map localize() takes (non-string values are ignored). */
export function asI18nMap(value: I18nJson | null | undefined): I18nMap | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const map: I18nMap = {};
  for (const [k, v] of Object.entries(value)) if (typeof v === 'string') map[k] = v;
  return map;
}

/** Localized wash group / item name in the user's language. */
export function useLocalizedName() {
  const { i18n } = useTranslation();
  return (name: string | null | undefined, i18nMap: I18nJson | null | undefined): string =>
    name ? localize(name, asI18nMap(i18nMap), i18n.language) : '';
}

/** Accepts only #RRGGBB (the DB CHECK); anything else falls back to a neutral grey. */
export function safeColor(hex: string | null | undefined): string {
  return hex && /^#[0-9A-Fa-f]{6}$/.test(hex) ? hex : '#64748B';
}
