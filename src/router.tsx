import { createBrowserRouter, Navigate } from 'react-router';

// Each surface is its own chunk (.claude/rules/frontend.md: code-split per surface), so a
// wall display never downloads the control app and vice versa.
export const router = createBrowserRouter([
  { path: '/', element: <Navigate to="/control" replace /> },
  {
    path: '/sign-in',
    lazy: async () => ({ Component: (await import('./app/auth/SignInPage')).SignInPage }),
  },
  {
    path: '/control',
    lazy: async () => ({ Component: (await import('./app/control/ControlRoute')).ControlRoute }),
  },
  {
    path: '/display/:areaId',
    lazy: async () => ({ Component: (await import('./app/display/DisplayPage')).DisplayPage }),
  },
  {
    path: '/pair',
    lazy: async () => ({ Component: (await import('./app/pair/PairPage')).PairPage }),
  },
]);
