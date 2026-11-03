// Request validation and temporary passwords for manage-users (PRD A4, owner decision 2026-11-03).
// Pure module: no network, no Deno.env, so validation_test.ts can cover it fully.
import { z } from 'zod';
import { USERNAME_PATTERN } from '../_shared/loginId.ts';

export const ASSIGNABLE_ROLES = ['owner', 'manager', 'lead', 'viewer'] as const;

/** Supabase Auth (bcrypt) only uses the first 72 bytes of a password. */
export const PASSWORD_MIN_CHARS = 10;
export const PASSWORD_MAX_BYTES = 72;

// No control characters; profiles.full_name CHECK is ≤ 120 chars, trimmed, no control chars.
const displayName = z
  .string()
  .trim()
  .min(1)
  .max(80)
  .regex(/^[^\p{Cc}]+$/u, 'no control characters');

// z.guid(): any 8-4-4-4-12 hex id (seeded ids are not always RFC 4122 variants).
const plantId = z.guid();

const createSchema = z.strictObject({
  action: z.literal('create'),
  plant_id: plantId,
  username: z.string().regex(USERNAME_PATTERN, 'lowercase a-z 0-9 . _ -, 3-32 chars'),
  display_name: displayName,
  role: z.enum(ASSIGNABLE_ROLES),
  can_manage_staff: z.boolean().optional().default(false),
});

const listSchema = z.strictObject({ action: z.literal('list'), plant_id: plantId });

const targetSchema = (action: 'reset_password' | 'deactivate') =>
  z.strictObject({ action: z.literal(action), plant_id: plantId, user_id: z.guid() });

const changeOwnSchema = z.strictObject({
  action: z.literal('change_own_password'),
  new_password: z
    .string()
    .min(PASSWORD_MIN_CHARS, `at least ${PASSWORD_MIN_CHARS} characters`)
    .refine(
      (p) => new TextEncoder().encode(p).length <= PASSWORD_MAX_BYTES,
      `at most ${PASSWORD_MAX_BYTES} bytes`,
    ),
});

export const requestSchema = z
  .discriminatedUnion('action', [
    createSchema,
    listSchema,
    targetSchema('reset_password'),
    targetSchema('deactivate'),
    changeOwnSchema,
  ])
  .superRefine((v, ctx) => {
    // Mirrors CHECK memberships_can_manage_staff_manager_only (the DB enforces it too).
    if (v.action === 'create' && v.can_manage_staff && v.role !== 'manager') {
      ctx.addIssue({
        code: 'custom',
        path: ['can_manage_staff'],
        message: 'only valid with role manager',
      });
    }
  });

export type ManageUsersRequest = z.infer<typeof requestSchema>;

export type ParseResult =
  { ok: true; value: ManageUsersRequest } | { ok: false; fields: string[]; reason?: string };

/** Parses a request body. Errors name fields and rules only; values are never echoed. */
export function parseRequest(body: unknown): ParseResult {
  const result = requestSchema.safeParse(body);
  if (result.success) return { ok: true, value: result.data };
  const fields = [...new Set(result.error.issues.map((i) => i.path.join('.') || 'body'))].sort();
  const pw = result.error.issues.find((i) => i.path[0] === 'new_password');
  const reason = pw
    ? pw.code === 'too_small'
      ? 'password_too_short'
      : pw.code === 'custom'
        ? 'password_too_long'
        : 'password_invalid'
    : undefined;
  return { ok: false, fields, reason };
}

// No look-alike characters: no I, O, l, o, 0, 1. 56 symbols → 16 symbols ≈ 93 bits.
export const TEMP_PASSWORD_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';

/**
 * Crypto-random temporary password, shown to the owner once: 4 groups of 4 separated by
 * hyphens (19 chars), easy to read aloud and type on a phone. Rejection sampling avoids bias.
 */
export function generateTempPassword(
  random: (bytes: Uint8Array) => Uint8Array = (b) => crypto.getRandomValues(b),
): string {
  const n = TEMP_PASSWORD_ALPHABET.length;
  const limit = 256 - (256 % n);
  const out: string[] = [];
  while (out.length < 16) {
    for (const byte of random(new Uint8Array(32))) {
      if (byte < limit && out.length < 16) out.push(TEMP_PASSWORD_ALPHABET[byte % n] as string);
    }
  }
  return [0, 4, 8, 12].map((i) => out.slice(i, i + 4).join('')).join('-');
}
