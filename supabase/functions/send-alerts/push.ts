// Web Push sender (RFC 8291 encryption + RFC 8292 VAPID) on jsr:@negrel/webpush (MIT, WebCrypto only).
// VAPID keys come from env in the common web-push format: VAPID_PUBLIC_KEY = base64url of the
// 65-byte uncompressed P-256 point (the same value the browser gets as VITE_VAPID_PUBLIC_KEY),
// VAPID_PRIVATE_KEY = base64url of the 32-byte private scalar.
import { ApplicationServer, PushMessageError, Urgency } from '@negrel/webpush';
import { decodeBase64Url, encodeBase64Url } from '@std/encoding/base64url';
import type { PushPayload, PushTarget, SendResult } from './alerts.ts';

export const PUSH_TTL_SECONDS = 3600;
export const PUSH_TIMEOUT_MS = 10_000;

/** Turns the base64url env keys into a WebCrypto ECDSA key pair; throws on malformed keys. */
export async function importVapidKeys(
  publicKey: string,
  privateKey: string,
): Promise<CryptoKeyPair> {
  const pub = decodeBase64Url(publicKey);
  const priv = decodeBase64Url(privateKey);
  if (pub.length !== 65 || pub[0] !== 0x04 || priv.length !== 32) {
    throw new Error(
      'VAPID keys must be base64url: public 65 bytes (uncompressed), private 32 bytes',
    );
  }
  const x = encodeBase64Url(pub.slice(1, 33));
  const y = encodeBase64Url(pub.slice(33, 65));
  const d = encodeBase64Url(priv);
  const algo = { name: 'ECDSA', namedCurve: 'P-256' };
  const [publicCryptoKey, privateCryptoKey] = await Promise.all([
    crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x, y, ext: true }, algo, true, [
      'verify',
    ]),
    // importing d together with x/y makes WebCrypto reject a private key that doesn't match
    crypto.subtle.importKey('jwk', { kty: 'EC', crv: 'P-256', x, y, d }, algo, false, ['sign']),
  ]);
  return { publicKey: publicCryptoKey, privateKey: privateCryptoKey };
}

/** VAPID `sub` claim: a mailto: or https: contact, read from env (never hard-coded). */
export function validSubject(subject: string): boolean {
  return /^mailto:[^\s@]+@[^\s@]+$/.test(subject) || /^https:\/\/[^\s]+$/.test(subject);
}

export function createSender(vapidKeys: CryptoKeyPair, subject: string) {
  return async function send(target: PushTarget, payload: PushPayload): Promise<SendResult> {
    // A fresh ApplicationServer per message: it owns the ECDH key pair, which RFC 8291 §3.1
    // requires to be new for every message.
    const server = await ApplicationServer.new({ contactInformation: subject, vapidKeys });
    const subscriber = server.subscribe({
      endpoint: target.endpoint,
      keys: { p256dh: target.p256dh, auth: target.auth },
    });
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<'timeout'>((resolve) => {
      timer = setTimeout(() => resolve('timeout'), PUSH_TIMEOUT_MS);
    });
    try {
      const outcome = await Promise.race([
        subscriber
          .pushTextMessage(JSON.stringify(payload), {
            ttl: PUSH_TTL_SECONDS,
            urgency: Urgency.High,
          })
          .then(() => 'ok' as const),
        timeout,
      ]);
      return outcome === 'ok' ? 'ok' : 'failed';
    } catch (err) {
      if (err instanceof PushMessageError) {
        const status = err.response.status;
        await err.response.body?.cancel().catch(() => {});
        return status === 404 || status === 410 ? 'gone' : 'failed';
      }
      return 'failed';
    } finally {
      clearTimeout(timer);
    }
  };
}
