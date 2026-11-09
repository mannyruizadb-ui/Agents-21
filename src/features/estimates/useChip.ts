import { useState } from 'react';
import { userStore } from '../../lib/scopedStore';
import { loadChip, saveChip, type Chip } from './categories';

/** The chosen chip, remembered per user on this device (scoped store; failures are ignored). */
export function useChip(userId: string): [Chip, (c: Chip) => void] {
  const [chip, setChip] = useState<Chip>(() => loadChip(userStore(userId)));
  return [
    chip,
    (c: Chip) => {
      setChip(c);
      saveChip(userStore(userId), c);
    },
  ];
}
