import { supabase } from '../../lib/supabase';
import { flushTaps, pendingTapCount } from '../../features/washroom/useTapSync';
import { flushEstimates, pendingEstimateCount } from '../../features/estimates/useEstimateOutbox';
import { flushDeliveries, pendingDeliveryCount } from '../../features/deliveries/useDeliveryOutbox';
import { flushFinished, pendingFinishedCount } from '../../features/finished/useFinishedOutbox';
import { removeThisDevicePush } from '../../features/notifications/pushClient';
import type { PendingSource } from './signOutFlow';
import { isSharedDevice } from './sharedDevice';

// The side-effecting halves of the guarded sign-out (signOutFlow.ts holds the pure flow). Shared by the
// Sign out button and the shared plant iPad's idle sign-out.

/** Every sign-out first removes this device's push subscription, so the next person on the device
 * doesn't get the last person's machine-down alerts. On the shared plant iPad only THIS device's
 * session ends (security review M1): the person stays signed in on their own phone. */
export async function signOutDevice(): Promise<void> {
  await removeThisDevicePush();
  await supabase.auth.signOut(signOutScope(isSharedDevice()));
}

/** Pure: `local` on the shared plant iPad, otherwise the default (every session of the account). */
export function signOutScope(shared: boolean): { scope: 'local' } | undefined {
  return shared ? { scope: 'local' } : undefined;
}

/** This account's waiting taps, estimates, deliveries and finished-goods lines. */
export function sourcesFor(userId: string): PendingSource[] {
  return [
    { count: () => pendingTapCount(userId), flush: () => flushTaps(userId) },
    { count: () => pendingEstimateCount(userId), flush: () => flushEstimates(userId) },
    { count: () => pendingDeliveryCount(userId), flush: () => flushDeliveries(userId) },
    { count: () => pendingFinishedCount(userId), flush: () => flushFinished(userId) },
  ];
}
