import { describe, expect, it } from 'vitest';
import { secondColor, swatchBackground } from './groupColor';

describe('two-colour wash group swatches', () => {
  it('one colour stays a solid colour', () => {
    expect(swatchBackground('#1E3A8A', null)).toBe('#1E3A8A');
    expect(swatchBackground('#1E3A8A', undefined)).toBe('#1E3A8A');
    expect(swatchBackground('#1E3A8A', 'red')).toBe('#1E3A8A');
  });
  it('a second colour splits the swatch half/half', () => {
    expect(swatchBackground('#FFFFFF', '#DC2626')).toBe(
      'linear-gradient(135deg, #FFFFFF 0 50%, #DC2626 50% 100%)',
    );
    expect(swatchBackground('#FFFFFF', '#DC2626', 'vertical')).toBe(
      'linear-gradient(to bottom, #FFFFFF 0 50%, #DC2626 50% 100%)',
    );
  });
  it('an invalid first colour falls back to grey, the second only when valid', () => {
    expect(swatchBackground(null, '#000000')).toBe(
      'linear-gradient(135deg, #64748B 0 50%, #000000 50% 100%)',
    );
    expect(secondColor('#12345')).toBeNull();
    expect(secondColor('#123456')).toBe('#123456');
  });
});
