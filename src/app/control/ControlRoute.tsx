import { RequireAuth } from '../auth/RequireAuth';
import { ControlHome } from './ControlHome';

/** The control surface, behind sign-in. Loaded lazily by the router. */
export function ControlRoute() {
  return (
    <RequireAuth>
      <ControlHome />
    </RequireAuth>
  );
}
