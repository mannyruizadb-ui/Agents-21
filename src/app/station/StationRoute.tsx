import { Outlet } from 'react-router';
import { RequireAuth } from '../auth/RequireAuth';
import { BackBar } from '../control/BackBar';

/**
 * Station screens (a tablet at one machine), behind sign-in. A stable URL per machine, so a mounted
 * tablet can open it in kiosk mode (Guided Access / a kiosk browser) and stay there.
 */
export function StationRoute() {
  return (
    <RequireAuth>
      <BackBar />
      <Outlet />
    </RequireAuth>
  );
}
