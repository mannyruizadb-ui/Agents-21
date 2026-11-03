// CORS for browser-called Edge Functions: only the site's own origins, never `*`.
// ALLOWED_ORIGINS is a comma-separated list, e.g. "https://adb-plantboard.netlify.app".

export const DEFAULT_ALLOWED_ORIGINS = 'http://127.0.0.1:5173,http://localhost:5173';

export function parseAllowedOrigins(value: string | undefined): string[] {
  return (value ?? DEFAULT_ALLOWED_ORIGINS)
    .split(',')
    .map((o) => o.trim())
    .filter((o) => o.length > 0);
}

/** Headers for a response to `origin`. A disallowed origin gets no Allow-Origin header. */
export function corsHeaders(origin: string | null, allowed: string[]): Record<string, string> {
  const headers: Record<string, string> = { Vary: 'Origin' };
  if (origin !== null && allowed.includes(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS';
    headers['Access-Control-Allow-Headers'] = 'authorization, x-client-info, apikey, content-type';
    headers['Access-Control-Max-Age'] = '600';
  }
  return headers;
}
