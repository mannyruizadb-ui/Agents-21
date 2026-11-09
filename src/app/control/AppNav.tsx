import type { ReactNode } from 'react';
import { NavLink } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useRequiredSession } from '../auth/sessionContext';
import { BRAND_LOGO_SRC } from '../../lib/brand';
import { useLoadOutBoard, usePlant } from '../../features/loadout/loadOutData';
import { loadOutBadgeCount } from '../../features/loadout/loadOutLogic';
import { estimateServerNow } from '../../features/washroom/washerTime';
import { useNow } from '../../lib/useNow';
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

// The app's one nav (owner 2026-11-06, round 2; frame by screen width 2026-11-09). The item list
// below is the single source of truth; CSS lays it out as a bottom bar (phone, tablet portrait) or a
// left side menu with the logo (≥ 1024 px wide). Per role, with count badges where data exists:
//   owner and others: Home · Washers · Queue · Load-out · More
//   managers:         Home · Washers · Estimates · Load-out · More
// Alerts live behind the bell on Home; tasks are a Home tile and a More tile. The Load-out badge
// counts trucks due within the hour or late (loadOutBadgeCount). Every item shows an
// icon AND its word; active = info blue + a bar + bold (never color alone); the badge number is part
// of the link's name.

interface NavItem {
  to: string;
  icon: ReactNode;
  label: string;
  badge?: number;
}

function Tab({ to, icon, label, badge }: NavItem) {
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
  // Review 2026-11-09: only from an hour before a truck (or when one is late), not all evening.
  const plant = usePlant(plantId);
  const now = useNow(60_000);
  const loadOutCount = board.data
    ? loadOutBadgeCount(
        board.data.routes,
        board.data.load_date,
        estimateServerNow(board.data.server_time, board.dataUpdatedAt, now),
        plant.data?.timezone ?? 'America/New_York',
      )
    : 0;

  const items: NavItem[] = [
    { to: '/control', icon: <IconHome size="26" />, label: t('nav.home') },
    { to: '/control/washers', icon: <IconWasher size="26" />, label: t('nav.washers') },
    isManager
      ? { to: '/control/estimates', icon: <IconBins size="26" />, label: t('nav.estimates') }
      : {
          to: '/control/queue',
          icon: <IconQueue size="26" />,
          label: t('nav.queue'),
          badge: queueCount,
        },
    {
      to: '/control/load-out',
      icon: <IconTruck size="26" />,
      label: t('nav.loadOut'),
      badge: loadOutCount,
    },
    { to: '/control/more', icon: <IconMenu size="26" />, label: t('nav.more') },
  ];

  return (
    <nav className="app-nav" aria-label={t('nav.label')}>
      {/* Side menu only (hidden in the bottom bar): the logo and the app's name. */}
      <div className="nav-brand">
        <img className="nav-brand-logo" src={BRAND_LOGO_SRC} alt={t('brand.company')} />
        <span className="nav-brand-name">{t('app.name')}</span>
      </div>
      <ul className="nav-items">
        {items.map((it) => (
          <li key={it.to}>
            <Tab {...it} />
          </li>
        ))}
      </ul>
    </nav>
  );
}
