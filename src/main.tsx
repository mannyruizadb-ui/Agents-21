import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { RouterProvider } from 'react-router';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { initI18n } from './lib/i18n';
import { supabase } from './lib/supabase';
import { router } from './router';
import { runStartupStorageSweep } from './app/startupStorage';

// Security re-review notes 2 and 5: expire stored PINs for every account and drop legacy keys.
runStartupStorageSweep();

const queryClient = new QueryClient();

// Security M3: no cached server data survives a sign-out or a switch to another account.
let cachedUserId: string | null | undefined;
supabase.auth.onAuthStateChange((event, session) => {
  const userId = session?.user.id ?? null;
  if (event === 'SIGNED_OUT' || (cachedUserId !== undefined && userId !== cachedUserId)) {
    queryClient.clear();
  }
  cachedUserId = userId;
});

await initI18n();

const root = document.getElementById('root');
if (!root) throw new Error('Missing #root element in index.html');

createRoot(root).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
