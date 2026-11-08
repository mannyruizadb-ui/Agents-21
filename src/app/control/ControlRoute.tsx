import { Outlet } from 'react-router';
import { RequireAuth } from '../auth/RequireAuth';
import { AppNav } from './AppNav';
import { BackBar } from './BackBar';

/** The control surface, behind sign-in, with the role-based bottom nav. Child routes render here. */
export function ControlRoute() {
  return (
    <RequireAuth>
      <BackBar />
      <Outlet />
      <AppNav />
    </RequireAuth>
  );
}
