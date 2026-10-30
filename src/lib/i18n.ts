import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';

// Locale files are discovered from src/locales/*.json and loaded on demand, so adding a
// language is a new file plus a `languages` row — no code change (PRD H1).
const loaders = import.meta.glob<{ default: Record<string, unknown> }>('../locales/*.json');

export const availableLocales = Object.keys(loaders).map((path) =>
  path.replace(/^.*\/(.+)\.json$/, '$1'),
);

async function loadLocale(code: string): Promise<void> {
  const loader = loaders[`../locales/${code}.json`];
  if (!loader || i18n.hasResourceBundle(code, 'translation')) return;
  const module = await loader();
  i18n.addResourceBundle(code, 'translation', module.default, true, true);
}

export async function setLanguage(code: string): Promise<void> {
  await loadLocale(code);
  await i18n.changeLanguage(code);
  document.documentElement.lang = code;
}

export async function initI18n(): Promise<void> {
  const preferred = navigator.language.split('-')[0] ?? 'en';
  const initial = availableLocales.includes(preferred) ? preferred : 'en';
  await i18n.use(initReactI18next).init({
    lng: initial,
    fallbackLng: 'en',
    resources: {},
    interpolation: { escapeValue: false },
    returnNull: false,
  });
  await loadLocale('en');
  await setLanguage(initial);
}

export default i18n;
