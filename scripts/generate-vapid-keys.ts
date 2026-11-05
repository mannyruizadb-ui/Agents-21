// Prints a new VAPID key pair for Web Push (RFC 8292) in the usual web-push format.
// Run: node scripts/generate-vapid-keys.ts   (or: deno run scripts/generate-vapid-keys.ts)
// Never commit the output. VAPID_PUBLIC_KEY goes to the send-alerts function secrets AND to
// Netlify as VITE_VAPID_PUBLIC_KEY; VAPID_PRIVATE_KEY goes ONLY to the function secrets.
// Changing the pair later invalidates every saved subscription (browsers must re-subscribe).

const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
  'sign',
  'verify',
]);
const publicRaw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
const privateJwk = await crypto.subtle.exportKey('jwk', pair.privateKey);

console.log(`VAPID_PUBLIC_KEY=${b64url(publicRaw)}`);
console.log(`VAPID_PRIVATE_KEY=${privateJwk.d}`);
