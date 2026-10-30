import { useTranslation } from 'react-i18next';

export function DisplayPage() {
  const { t } = useTranslation();
  return <main>{t('display.placeholder')}</main>;
}
