import { describe, expect, it } from 'vitest';
import { localName } from './seededNames';

describe('seeded names', () => {
  it('translates seeded machine names to Spanish', () => {
    expect(localName('machine', 'Washer 1', 'es')).toBe('Lavadora 1');
    expect(localName('machine', 'Dryer 2', 'es')).toBe('Secadora 2');
    expect(localName('machine', 'Washer 1', 'en')).toBe('Washer 1');
    expect(localName('machine', 'Ironer', 'es')).toBe('Planchadora');
    expect(localName('machine', 'Folder', 'es')).toBe('Dobladora');
    expect(localName('machine', 'Boiler', 'es')).toBe('Caldera');
    expect(localName('machine', 'Compressor', 'es')).toBe('Compresor');
    expect(localName('machine', 'Water pump', 'es')).toBe('Bomba de agua');
    expect(localName('machine', 'soap  machine', 'es')).toBe('Máquina de jabón');
    expect(localName('machine', 'Wrapping machine', 'es')).toBe('Empacadora');
    expect(localName('machine', 'Ironer', 'en')).toBe('Ironer');
  });
  it("prefers the machine's own name_i18n", () => {
    expect(localName('machine', 'Ironer', 'es', { es: 'Planchadora grande' })).toBe(
      'Planchadora grande',
    );
    expect(localName('machine', 'Ironer', 'es-US', { es: 'Calandra' })).toBe('Calandra');
    expect(localName('machine', 'Ironer', 'es', { es: '  ' })).toBe('Planchadora');
    expect(localName('machine', 'Ironer', 'es', ['x'])).toBe('Planchadora');
    expect(localName('machine', 'Ironer', 'en', { es: 'Calandra' })).toBe('Ironer');
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
