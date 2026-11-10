import { useQuery, type QueryClient } from '@tanstack/react-query';
import { supabase } from '../../lib/supabase';
import type { Database } from '../../types/database';
import { unwrap } from '../washroom/rpcError';
import { availableLocales } from '../../lib/i18n';
import { otherLanguages } from './setupForm';

// Reads for the owner Setup tables (review 2026-11-09 item 8). Every query waits for the plant id,
// so nothing asks for `plant_id=eq.` (the empty-id 400 the review found). Writes are direct table
// writes through RLS and column grants, made by the pages.

type Tables = Database['public']['Tables'];

export type MachineKind = Tables['machines']['Row']['kind'];
export type SetupMachine = Pick<
  Tables['machines']['Row'],
  'id' | 'name' | 'name_i18n' | 'kind' | 'area_id' | 'active' | 'load_factor'
>;

export type SetupWashGroup = Pick<
  Tables['wash_groups']['Row'],
  | 'id'
  | 'name'
  | 'name_i18n'
  | 'color_hex'
  | 'category'
  | 'wash_formula_id'
  | 'loads_per_basket'
  | 'loads_per_bin'
  | 'allow_basket_estimates'
  | 'allow_bin_estimates'
  | 'default_estimate_unit'
  | 'sort_order'
  | 'active'
  | 'customer_id'
>;

export type SetupFormula = Pick<
  Tables['wash_formulas']['Row'],
  'id' | 'external_no' | 'name' | 'cycle_minutes' | 'active'
>;

export const setupKeys = {
  machines: (plantId: string) => ['setup-machines', plantId] as const,
  groups: (plantId: string) => ['setup-wash-groups', plantId] as const,
  formulas: (plantId: string) => ['setup-formulas', plantId] as const,
  languages: (plantId: string) => ['plant-languages', plantId] as const,
};

/** Every machine of the plant, inactive ones included. */
export function useSetupMachines(plantId: string | undefined) {
  return useQuery({
    queryKey: setupKeys.machines(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<SetupMachine[]> =>
      unwrap(
        await supabase
          .from('machines')
          .select('id, name, name_i18n, kind, area_id, active, load_factor')
          .eq('plant_id', plantId ?? '')
          .order('name'),
      ) ?? [],
  });
}

/** Every wash group of the plant (ours and customers'), inactive ones included. */
export function useSetupWashGroups(plantId: string | undefined) {
  return useQuery({
    queryKey: setupKeys.groups(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<SetupWashGroup[]> =>
      unwrap(
        await supabase
          .from('wash_groups')
          .select(
            'id, name, name_i18n, color_hex, category, wash_formula_id, loads_per_basket, loads_per_bin, allow_basket_estimates, allow_bin_estimates, default_estimate_unit, sort_order, active, customer_id',
          )
          .eq('plant_id', plantId ?? '')
          .order('sort_order')
          .order('name'),
      ) ?? [],
  });
}

/** Every washer program of the plant, retired ones included. */
export function useSetupFormulas(plantId: string | undefined) {
  return useQuery({
    queryKey: setupKeys.formulas(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<SetupFormula[]> =>
      unwrap(
        await supabase
          .from('wash_formulas')
          .select('id, external_no, name, cycle_minutes, active')
          .eq('plant_id', plantId ?? ''),
      ) ?? [],
  });
}

/** The plant's default and enabled languages (names per language are data, PRD H1). */
export function usePlantLanguages(plantId: string | undefined) {
  return useQuery({
    queryKey: setupKeys.languages(plantId ?? ''),
    enabled: !!plantId,
    queryFn: async (): Promise<{ default_language: string; enabled_languages: string[] } | null> =>
      unwrap(
        await supabase
          .from('plants')
          .select('default_language, enabled_languages')
          .eq('id', plantId ?? '')
          .maybeSingle(),
      ),
    staleTime: 60 * 60_000,
  });
}

/** Formula numbers sort as numbers where they are numbers ("2" before "10"). */
export function byFormulaNo(a: { external_no: string }, b: { external_no: string }): number {
  return a.external_no.localeCompare(b.external_no, undefined, { numeric: true });
}

/** After a setup write: refresh the setup lists and every screen that reads these tables. */
export function invalidateSetup(qc: QueryClient): void {
  for (const key of [
    'setup-machines',
    'setup-wash-groups',
    'setup-formulas',
    'machine-status',
    'washroom-board',
    'washers',
    'machine',
    'wash-groups',
    'formulas',
    'estimate-groups',
    'wash-formulas',
    'wash-group-categories',
    'wash-group-pace',
    'washer-capacity',
    'customer-groups',
    'customer-wash-groups',
    'machine-names',
    'queue',
    'soil',
  ])
    void qc.invalidateQueries({ queryKey: [key] });
}

/** The plant's default language (the base `name`) and the other languages to edit names in. */
export function useSetupLanguages(plantId: string | undefined): {
  defaultLang: string;
  langs: string[];
} {
  const q = usePlantLanguages(plantId);
  const defaultLang = q.data?.default_language ?? 'en';
  return {
    defaultLang,
    langs: otherLanguages(q.data?.enabled_languages, defaultLang, availableLocales),
  };
}
