import { createBrowserRouter, Navigate } from 'react-router';
import { RequireAuth } from './app/auth/RequireAuth';
import { SignInPage } from './app/auth/SignInPage';
import { ControlHome } from './app/control/ControlHome';
import { DisplayPage } from './app/display/DisplayPage';
import { PairPage } from './app/pair/PairPage';

export const router = createBrowserRouter([
  { path: '/', element: <Navigate to="/control" replace /> },
  { path: '/sign-in', element: <SignInPage /> },
  {
    path: '/control',
    element: (
      <RequireAuth>
        <ControlHome />
      </RequireAuth>
    ),
  },
  { path: '/display/:areaId', element: <DisplayPage /> },
  { path: '/pair', element: <PairPage /> },
]);
