import { describe, expect, it } from 'vitest';
import { localize } from './localize';

describe('localize', () => {
  const names = { es: 'Servilleta blanca', ht: '' };

  it('returns the requested language when present', () => {
    expect(localize('White napkin', names, 'es')).toBe('Servilleta blanca');
  });

  it('falls back past empty translations to the base value', () => {
    expect(localize('White napkin', names, 'ht')).toBe('White napkin');
  });

  it('uses fallbacks in order before the base value', () => {
    expect(localize('White napkin', { en: 'Napkin (white)' }, 'ht', ['es', 'en'])).toBe(
      'Napkin (white)',
    );
  });

  it('handles a missing map', () => {
    expect(localize('White napkin', null, 'es')).toBe('White napkin');
  });
});
