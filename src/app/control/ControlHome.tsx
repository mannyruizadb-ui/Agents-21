import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { SignOutButton } from '../auth/SignOutButton';
import { LanguageSwitch } from '../auth/LanguageSwitch';
import { useRequiredSession } from '../auth/sessionContext';
import { useOwnerPlants } from '../../features/admin/useOwnerPlants';
import { NotificationsCard } from '../../features/notifications/NotificationsCard';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { useAreas } from '../../features/washroom/washroomData';
import { useLoadOutPermissions, usePlant } from '../../features/loadout/loadOutData';
import type { ReactNode } from 'react';
import {
  IconBell,
  IconBins,
  IconEdit,
  IconGear,
  IconHome,
  IconList,
  IconMachineDown,
  IconPeople,
  IconQueue,
  IconTasks,
  IconTruck,
  IconWasher,
} from '../../features/washroom/Icons';
import '../../lib/forms.css';
import './more.css';

// "More" (bottom-nav tab; owner 2026-11-06, round 2): a grid of EVERY screen the user can open, with
// big icon tiles, then notifications, language and sign-out. Route: /control/more.

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

  const isStaff = isOwner || isManager;
  const plant = usePlant(plantId);
  const loadOutPerms = useLoadOutPermissions(session.user.id, plant.data ?? undefined);
  const links: { to: string; label: string; icon: ReactNode; show: boolean }[] = [
    { to: '/control', label: t('nav.home'), icon: <IconHome />, show: true },
    { to: '/control/washers', label: t('nav.washers'), icon: <IconWasher />, show: true },
    { to: '/control/queue', label: t('nav.queue'), icon: <IconQueue />, show: true },
    { to: '/control/estimates', label: t('nav.estimates'), icon: <IconBins />, show: isStaff },
    { to: '/control/load-out', label: t('loadOut.boardTitle'), icon: <IconTruck />, show: true },
    {
      to: '/control/load-out/entry',
      label: t('loadOut.entryTitle'),
      icon: <IconEdit />,
      show: loadOutPerms.data?.canEnter ?? false,
    },
    {
      to: '/control/tasks',
      label: isOwner ? t('tasks.title') : t('tasks.myTitle'),
      icon: <IconTasks />,
      show: isStaff,
    },
    { to: '/control/alerts', label: t('nav.alerts'), icon: <IconBell />, show: isStaff },
    {
      to: '/control/machines',
      label: t('machines.linkLabel'),
      icon: <IconMachineDown />,
      show: true,
    },
    { to: '/control/people', label: t('people.title'), icon: <IconPeople />, show: isOwner },
    {
      to: '/control/setup/machines',
      label: t('setup.machines.title'),
      icon: <IconGear />,
      show: isOwner,
    },
    {
      to: '/control/setup/pins',
      label: t('setup.pins.title'),
      icon: <IconPeople />,
      show: isOwner,
    },
    {
      to: '/control/setup/reasons',
      label: t('setup.reasons.title'),
      icon: <IconList />,
      show: isOwner,
    },
  ];

  return (
    <main className="form-page">
      <h1>{t('nav.more')}</h1>
      <ul className="more-grid">
        {links
          .filter((l) => l.show)
          .map((l) => (
            <li key={l.to}>
              <Link to={l.to}>
                <span className="more-icon" aria-hidden="true">
                  {l.icon}
                </span>
                <span className="more-label">{l.label}</span>
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
