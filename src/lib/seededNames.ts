// Seeded names in the viewer's language (coordinator 2026-11-06; same rule as the push sender for
// routes): the plant's seeded machine, area and route names are English data ("Washer 1",
// "Washroom", "Route 21"). In Spanish they read "Lavadora 1", "Lavandería", "Ruta 21". Any other
// name stays exactly as the owner entered it. Pure module plus one hook.
import { useTranslation } from 'react-i18next';

type Kind = 'machine' | 'area' | 'route';

const NUMBERED: Record<Kind, [RegExp, string][]> = {
  machine: [
    [/^Washer (\w{1,10})$/i, 'Lavadora'],
    [/^Dryer (\w{1,10})$/i, 'Secadora'],
  ],
  area: [],
  route: [[/^Route (\w{1,10})$/i, 'Ruta']],
};

const EXACT: Record<Kind, Record<string, string>> = {
  machine: {},
  area: { washroom: 'Lavandería', finishing: 'Terminación' },
  route: {},
};

export function localName(kind: Kind, name: string, lang: string): string {
  const clean = name.replace(/\s+/g, ' ').trim();
  if (!lang.toLowerCase().startsWith('es')) return clean;
  const exact = EXACT[kind][clean.toLowerCase()];
  if (exact) return exact;
  for (const [re, word] of NUMBERED[kind]) {
    const m = re.exec(clean);
    if (m) return `${word} ${m[1]}`;
  }
  return clean;
}

/** Name formatters for the current language. */
export function useLocalNames() {
  const { i18n } = useTranslation();
  const lang = i18n.language;
  return {
    machine: (name: string | null | undefined) => (name ? localName('machine', name, lang) : ''),
    area: (name: string | null | undefined) => (name ? localName('area', name, lang) : ''),
    route: (name: string | null | undefined) => (name ? localName('route', name, lang) : ''),
  };
}
