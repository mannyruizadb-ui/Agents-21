// Client-side configuration. Only the publishable key may ever ship to the browser.
function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`Missing ${name}. Copy .env.example to .env.local and fill it in.`);
  return value;
}

export const env = {
  supabaseUrl: required('VITE_SUPABASE_URL', import.meta.env.VITE_SUPABASE_URL),
  supabasePublishableKey: required(
    'VITE_SUPABASE_PUBLISHABLE_KEY',
    import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  ),
  /**
   * Web Push VAPID public key (base64url). Optional: when it is not set, push notifications are not
   * set up and the Notifications card says so. The private key lives only in the push sender.
   */
  vapidPublicKey: import.meta.env.VITE_VAPID_PUBLIC_KEY?.trim() || null,
};
