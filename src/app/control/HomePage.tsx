import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useQueryClient } from '@tanstack/react-query';
import { useRequiredSession } from '../auth/sessionContext';
import { userStore } from '../../lib/scopedStore';
import { useLiveRefetch } from '../../lib/useLiveRefetch';
import { useNow } from '../../lib/useNow';
import { usePageAge } from '../../lib/usePageAge';
import { DataAge } from '../../features/washroom/DataAge';
import { useOwnerPlants } from '../../features/admin/useOwnerPlants';
import { useMyAlertCount } from '../../features/alerts/alertsData';
import { HomeTile } from '../../features/home/HomeTiles';
import { useTileLabel } from '../../features/home/useTileLabel';
import {
  allowedTiles,
  loadPrefs,
  moveTile,
  savePrefs,
  toggleTile,
  visibleTiles,
  type HomePrefs,
  type HomeRole,
} from '../../features/home/homePrefs';
import { IconBell, IconDown, IconGear, IconUp } from '../../features/washroom/Icons';
import { TapAlarmBanner } from '../../features/washroom/TapAlarmBanner';
import { useMyRoles } from '../../features/washroom/useMyRoles';
import { pickArea, useAreas } from '../../features/washroom/washroomData';
import { OwnerDashboard } from '../../features/dashboard/OwnerDashboard';
import '../../lib/forms.css';
import './home.css';

// Home dashboard (owner 2026-11-06, round 2): live summary tiles, role-aware, each tapping through to
// its screen. The owner's Home is the dashboard plus a compact strip of the tiles it doesn't repeat
// (declutter 2026-11-09); on a desktop it fits the screen without page scrolling. "Customize" (gear) shows/hides and reorders tiles, saved per user per device
// (plantboard.<userId>.home.v1). Alerts live behind the bell in the header (badge = last 24 h).
// The late/unsent tap alarm always shows on top when present (never hideable).

function Customize({
  prefs,
  role,
  isOwner,
  onChange,
  onDone,
}: {
  prefs: HomePrefs;
  role: HomeRole;
  isOwner: boolean;
  onChange: (p: HomePrefs) => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const label = useTileLabel();
  const allowed = new Set(allowedTiles(role));
  const order = prefs.order.filter((id) => allowed.has(id));
  return (
    <section className="home-customize" aria-labelledby="home-customize-title">
      <h2 id="home-customize-title">{t('home.customizeTitle')}</h2>
      <ol className="home-custom-list">
        {order.map((id, i) => {
          const name = label(id, isOwner);
          const shown = !prefs.hidden.includes(id);
          return (
            <li key={id} className={shown ? undefined : 'off'}>
              <label className="home-custom-check">
                <input
                  type="checkbox"
                  checked={shown}
                  onChange={() => onChange(toggleTile(prefs, id))}
                />
                <span>{name}</span>
              </label>
              <span className="home-custom-move">
                <button
                  type="button"
                  className="secondary"
                  disabled={i === 0}
                  aria-label={t('home.moveUp', { name })}
                  title={t('home.moveUp', { name })}
                  onClick={() => onChange(moveTile(prefs, id, -1))}
                >
                  <IconUp />
                </button>
                <button
                  type="button"
                  className="secondary"
                  disabled={i === order.length - 1}
                  aria-label={t('home.moveDown', { name })}
                  title={t('home.moveDown', { name })}
                  onClick={() => onChange(moveTile(prefs, id, 1))}
                >
                  <IconDown />
                </button>
              </span>
            </li>
          );
        })}
      </ol>
      <div className="actions">
        <button type="button" onClick={onDone}>
          {t('home.customizeDone')}
        </button>
        <button
          type="button"
          className="secondary"
          onClick={() => onChange(loadPrefs({ getItem: () => null, setItem: () => {} }, role))}
        >
          {t('home.customizeReset')}
        </button>
      </div>
    </section>
  );
}

export function HomePage() {
  const { t } = useTranslation();
  const session = useRequiredSession();
  const userId = session.user.id;
  const qc = useQueryClient();
  const now = useNow(5_000);
  const ownerPlants = useOwnerPlants(userId);
  const areas = useAreas();
  const washroom = pickArea(areas.data, 'washroom');
  const plantId = washroom?.plant_id ?? areas.data?.[0]?.plant_id;
  const myRoles = useMyRoles(userId);
  const roles = myRoles.rolesFor(plantId);
  const isOwner = (ownerPlants.data?.length ?? 0) > 0 || roles.has('owner');
  const isManager = !isOwner && roles.has('manager');
  const role: HomeRole = isOwner ? 'owner' : isManager ? 'manager' : 'other';
  const rolesKnown = myRoles.isSuccess;
  const alertCount = useMyAlertCount(isOwner || isManager ? plantId : undefined, userId).data ?? 0;

  // Prefs: read once per user + role; edits save immediately.
  const [edited, setEdited] = useState<{ key: string; prefs: HomePrefs } | null>(null);
  const prefsKey = `${userId}|${role}`;
  const prefs =
    edited && edited.key === prefsKey ? edited.prefs : loadPrefs(userStore(userId), role);
  const change = (p: HomePrefs) => {
    savePrefs(userStore(userId), p);
    setEdited({ key: prefsKey, prefs: p });
  };
  const [params, setParams] = useSearchParams();
  const customizing = params.get('customize') === '1';

  useLiveRefetch(() => qc.refetchQueries({ type: 'active' }), !!plantId);

  const ctx = { userId, plantId, washroomId: washroom?.id, isOwner, isManager, now };
  const tiles = visibleTiles(prefs);
  // One freshness line for the page (declutter 2026-11-09); cards and tiles warn only when stale.
  const age = usePageAge(now);

  return (
    <main className={`form-page home-page${isOwner ? ' owner' : ''}`}>
      <div className="home-header">
        <div className="home-title">
          <h1>{t('home.title')}</h1>
          {age && (
            <DataAge
              updatedAt={age.updatedAt}
              now={now}
              isFetching={age.isFetching}
              isError={age.isError}
              refreshSeconds={age.refreshSeconds}
            />
          )}
        </div>
        <div className="home-header-actions">
          {(isOwner || isManager) && (
            <Link
              to="/control/alerts"
              className="home-icon-button"
              aria-label={
                alertCount > 0 ? t('home.bellLabel', { count: alertCount }) : t('nav.alerts')
              }
              title={t('nav.alerts')}
            >
              <IconBell size="1.6em" />
              {alertCount > 0 && (
                <span className="nav-badge" aria-hidden="true">
                  {alertCount > 99 ? '99+' : alertCount}
                </span>
              )}
            </Link>
          )}
          <button
            type="button"
            className="home-icon-button"
            aria-label={t('home.customize')}
            title={t('home.customize')}
            aria-pressed={customizing}
            onClick={() => setParams(customizing ? {} : { customize: '1' }, { replace: true })}
          >
            <IconGear size="1.6em" />
          </button>
        </div>
      </div>
      <TapAlarmBanner />
      {customizing && rolesKnown && (
        <Customize
          prefs={prefs}
          role={role}
          isOwner={isOwner}
          onChange={change}
          onDone={() => setParams({}, { replace: true })}
        />
      )}
      {!plantId && areas.isPending && <p role="status">{t('common.loading')}</p>}
      {plantId && rolesKnown && (
        <div className="home-body">
          {tiles.length === 0 ? (
            !isOwner && <p className="notice">{t('home.noTiles')}</p>
          ) : (
            // Owner: a compact status strip above the dashboard (only what the dashboard lacks).
            <ul
              className={isOwner ? 'home-grid home-strip' : 'home-grid'}
              aria-label={isOwner ? t('home.statusStrip') : undefined}
            >
              {tiles.map((id) => (
                <HomeTile key={id} id={id} ctx={ctx} />
              ))}
            </ul>
          )}
          {isOwner && <OwnerDashboard plantId={plantId} washroomId={washroom?.id} now={now} />}
        </div>
      )}
    </main>
  );
}
