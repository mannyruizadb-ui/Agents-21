import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { IconWarning } from '../washroom/Icons';

// Name + PIN pieces shared by the screens that confirm entries with a staff session (A8):
// estimates and customer deliveries.

/**
 * 4-digit PIN box. Not type=password and no username field nearby, so password managers don't offer
 * to save it; autocomplete=one-time-code, numeric keypad, masked with CSS.
 */
export function PinInput({
  value,
  onChange,
  id = 'est-pin',
}: {
  value: string;
  onChange: (v: string) => void;
  id?: string;
}) {
  const { t } = useTranslation();
  return (
    <div className="field">
      <label htmlFor={id}>{t('estimates.pinLabel')}</label>
      <input
        id={id}
        name="entry-pin"
        className="pin-input"
        type="text"
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]*"
        maxLength={4}
        value={value}
        onChange={(e) => onChange(e.target.value.replace(/\D/g, '').slice(0, 4))}
        data-1p-ignore="true"
        data-lpignore="true"
        data-form-type="other"
        aria-describedby={`${id}-hint`}
      />
      <p id={`${id}-hint`} className="hint">
        {t('estimates.pinHint')}
      </p>
    </div>
  );
}

/** A waiting batch needs its PIN again (wrong, changed, or the person was locked). */
export function RePin({
  staffId,
  onPin,
}: {
  staffId: string;
  onPin: (staffId: string, pin: string) => Promise<number>;
}) {
  const { t } = useTranslation();
  const [pin, setPin] = useState('');
  return (
    <form
      className="notice notice-bad"
      noValidate
      autoComplete="off"
      onSubmit={(e) => {
        e.preventDefault();
        if (/^\d{4}$/.test(pin)) void onPin(staffId, pin).then(() => setPin(''));
      }}
    >
      <p role="alert">
        <IconWarning /> {t('estimates.needsPin')}
      </p>
      <PinInput id="repin" value={pin} onChange={setPin} />
      <button type="submit">{t('estimates.sendNow')}</button>
    </form>
  );
}
