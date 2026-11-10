import { useTranslation } from 'react-i18next';
import { localize } from '../../lib/localize';
import { asI18nMap } from '../washroom/localizedName';
import type { I18nJson } from '../washroom/washroomData';
import type { FinishItem } from './finishedLogic';

/** An item's name in the user's language (name + name_i18n through the shared localize helper). */
export function useItemName() {
  const { i18n } = useTranslation();
  return (item: Pick<FinishItem, 'name' | 'name_i18n'> | undefined): string =>
    item ? localize(item.name, asI18nMap(item.name_i18n as I18nJson), i18n.language) : '';
}
