// Guarded sign-out (security review 2026-11-04, H1). Pending entries and taps live in the signed-in
// account's own storage. Before signing out with something pending, the person chooses:
//  - "Send now": try to send everything, then sign out (anything that still can't send stays kept);
//  - "Keep for next time": sign out and leave this account's storage exactly as it is.
// Nothing is ever sent or read for another account. Pure: sources and signOut are injected.

export interface PendingSource {
  /** How many entries/taps are waiting for this account. */
  count(): number;
  /** Try to send them now (must not throw). */
  flush(): Promise<unknown>;
}

export function pendingTotal(sources: readonly PendingSource[]): number {
  return sources.reduce((n, s) => n + s.count(), 0);
}

export type SignOutChoice = 'send' | 'keep';

export async function signOutWith(
  choice: SignOutChoice,
  sources: readonly PendingSource[],
  signOut: () => Promise<unknown>,
): Promise<{ stillPending: number }> {
  if (choice === 'send') {
    for (const s of sources) {
      try {
        await s.flush();
      } catch {
        // kept for next time
      }
    }
  }
  const stillPending = pendingTotal(sources);
  await signOut();
  return { stillPending };
}
