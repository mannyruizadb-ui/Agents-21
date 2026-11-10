import { Link } from 'react-router';
import { useTranslation } from 'react-i18next';
import { SignOutButton } from '../auth/SignOutButton';
import { LanguageSwitch } from '../auth/LanguageSwitch';
import { useRequiredSession } from '../auth/sessionContext';
import { useOwnerPlants } from '../../features/admin/useOwnerPlants';
import { NotificationsCard } from '../../features/notifications/NotificationsCard';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { pickArea, useAreas } from '../../features/washroom/washroomData';
import { useLoadOutPermissions, usePlant } from '../../features/loadout/loadOutData';
import type { ReactNode } from 'react';
import {
  IconBell,
  IconBins,
  IconCustomer,
  IconEdit,
  IconGear,
  IconList,
  IconMachineDown,
  IconPeople,
  IconQueue,
  IconReady,
  IconTasks,
  IconWasher,
} from '../../features/washroom/Icons';
import { useCustomers } from '../../features/deliveries/deliveriesData';
import { asI18nMap } from '../../features/washroom/localizedName';
import { localize } from '../../lib/localize';
import '../../lib/forms.css';
import './more.css';

// "More" (bottom-nav tab; owner 2026-11-06, round 2; review 2026-11-09 item 9): only the screens
// that are NOT already in the nav, grouped "Daily" and "Setup" (owner only), then the account part:
// change my password, notifications, language and sign-out. Route: /control/more. The nav is
//   owner and others: Home · Washers · Queue · Load-out · More
//   managers:         Home · Washers · Estimates · Load-out · More   (src/app/control/AppNav.tsx)

interface Tile {
  to: string;
  label: string;
  icon: ReactNode;
  show: boolean;
}

function TileGrid({ id, title, tiles }: { id: string; title: string; tiles: Tile[] }) {
  const shown = tiles.filter((l) => l.show);
  if (shown.length === 0) return null;
  return (
    <section aria-labelledby={id}>
      <h2 id={id}>{title}</h2>
      <ul className="more-grid">
        {shown.map((l) => (
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
    </section>
  );
}

export function ControlHome() {
  const { t, i18n } = useTranslation();
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
  const customers = useCustomers(isStaff ? plantId : undefined);
  const activeCustomers = (customers.data ?? []).filter((c) => c.active);
  const onlyCustomer = activeCustomers.length === 1 ? activeCustomers[0] : undefined;
  const dropOffLabel = onlyCustomer
    ? t('more.dropOffs', {
        name: localize(onlyCustomer.name, asI18nMap(onlyCustomer.name_i18n), i18n.language),
      })
    : t('deliveries.title');

  const hasFinishing = !!pickArea(areas.data, 'finishing');
  const daily: Tile[] = [
    {
      to: '/control/finished',
      label: t('finished.title'),
      icon: <IconReady />,
      show: isStaff && hasFinishing,
    },
    // Managers have Estimates in the nav; everyone else has Queue there.
    { to: '/control/estimates', label: t('nav.estimates'), icon: <IconBins />, show: isOwner },
    { to: '/control/queue', label: t('nav.queue'), icon: <IconQueue />, show: isManager },
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
    // One tile for the customer's drop-offs (review item 5: AA in one place): the Estimates AA tab
    // (what AA has waiting, "+ drop-off", today's drop-offs; owners get "Last 7 days ›" there).
    {
      to: '/control/estimates?view=aa',
      label: dropOffLabel,
      icon: <IconCustomer />,
      show: isStaff && activeCustomers.length > 0,
    },
    {
      to: '/control/load-out/entry',
      label: t('loadOut.entryTitle'),
      icon: <IconEdit />,
      show: loadOutPerms.data?.canEnter ?? false,
    },
  ];
  const setup: Tile[] = [
    { to: '/control/people', label: t('people.title'), icon: <IconPeople />, show: isOwner },
    {
      to: '/control/setup/machines',
      label: t('more.machines'),
      icon: <IconGear />,
      show: isOwner,
    },
    {
      to: '/control/setup/wash-groups',
      label: t('more.washGroups'),
      icon: <IconWasher />,
      show: isOwner,
    },
    {
      to: '/control/setup/items',
      label: t('more.items'),
      icon: <IconBins />,
      show: isOwner,
    },
    {
      to: '/control/setup/formulas',
      label: t('more.formulas'),
      icon: <IconList />,
      show: isOwner,
    },
    {
      to: '/control/setup/reasons',
      label: t('more.reasons'),
      icon: <IconMachineDown />,
      show: isOwner,
    },
    // Shared plant iPad (owner 2026-11-10): names + 6-digit password on that device only.
    {
      to: '/control/setup/plant-ipad',
      label: t('sharedDevice.setupTitle'),
      icon: <IconPeople />,
      show: isOwner,
    },
  ];

  return (
    <main className="form-page more-page">
      <h1>{t('nav.more')}</h1>
      <TileGrid id="more-daily" title={t('more.daily')} tiles={daily} />
      <TileGrid id="more-setup" title={t('more.setup')} tiles={setup} />
      <section aria-labelledby="more-account">
        <h2 id="more-account">{t('more.account')}</h2>
        <ul className="more-menu">
          <li>
            <Link to="/control/password">
              {t('changePassword.myTitle')}
              <span aria-hidden="true">›</span>
            </Link>
          </li>
        </ul>
      </section>
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
