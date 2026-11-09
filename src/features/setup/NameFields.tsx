import { useTranslation } from 'react-i18next';

/**
 * A name in the plant's default language (the row's `name`) plus one field per other enabled
 * language (`name_i18n`). Languages are data: the list comes from the plant (otherLanguages()).
 * Visible label = accessible name; each field carries its `lang` so dictation uses the right one.
 */
export function NameFields({
  idBase,
  defaultLang,
  langs,
  name,
  names,
  onName,
  onNames,
  invalid,
}: {
  idBase: string;
  defaultLang: string;
  langs: readonly string[];
  name: string;
  names: Readonly<Record<string, string>>;
  onName: (v: string) => void;
  onNames: (v: Record<string, string>) => void;
  invalid?: boolean;
}) {
  const { t } = useTranslation();
  const langName = (l: string) => t(`setup.languages.${l}`, { defaultValue: l });
  return (
    <>
      <div className="field">
        <label htmlFor={`${idBase}-name`}>
          {t('setup.nameIn', { language: langName(defaultLang) })}
        </label>
        <input
          id={`${idBase}-name`}
          lang={defaultLang}
          value={name}
          maxLength={60}
          autoComplete="off"
          aria-invalid={invalid || undefined}
          onChange={(e) => onName(e.target.value)}
        />
      </div>
      {langs.map((l) => (
        <div className="field" key={l}>
          <label htmlFor={`${idBase}-name-${l}`}>
            {t('setup.nameIn', { language: langName(l) })} ({t('setup.optional')})
          </label>
          <input
            id={`${idBase}-name-${l}`}
            lang={l}
            value={names[l] ?? ''}
            maxLength={60}
            autoComplete="off"
            onChange={(e) => onNames({ ...names, [l]: e.target.value })}
          />
        </div>
      ))}
    </>
  );
}
