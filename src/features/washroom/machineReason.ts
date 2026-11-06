// Machine-down reasons (owner 2026-11-04): a preset reason CODE (stored as
// machine_status_events.reason_code, translated by each viewer's screen) plus optional free-text
// details (required for "other"). Details: 1–200 characters, no control characters
// (set_machine_status). The form asks people to describe the problem, not the person. Pure module.

import type { Database } from '../../types/database';

export type ReasonCode = NonNullable<
  Database['public']['Functions']['set_machine_status']['Args']['p_reason_code']
>;

export const REASON_CODES: readonly ReasonCode[] = [
  'water_pump',
  'soap_dispenser',
  'wont_start',
  'leaking',
  'other',
];

export const REASON_MAX = 200;

export type ReasonResult =
  | { ok: true; code: ReasonCode; details: string | null }
  | { ok: false; error: 'pick' | 'details' | 'tooLong' };

/** Cleans the details and checks the server's rules. */
export function buildDownReason(code: ReasonCode | null, details: string): ReasonResult {
  if (!code) return { ok: false, error: 'pick' };
  const extra = details
    // eslint-disable-next-line no-control-regex -- strip control characters the server would refuse
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (code === 'other' && !extra) return { ok: false, error: 'details' };
  if (extra.length > REASON_MAX) return { ok: false, error: 'tooLong' };
  return { ok: true, code, details: extra || null };
}

export function isReasonCode(v: unknown): v is ReasonCode {
  return typeof v === 'string' && (REASON_CODES as readonly string[]).includes(v);
}

/**
 * The text a viewer reads: the preset in their language, then the details ("Water pump: grinding
 * noise"). "other" shows the details alone. A row from before reason codes shows its old text.
 * `label` translates a code.
 */
export function reasonText(
  code: string | null | undefined,
  details: string | null | undefined,
  label: (code: ReasonCode) => string,
): string | null {
  const d = details?.trim() || null;
  if (!isReasonCode(code)) return d;
  if (code === 'other') return d ?? label('other');
  return d ? `${label(code)}: ${d}` : label(code);
}
