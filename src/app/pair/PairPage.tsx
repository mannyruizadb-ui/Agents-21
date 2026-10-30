import { useTranslation } from 'react-i18next';

export function PairPage() {
  const { t } = useTranslation();
  return <main>{t('pair.placeholder')}</main>;
}
