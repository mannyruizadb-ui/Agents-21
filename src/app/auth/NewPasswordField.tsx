import { useTranslation } from 'react-i18next';
import { passwordProblem, passwordProblemKey } from '../../lib/passwordRules';

// A password field with the number pad by default and a "my password has letters" toggle (same style
// as sign-in), plus instant feedback on the password rule (src/lib/passwordRules.ts; the server
// decides). Used for a new password (change password, owner-chosen starting passwords) and, with
// `rule={false}`, for the current password.

export function NewPasswordField({
  id,
  label,
  value,
  onChange,
  letters,
  onLettersChange,
  shown,
  rule = true,
  autoComplete = 'new-password',
  invalid = false,
  describedBy,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (v: string) => void;
  letters: boolean;
  onLettersChange: (letters: boolean) => void;
  shown: boolean;
  /** Show the password rule and live feedback (new passwords only). */
  rule?: boolean;
  autoComplete?: 'new-password' | 'current-password';
  invalid?: boolean;
  describedBy?: string;
}) {
  const { t } = useTranslation();
  const problem = rule && value.length > 0 ? passwordProblem(value) : null;
  const ok = rule && value.length > 0 && problem === null;
  const feedbackId = `${id}-rule`;
  return (
    <div className="field password-field">
      <label htmlFor={id}>{label}</label>
      <input
        id={id}
        type={shown ? 'text' : 'password'}
        autoComplete={autoComplete}
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        inputMode={letters ? 'text' : 'numeric'}
        {...(letters ? {} : { pattern: '[0-9]*' })}
        required
        aria-invalid={invalid || problem === 'password_too_long' || undefined}
        aria-describedby={[rule ? feedbackId : null, describedBy].filter(Boolean).join(' ') || undefined}
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
      {rule && (
        <p id={feedbackId} className={problem && value.length >= 6 ? 'hint error' : 'hint'}>
          {ok ? (
            <>
              <span aria-hidden="true" className="password-ok-icon">
                ✓
              </span>{' '}
              {t('password.ok')}
            </>
          ) : problem && value.length >= 6 ? (
            <>
              <span aria-hidden="true" className="error-icon">
                ⚠
              </span>
              {t(`password.problems.${passwordProblemKey(problem)}`)}
            </>
          ) : (
            t('password.rule')
          )}
        </p>
      )}
      <button
        type="button"
        className="secondary password-keyboard"
        aria-pressed={letters}
        onClick={() => {
          onLettersChange(!letters);
          document.getElementById(id)?.focus();
        }}
      >
        {letters ? t('auth.useNumbers') : t('auth.useLetters')}
      </button>
    </div>
  );
}
