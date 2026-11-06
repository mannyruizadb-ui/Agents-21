import { useTranslation } from 'react-i18next';
import type { TileId } from './homePrefs';

/** The tile names, for Customize. */
export function useTileLabel() {
  const { t } = useTranslation();
  return (id: TileId, isOwner: boolean): string => {
    switch (id) {
      case 'washers':
        return t('nav.washers');
      case 'machinesDown':
        return t('home.machinesDown');
      case 'nextTruck':
        return t('loadOut.nextLabel');
      case 'tasks':
        return isOwner ? t('tasks.title') : t('tasks.myTitle');
      case 'dirtyWork':
        return t('home.dirtyWork');
      case 'queue':
        return t('nav.queue');
      case 'alerts':
        return t('nav.alerts');
    }
  };
}
