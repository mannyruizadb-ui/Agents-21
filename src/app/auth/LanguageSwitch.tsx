import { useTranslation } from 'react-i18next';
import { availableLocales, setLanguage } from '../../lib/i18n';
import { languageNativeName } from '../../lib/languagePrefs';

/**
 * One button per locale file that exists (src/locales/*.json), named in its own language.
 * Works before sign-in, when the languages table isn't readable yet. The choice is remembered on
 * this device. Visible text = accessible name; aria-pressed marks the current language.
 */
export function LanguageSwitch() {
  const { t, i18n } = useTranslation();
  const current = i18n.resolvedLanguage ?? i18n.language;

  return (
    <div className="language-switch" role="group" aria-labelledby="language-switch-label">
      <span id="language-switch-label" className="language-switch-label">
        {t('language.label')}
      </span>
      <div className="actions">
        {availableLocales.map((code) => (
          <button
            key={code}
            type="button"
            lang={code}
            className={code === current ? undefined : 'secondary'}
            aria-pressed={code === current}
            onClick={() => void setLanguage(code, { remember: true })}
          >
            {languageNativeName(code)}
          </button>
        ))}
      </div>
    </div>
  );
}
