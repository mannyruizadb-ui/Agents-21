import { supabase } from '../../lib/supabase';
import { unwrap } from '../washroom/rpcError';
import type { SubscriptionKeys } from './pushSupport';

// The two server calls for push subscriptions (db-engineer, 2026-11-04). The server ties the row to
// the signed-in account and checks the plant role; the client sends only this device's keys.

export async function savePushSubscription(
  plantId: string,
  keys: SubscriptionKeys,
  userAgent: string,
): Promise<void> {
  unwrap(
    await supabase.rpc('save_push_subscription', {
      p_plant_id: plantId,
      p_endpoint: keys.endpoint,
      p_p256dh: keys.p256dh,
      p_auth: keys.auth,
      p_user_agent: userAgent.slice(0, 300),
    }),
  );
}

export async function removePushSubscription(endpoint: string): Promise<void> {
  unwrap(await supabase.rpc('remove_push_subscription', { p_endpoint: endpoint }));
}
