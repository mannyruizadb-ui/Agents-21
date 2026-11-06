import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { SignOutButton } from '../auth/SignOutButton';
import { LanguageSwitch } from '../auth/LanguageSwitch';
import { useRequiredSession } from '../auth/sessionContext';
import { useOwnerPlants } from '../../features/admin/useOwnerPlants';
import { NotificationsCard } from '../../features/notifications/NotificationsCard';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { useAreas } from '../../features/washroom/washroomData';
import { TapAlarmBanner } from '../../features/washroom/TapAlarmBanner';
import { MyTaskCount } from '../../features/tasks/MyTaskCount';
import '../../lib/forms.css';
import './more.css';

// "More" (bottom-nav tab): every screen that isn't a tab, notifications, language and sign-out.
// Route: /control/more (the washer board is the home tab).

export function ControlHome() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const ownerPlants = useOwnerPlants(session.user.id);
  const areas = useAreas();
  const plantId = areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id).rolesFor(plantId);
  const isOwner = (ownerPlants.data?.length ?? 0) > 0 || roles.has('owner');
  const isManager = !isOwner && roles.has('manager');
  // Machine-down alerts go to owners and managers (owner 2026-11-04).
  const canGetAlerts = !!plantId && (roles.has('owner') || roles.has('manager'));

  const links: { to: string; label: string; show: boolean }[] = [
    { to: '/control/tasks', label: isOwner ? t('tasks.title') : t('tasks.myTitle'), show: isOwner },
    { to: '/control/estimates', label: t('control.estimates'), show: !isManager },
    { to: '/control/queue', label: t('control.queue'), show: isManager },
    { to: '/control/machines', label: t('machines.linkLabel'), show: true },
    { to: '/control/load-out/entry', label: t('loadOut.entryTitle'), show: isOwner || isManager },
    { to: '/control/people', label: t('people.title'), show: isOwner },
    { to: '/control/setup/machines', label: t('setup.machines.title'), show: isOwner },
    { to: '/control/setup/reasons', label: t('setup.reasons.title'), show: isOwner },
  ];

  return (
    <main className="form-page">
      <h1>{t('nav.more')}</h1>
      <TapAlarmBanner />
      {plantId && isManager && <MyTaskCount plantId={plantId} />}
      <ul className="more-menu">
        {links
          .filter((l) => l.show)
          .map((l) => (
            <li key={l.to}>
              <Link to={l.to}>
                <span>{l.label}</span>
                <span aria-hidden="true">›</span>
              </Link>
            </li>
          ))}
      </ul>
      {canGetAlerts && plantId && <NotificationsCard plantId={plantId} />}
      <section className="card">
        <LanguageSwitch />
      </section>
      <div className="actions">
        <SignOutButton />
      </div>
    </main>
  );
}
