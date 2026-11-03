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
  manageable: boolean;
}

export interface TempPasswordResult {
  user_id: string;
  username?: string;
  temp_password: string;
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
    }
  | { action: 'reset_password' | 'deactivate'; plant_id: string; user_id: string }
  | { action: 'change_own_password'; new_password: string };

/** `code` is a PRD §5.1 code (or USERNAME_TAKEN / INTERNAL / NETWORK); `reason` refines it. */
export class ManageUsersError extends Error {
  constructor(
    readonly code: string,
    readonly reason?: string,
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
    } | null;
    throw new ManageUsersError(payload?.code ?? 'INTERNAL', payload?.reason);
  }
  throw new ManageUsersError('NETWORK');
}
