// Seeded names in the viewer's language (coordinator 2026-11-06; same rule as the push sender for
// routes): the plant's seeded machine, area and route names are English data ("Washer 1",
// "Washroom", "Route 21"). In Spanish they read "Lavadora 1", "Lavandería", "Ruta 21". Any other
// name stays exactly as the owner entered it. Pure module plus one hook.
// 2026-11-09 (review item 10): the other seeded machines too (Ironer → Planchadora, …), and a
// machine's own name_i18n (machines.name_i18n, owner-edited in Setup → Machines) wins over both.
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
  // Owner-approved Spanish (2026-11-09); the same words as the DB backfill of machines.name_i18n.
  machine: {
    ironer: 'Planchadora',
    folder: 'Dobladora',
    boiler: 'Caldera',
    compressor: 'Compresor',
    'water pump': 'Bomba de agua',
    'soap machine': 'Máquina de jabón',
    'wrapping machine': 'Empacadora',
  },
  area: { washroom: 'Lavandería', finishing: 'Terminación' },
  route: {},
};

/** The name stored for this language in a name_i18n map, if any (base language tag too). */
function fromMap(i18n: unknown, lang: string): string | null {
  if (!i18n || typeof i18n !== 'object' || Array.isArray(i18n)) return null;
  const map = i18n as Record<string, unknown>;
  for (const code of [lang, lang.split('-')[0] ?? lang]) {
    const v = map[code];
    if (typeof v === 'string' && v.trim() !== '') return v.trim();
  }
  return null;
}

export function localName(kind: Kind, name: string, lang: string, i18n?: unknown): string {
  const own = fromMap(i18n, lang);
  if (own) return own;
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
    /** `i18n` = the machine's name_i18n where the read carries it (it wins over the seeded words). */
    machine: (name: string | null | undefined, i18n?: unknown) =>
      name ? localName('machine', name, lang, i18n) : '',
    area: (name: string | null | undefined) => (name ? localName('area', name, lang) : ''),
    route: (name: string | null | undefined) => (name ? localName('route', name, lang) : ''),
  };
}
