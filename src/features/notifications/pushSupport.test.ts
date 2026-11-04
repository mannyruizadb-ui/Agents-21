import { describe, expect, it } from 'vitest';
import {
  iosVersion,
  isInstalled,
  isIOS,
  pushSupport,
  subscriptionKeys,
  urlBase64ToUint8Array,
  type PushEnv,
} from './pushSupport';

const IPHONE_17 =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const IPHONE_16_3 = IPHONE_17.replace('17_5', '16_3').replace('17.5', '16.3');
const IPAD_DESKTOP =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15';
const ANDROID =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

const env = (over: Partial<PushEnv>): PushEnv => ({
  userAgent: ANDROID,
  maxTouchPoints: 5,
  hasServiceWorker: true,
  hasPushManager: true,
  hasNotification: true,
  standaloneDisplay: false,
  navigatorStandalone: undefined,
  ...over,
});

describe('iOS detection', () => {
  it('finds iPhone, and iPad asking for the desktop site', () => {
    expect(isIOS(IPHONE_17, 5)).toBe(true);
    expect(isIOS(IPAD_DESKTOP, 5)).toBe(true);
    expect(isIOS(IPAD_DESKTOP, 0)).toBe(false); // a real Mac
    expect(isIOS(ANDROID, 5)).toBe(false);
  });
  it('reads the iOS version', () => {
    expect(iosVersion(IPHONE_17)).toEqual([17, 5]);
    expect(iosVersion(IPAD_DESKTOP)).toEqual([17, 4]);
    expect(iosVersion(ANDROID)).toBeNull();
  });
});

describe('installed detection', () => {
  it('is installed in standalone display mode or with navigator.standalone', () => {
    expect(isInstalled({ standaloneDisplay: true, navigatorStandalone: undefined })).toBe(true);
    expect(isInstalled({ standaloneDisplay: false, navigatorStandalone: true })).toBe(true);
    expect(isInstalled({ standaloneDisplay: false, navigatorStandalone: false })).toBe(false);
  });
});

describe('pushSupport', () => {
  it('iPhone in Safari must be added to the Home Screen first', () => {
    // Safari tabs on iOS have no PushManager at all.
    expect(pushSupport(env({ userAgent: IPHONE_17, hasPushManager: false }))).toBe('ios-install');
  });
  it('iPhone installed on 16.4+ is supported', () => {
    expect(pushSupport(env({ userAgent: IPHONE_17, navigatorStandalone: true }))).toBe('supported');
  });
  it('iPhone older than 16.4 needs an update, installed or not', () => {
    expect(pushSupport(env({ userAgent: IPHONE_16_3, navigatorStandalone: true }))).toBe(
      'ios-update',
    );
  });
  it('Android Chrome is supported in a tab; missing APIs are unsupported', () => {
    expect(pushSupport(env({}))).toBe('supported');
    expect(pushSupport(env({ hasPushManager: false }))).toBe('unsupported');
    expect(
      pushSupport(env({ userAgent: IPHONE_17, navigatorStandalone: true, hasNotification: false })),
    ).toBe('unsupported');
  });
});

describe('keys', () => {
  it('decodes a base64url VAPID key', () => {
    expect([...urlBase64ToUint8Array('AQID_-8')]).toEqual([1, 2, 3, 255, 239]);
  });
  it('extracts subscription keys and rejects incomplete ones', () => {
    expect(
      subscriptionKeys({ endpoint: 'https://push.example/abc', keys: { p256dh: 'P', auth: 'A' } }),
    ).toEqual({ endpoint: 'https://push.example/abc', p256dh: 'P', auth: 'A' });
    expect(subscriptionKeys({ endpoint: 'http://x', keys: { p256dh: 'P', auth: 'A' } })).toBeNull();
    expect(subscriptionKeys({ endpoint: 'https://x', keys: { p256dh: 'P' } })).toBeNull();
    expect(subscriptionKeys({ endpoint: null, keys: null })).toBeNull();
  });
});
