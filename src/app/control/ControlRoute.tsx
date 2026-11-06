import { Outlet } from 'react-router';
import { RequireAuth } from '../auth/RequireAuth';
import { AppNav } from './AppNav';

/** The control surface, behind sign-in, with the role-based bottom nav. Child routes render here. */
export function ControlRoute() {
  return (
    <RequireAuth>
      <Outlet />
      <AppNav />
    </RequireAuth>
  );
}
