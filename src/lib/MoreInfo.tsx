import { useId, useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import './forms.css';

// Owner 2026-11-09: "I don't like all the instructions everywhere under the buttons." Explanations
// worth keeping for new users sit behind a small "ⓘ More info" button instead of a paragraph.
// Real <button>, visible text = accessible name (the ⓘ is hidden from screen readers), ≥ 48 px
// target, aria-expanded + aria-controls. Closed by default; nothing is remembered.

export function MoreInfo({
  children,
  className = '',
  id: textId,
}: {
  children: ReactNode;
  className?: string;
  /** Id of the text, so a field can point aria-describedby at it (read even while closed). */
  id?: string;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const autoId = useId();
  const id = textId ?? autoId;
  return (
    <div className={`more-info ${className}`.trim()}>
      <button
        type="button"
        className="more-info-button"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen((o) => !o)}
      >
        <span className="more-info-icon" aria-hidden="true">
          ⓘ
        </span>
        <span>{t('common.moreInfo')}</span>
      </button>
      <div id={id} className="more-info-text" hidden={!open}>
        {children}
      </div>
    </div>
  );
}
