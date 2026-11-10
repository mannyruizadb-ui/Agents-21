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
      // Home dashboard (owner 2026-11-06, round 2): live tiles that tap through to each screen.
      {
        index: true,
        lazy: async () => ({ Component: (await import('./app/control/HomePage')).HomePage }),
      },
      {
        // "More": a grid of every screen the user can open, plus notifications, language, sign-out.
        path: 'more',
        lazy: async () => ({ Component: (await import('./app/control/ControlHome')).ControlHome }),
      },
      {
        path: 'alerts',
        lazy: async () => ({ Component: (await import('./app/control/AlertsPage')).AlertsPage }),
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
        // Soil estimates (B1): owner and managers (no entry PIN since 2026-11-07).
        path: 'estimates',
        lazy: async () => ({
          Component: (await import('./features/estimates/EstimatesPage')).EstimatesPage,
        }),
      },
      {
        // Tasks (owner 2026-11-06): owner sends; managers see and finish their own.
        path: 'tasks',
        lazy: async () => ({ Component: (await import('./features/tasks/TasksPage')).TasksPage }),
      },
      {
        // Load-out (owner 2026-11-06): the board for the manager on duty, the entry for the office.
        path: 'load-out',
        lazy: async () => ({
          Component: (await import('./features/loadout/LoadOutBoardPage')).LoadOutBoardPage,
        }),
      },
      {
        path: 'load-out/entry',
        lazy: async () => ({
          Component: (await import('./features/loadout/LoadOutEntryPage')).LoadOutEntryPage,
        }),
      },
      {
        // Customer deliveries (owner 2026-11-06 B): history for owners; record for owners + managers.
        path: 'deliveries',
        lazy: async () => ({
          Component: (await import('./features/deliveries/DeliveriesPage')).DeliveriesPage,
        }),
      },
      {
        // Review item 5 (owner 2026-11-09): AA in one place, the Estimates AA tab. Old links land there
        // with the drop-off form open.
        path: 'deliveries/new',
        element: <Navigate to="/control/estimates?view=aa&dropoff=1" replace />,
      },
      {
        // Owner Setup (owner 2026-11-05): machines and machine-down reasons are app data.
        path: 'setup/machines',
        lazy: async () => ({
          Component: (await import('./features/setup/SetupMachinesPage')).SetupMachinesPage,
        }),
      },
      {
        // Setup → Wash groups and Formulas (owner 2026-11-09, review item 8): owner only.
        path: 'setup/wash-groups',
        lazy: async () => ({
          Component: (await import('./features/setup/SetupWashGroupsPage')).SetupWashGroupsPage,
        }),
      },
      {
        path: 'setup/formulas',
        lazy: async () => ({
          Component: (await import('./features/setup/SetupFormulasPage')).SetupFormulasPage,
        }),
      },
      {
        // "Change my password" (review 2026-11-09): anyone signed in, from More.
        path: 'password',
        lazy: async () => ({
          Component: (await import('./app/auth/MyPasswordPage')).MyPasswordPage,
        }),
      },
      {
        // Shared plant iPad (owner 2026-11-10). Owner only (RLS + RPC checks).
        path: 'setup/plant-ipad',
        lazy: async () => ({
          Component: (await import('./features/setup/SetupPlantIpadPage')).SetupPlantIpadPage,
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
