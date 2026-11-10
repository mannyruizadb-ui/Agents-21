import { describe, expect, it, vi } from 'vitest';

vi.mock('../../lib/supabase', () => ({ supabase: {} }));
vi.mock('../../features/washroom/useTapSync', () => ({}));
vi.mock('../../features/estimates/useEstimateOutbox', () => ({}));
vi.mock('../../features/deliveries/useDeliveryOutbox', () => ({}));
vi.mock('../../features/notifications/pushClient', () => ({}));

import { signOutScope } from './signOutActions';

describe('signOutScope', () => {
  it('ends only this device session on the shared plant iPad', () => {
    expect(signOutScope(true)).toEqual({ scope: 'local' });
  });
  it('keeps the default (all sessions) on a personal device', () => {
    expect(signOutScope(false)).toBeUndefined();
  });
});
