import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { unwrap } from './rpcError';
import { DEFAULT_REASON_CODES, reasonLabel, type ReasonOption } from './machineReason';

// The plant's machine-down reasons (machine_down_reasons, owner-editable in Setup). Every role of the
// plant can read them (RLS); only the owner writes.

export type DownReasonRow = Database['public']['Tables']['machine_down_reasons']['Row'];

export function useDownReasons(plantId: string | undefined) {
  return useQuery({
    queryKey: ['down-reasons', plantId ?? ''],
    enabled: !!plantId,
    queryFn: async (): Promise<DownReasonRow[]> =>
      unwrap(
        await supabase
          .from('machine_down_reasons')
          .select('*')
          .eq('plant_id', plantId ?? '')
          .order('sort_order')
          .order('code'),
      ) ?? [],
    staleTime: 60_000,
  });
}

/** (code, label_i18n?) → the label in the user's language, with the locale strings as fallback. */
export function useReasonLabeler() {
  const { t, i18n } = useTranslation();
  return (code: string, labelI18n?: unknown): string =>
    reasonLabel(code, labelI18n, i18n.language, (c) => {
      const key = `machines.reasons.${c}`;
      return i18n.exists(key) ? t(key) : null;
    });
}

/**
 * Active reasons to pick from, in the plant's order. Falls back to the 5 default codes (locale
 * labels) only when the list can't be loaded or is empty, so marking a machine down never blocks.
 */
export function useReasonOptions(plantId: string | undefined): {
  options: ReasonOption[];
  fromPlant: boolean;
  isPending: boolean;
} {
  const reasons = useDownReasons(plantId);
  const label = useReasonLabeler();
  const active = (reasons.data ?? []).filter((r) => r.active);
  if (active.length > 0) {
    return {
      options: active.map((r) => ({
        code: r.code,
        label: label(r.code, r.label_i18n),
        requiresDetails: r.requires_details,
      })),
      fromPlant: true,
      isPending: false,
    };
  }
  return {
    options: DEFAULT_REASON_CODES.map((c) => ({
      code: c,
      label: label(c),
      requiresDetails: c === 'other',
    })),
    fromPlant: false,
    isPending: reasons.isPending,
  };
}
