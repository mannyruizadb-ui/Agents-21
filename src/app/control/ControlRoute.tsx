import { Outlet } from 'react-router';
import { RequireAuth } from '../auth/RequireAuth';

/** The control surface, behind sign-in. Loaded lazily by the router; child routes render here. */
export function ControlRoute() {
  return (
    <RequireAuth>
      <Outlet />
    </RequireAuth>
  );
}
