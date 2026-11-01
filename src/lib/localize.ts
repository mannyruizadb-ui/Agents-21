export type I18nMap = Record<string, string | null | undefined>;

/**
 * Pick the best translation of a data value (item name, message body).
 * Order: the user's language, then each fallback (plant default, then 'en'), then the
 * base value, which is stored in the plant's default language. Never returns an empty string.
 */
export function localize(
  base: string,
  i18n: I18nMap | null | undefined,
  lang: string,
  fallbacks: readonly string[] = ['en'],
): string {
  for (const code of [lang, ...fallbacks]) {
    const value = i18n?.[code]?.trim();
    if (value) return value;
  }
  return base;
}
