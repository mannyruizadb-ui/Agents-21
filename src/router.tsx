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
    children: [
      {
        index: true,
        lazy: async () => ({ Component: (await import('./app/control/ControlHome')).ControlHome }),
      },
      {
        // Owner only (PRD A4). The page shows nothing manageable to others, and manage-users
        // re-checks the owner role on every request.
        path: 'people',
        lazy: async () => ({
          Component: (await import('./features/admin/PeoplePage')).PeoplePage,
        }),
      },
      {
        // Washer board (D1/G6 on phones): owner, managers, leads and viewers can read it.
        path: 'washers',
        lazy: async () => ({
          Component: (await import('./features/washroom/WasherBoardPage')).WasherBoardPage,
        }),
      },
      {
        // Soil estimates (B1): owner and managers, one name + PIN per batch (owner 2026-11-04).
        path: 'estimates',
        lazy: async () => ({
          Component: (await import('./features/estimates/EstimatesPage')).EstimatesPage,
        }),
      },
      {
        // Owner Setup (owner 2026-11-05): machines and machine-down reasons are app data.
        path: 'setup/machines',
        lazy: async () => ({
          Component: (await import('./features/setup/SetupMachinesPage')).SetupMachinesPage,
        }),
      },
      {
        path: 'setup/reasons',
        lazy: async () => ({
          Component: (await import('./features/setup/SetupReasonsPage')).SetupReasonsPage,
        }),
      },
      {
        // Machine down / back up (owner 2026-11-04): owner and managers change; others read.
        path: 'machines',
        lazy: async () => ({
          Component: (await import('./features/washroom/MachineStatusPage')).MachineStatusPage,
        }),
      },
      {
        // Work queue (C1–C4). Everyone with a role reads it; only the owner gets edit controls
        // (owner decision 2026-11-04).
        path: 'queue',
        lazy: async () => ({
          Component: (await import('./features/queue/QueuePage')).QueuePage,
        }),
      },
    ],
  },
  {
    // Washer station: a tablet at one washer opens this URL in kiosk mode (stable per machine).
    path: '/station',
    lazy: async () => ({ Component: (await import('./app/station/StationRoute')).StationRoute }),
    children: [
      {
        path: 'washer/:machineId',
        lazy: async () => ({
          Component: (await import('./features/washroom/WasherStationPage')).WasherStationPage,
        }),
      },
    ],
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
