// Machine-down reasons (owner 2026-11-04): a quick pick, plus optional details ("Other" needs them).
// The server stores 1–200 characters with no control characters (set_machine_status). Pure module.

export const REASON_PICKS = [
  'waterPump',
  'soapDispenser',
  'wontStart',
  'leaking',
  'other',
] as const;
export type ReasonPick = (typeof REASON_PICKS)[number];

export const REASON_MAX = 200;

export type ReasonResult =
  { ok: true; reason: string } | { ok: false; error: 'pick' | 'details' | 'tooLong' };

/**
 * Builds the stored reason: "<pick label>" or "<pick label>: <details>"; for "other", the details alone.
 * `label` is the pick's text in the user's language.
 */
export function buildDownReason(
  pick: ReasonPick | null,
  label: string,
  details: string,
): ReasonResult {
  if (!pick) return { ok: false, error: 'pick' };
  const extra = details
    // eslint-disable-next-line no-control-regex -- strip control characters the server would refuse
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (pick === 'other' && !extra) return { ok: false, error: 'details' };
  const reason = pick === 'other' ? extra : extra ? `${label}: ${extra}` : label;
  if (reason.length > REASON_MAX) return { ok: false, error: 'tooLong' };
  return { ok: true, reason };
}
