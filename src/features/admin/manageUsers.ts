import { FunctionsHttpError } from '@supabase/supabase-js';
import { supabase } from '../../lib/supabase';

// Client for the manage-users Edge Function (PRD A4, owner decision 2026-11-03).

export type AssignableRole = 'owner' | 'manager' | 'lead' | 'viewer';
export const ASSIGNABLE_ROLES: readonly AssignableRole[] = ['manager', 'lead', 'viewer', 'owner'];

export interface PersonMembership {
  role: AssignableRole;
  org_wide: boolean;
  can_manage_staff: boolean;
}

export interface Person {
  user_id: string;
  /** null for an account outside the username domain; its email is never sent or shown. */
  username: string | null;
  display_name: string | null;
  memberships: PersonMembership[];
  is_self: boolean;
  /** Set while the person's sign-in is locked (5 wrong passwords); ISO time. */
  locked_until: string | null;
  manageable: boolean;
}

export interface TempPasswordResult {
  user_id: string;
  username?: string;
  /** null when the owner typed the password (it is never echoed back). */
  temp_password: string | null;
}

type Body =
  | { action: 'list'; plant_id: string }
  | {
      action: 'create';
      plant_id: string;
      username: string;
      display_name: string;
      role: AssignableRole;
      can_manage_staff: boolean;
      /** Optional starting password chosen by the owner (else a generated one). */
      password?: string;
    }
  | { action: 'reset_password'; plant_id: string; user_id: string; password?: string }
  | { action: 'deactivate' | 'unlock'; plant_id: string; user_id: string }
  | { action: 'change_own_password'; current_password: string; new_password: string };

/** `code` is a PRD §5.1 code (or USERNAME_TAKEN / INTERNAL / NETWORK); `reason` refines it. */
export class ManageUsersError extends Error {
  constructor(
    readonly code: string,
    readonly reason?: string,
    readonly retryAfterSeconds?: number,
  ) {
    super(code);
  }
}

export async function callManageUsers<T>(body: Body): Promise<T> {
  const { data, error } = await supabase.functions.invoke<T>('manage-users', { body });
  if (!error) return data as T;
  if (error instanceof FunctionsHttpError) {
    const payload = (await (error.context as Response).json().catch(() => null)) as {
      code?: string;
      reason?: string;
      retry_after_seconds?: number;
    } | null;
    throw new ManageUsersError(
      payload?.code ?? 'INTERNAL',
      payload?.reason,
      typeof payload?.retry_after_seconds === 'number' ? payload.retry_after_seconds : undefined,
    );
  }
  throw new ManageUsersError('NETWORK');
}
