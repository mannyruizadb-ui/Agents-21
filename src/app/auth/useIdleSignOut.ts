import { useEffect, useState } from 'react';
import { signOutWith } from './signOutFlow';
import { signOutDevice, sourcesFor } from './signOutActions';
import {
  isIdle,
  isSharedDevice,
  markIdleSignOut,
  readLastActive,
  readWho,
  setWaiting,
  SHARED_DEVICE_EVENT,
  writeLastActive,
} from './sharedDevice';

// Shared plant iPad (owner 2026-11-10): whoever is signed in is signed out after 10 minutes without a
// touch, key or scroll, so the next person never works under someone else's name. The last activity
// is kept in storage too, so an iPad that slept or reloaded past the limit signs out when it wakes.
// Anything waiting to send is sent first; what still can't send stays kept in that person's own
// storage and goes the next time they sign in (the same guarded sign-out as the button, choice "send").
// Does nothing on any other device.

const CHECK_EVERY_MS = 30_000;
/** Storage writes are throttled; the in-memory value is exact. */
const WRITE_EVERY_MS = 15_000;
const ACTIVITY = ['pointerdown', 'keydown', 'touchstart', 'wheel', 'scroll'] as const;

export function useIdleSignOut(userId: string | null) {
  // Re-arms when this device is marked or unmarked while someone is signed in (review L3).
  const [shared, setShared] = useState(isSharedDevice);
  useEffect(() => {
    const onChange = () => setShared(isSharedDevice());
    window.addEventListener(SHARED_DEVICE_EVENT, onChange);
    return () => window.removeEventListener(SHARED_DEVICE_EVENT, onChange);
  }, []);

  useEffect(() => {
    if (!userId || !shared) return;
    let last = readLastActive() ?? Date.now();
    let written = 0;
    let signingOut = false;

    const signOutNow = () => {
      if (signingOut) return;
      signingOut = true;
      markIdleSignOut();
      const who = readWho();
      void signOutWith('send', sourcesFor(userId), signOutDevice)
        .then(({ stillPending }) => {
          // Left unsent: kept for this person; the name screen says so (review M2).
          if (who) setWaiting(who, stillPending);
        })
        .catch(() => {
          signingOut = false;
        });
    };
    const check = () => {
      if (isIdle(last, Date.now())) signOutNow();
    };
    // Every sign-in on this device stamps the time (sign-in screen), so an old value here means the
    // device sat unused with someone signed in (asleep, or the app was closed): sign out now.
    check();

    const onActivity = () => {
      last = Date.now();
      if (last - written >= WRITE_EVERY_MS) {
        written = last;
        writeLastActive(last);
      }
    };
    const onVisible = () => {
      if (document.visibilityState === 'visible') check();
    };
    for (const e of ACTIVITY)
      window.addEventListener(e, onActivity, { passive: true, capture: true });
    document.addEventListener('visibilitychange', onVisible);
    const id = window.setInterval(check, CHECK_EVERY_MS);
    return () => {
      for (const e of ACTIVITY) window.removeEventListener(e, onActivity, { capture: true });
      document.removeEventListener('visibilitychange', onVisible);
      window.clearInterval(id);
    };
  }, [userId, shared]);
}
