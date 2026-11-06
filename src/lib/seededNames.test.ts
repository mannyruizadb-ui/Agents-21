import { describe, expect, it } from 'vitest';
import { localName } from './seededNames';

describe('seeded names', () => {
  it('translates seeded machine names to Spanish', () => {
    expect(localName('machine', 'Washer 1', 'es')).toBe('Lavadora 1');
    expect(localName('machine', 'Dryer 2', 'es')).toBe('Secadora 2');
    expect(localName('machine', 'Washer 1', 'en')).toBe('Washer 1');
  });
  it('translates seeded area names', () => {
    expect(localName('area', 'Washroom', 'es')).toBe('Lavandería');
    expect(localName('area', 'Finishing', 'es-US')).toBe('Terminación');
    expect(localName('area', 'Finishing', 'en')).toBe('Finishing');
  });
  it('keeps every other name as entered', () => {
    expect(localName('machine', 'Air compressor', 'es')).toBe('Air compressor');
    expect(localName('machine', 'Washer 7 big', 'es')).toBe('Washer 7 big');
    expect(localName('area', 'Back dock', 'es')).toBe('Back dock');
    expect(localName('route', 'Route 21', 'es')).toBe('Ruta 21');
    expect(localName('route', 'Hialeah run', 'es')).toBe('Hialeah run');
  });
});
