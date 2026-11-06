import type { ReactNode } from 'react';
import { NavLink } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../auth/sessionContext';
import { useLoadOutBoard } from '../../features/loadout/loadOutData';
import {
  IconBins,
  IconHome,
  IconMenu,
  IconQueue,
  IconTruck,
  IconWasher,
} from '../../features/washroom/Icons';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { pickArea, useAreas, useQueue } from '../../features/washroom/washroomData';
import './appnav.css';

// Bottom nav (owner 2026-11-06, round 2), per role, with count badges where data exists:
//   owner and others: Home · Washers · Queue · Load-out · More
//   managers:         Home · Washers · Estimates · Load-out · More
// Alerts moved to the bell on Home; tasks are a Home tile and a More tile. Every tab shows an icon
// AND its word; the badge number is part of the link's name.

function Tab({
  to,
  icon,
  label,
  badge,
}: {
  to: string;
  icon: ReactNode;
  label: string;
  badge?: number;
}) {
  return (
    <NavLink
      to={to}
      end={to === '/control'}
      className={({ isActive }) => (isActive ? 'nav-tab active' : 'nav-tab')}
    >
      <span className="nav-icon" aria-hidden="true">
        {icon}
        {badge ? <span className="nav-badge">{badge > 99 ? '99+' : badge}</span> : null}
      </span>
      <span className="nav-label">{label}</span>
      {badge ? <span className="visually-hidden"> ({badge})</span> : null}
    </NavLink>
  );
}

export function AppNav() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const areas = useAreas();
  const washroom = pickArea(areas.data, 'washroom');
  const plantId = washroom?.plant_id ?? areas.data?.[0]?.plant_id;
  const roles = useMyRoles(session.user.id).rolesFor(plantId);
  const isManager = !roles.has('owner') && roles.has('manager');

  const queue = useQueue(washroom?.id);
  const board = useLoadOutBoard(plantId);
  const queueCount = queue.data?.length ?? 0;
  const loadOutCount = (board.data?.routes ?? []).filter(
    (r) => !r.loaded && r.lines.length > 0,
  ).length;

  return (
    <nav className="app-nav" aria-label={t('nav.label')}>
      <Tab to="/control" icon={<IconHome size="26" />} label={t('nav.home')} />
      <Tab to="/control/washers" icon={<IconWasher size="26" />} label={t('nav.washers')} />
      {isManager ? (
        <Tab to="/control/estimates" icon={<IconBins size="26" />} label={t('nav.estimates')} />
      ) : (
        <Tab
          to="/control/queue"
          icon={<IconQueue size="26" />}
          label={t('nav.queue')}
          badge={queueCount}
        />
      )}
      <Tab
        to="/control/load-out"
        icon={<IconTruck size="26" />}
        label={t('nav.loadOut')}
        badge={loadOutCount}
      />
      <Tab to="/control/more" icon={<IconMenu size="26" />} label={t('nav.more')} />
    </nav>
  );
}
