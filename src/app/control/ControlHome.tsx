import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { SignOutButton } from '../auth/SignOutButton';
import { useRequiredSession } from '../auth/sessionContext';
import { useOwnerPlants } from '../../features/admin/useOwnerPlants';
import { NotificationsCard } from '../../features/notifications/NotificationsCard';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { useAreas } from '../../features/washroom/washroomData';
import { TapAlarmBanner } from '../../features/washroom/TapAlarmBanner';
import { MyTaskCount } from '../../features/tasks/MyTaskCount';
import '../../lib/forms.css';

export function ControlHome() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id).rolesFor(plantId);
  // Machine-down alerts go to owners and managers (owner 2026-11-04).
  const canGetAlerts = !!plantId && (roles.has('owner') || roles.has('manager'));

  return (
    <main className="form-page">
      <h1>{t('app.name')}</h1>
      <TapAlarmBanner />
      {plantId && !roles.has('owner') && roles.has('manager') && <MyTaskCount plantId={plantId} />}
      <p>{t('control.placeholder')}</p>
      <div className="actions">
        <Link className="button-link" to="/control/washers">
          {t('control.washerBoard')}
        </Link>
        <Link className="button-link" to="/control/estimates">
          {t('control.estimates')}
        </Link>
        <Link className="button-link" to="/control/queue">
          {t('control.queue')}
        </Link>
        {(roles.has('owner') || roles.has('manager')) && (
          <Link className="button-link" to="/control/tasks">
            {roles.has('owner') ? t('tasks.title') : t('tasks.myTitle')}
          </Link>
        )}
        <Link className="button-link" to="/control/load-out">
          {t('loadOut.boardTitle')}
        </Link>
        {(ownerPlants.data?.length ?? 0) > 0 && (
          <Link className="button-link" to="/control/people">
            {t('people.title')}
          </Link>
        )}
        {(ownerPlants.data?.length ?? 0) > 0 && (
          <Link className="button-link" to="/control/setup/machines">
            {t('setup.machines.title')}
          </Link>
        )}
        {(ownerPlants.data?.length ?? 0) > 0 && (
          <Link className="button-link" to="/control/setup/reasons">
            {t('setup.reasons.title')}
          </Link>
        )}
        <SignOutButton />
      </div>
      {canGetAlerts && plantId && <NotificationsCard plantId={plantId} />}
    </main>
  );
}
