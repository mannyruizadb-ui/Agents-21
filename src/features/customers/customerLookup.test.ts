import { describe, expect, it } from 'vitest';
import { buildCustomerLookup, groupOptionText } from './customerLookup';

describe('buildCustomerLookup', () => {
  const lookup = buildCustomerLookup(
    [
      { id: 'ours', customer_id: null },
      { id: 'aa-napkins', customer_id: 'aa' },
      { id: 'other', customer_id: 'hidden' },
    ],
    [{ id: 'aa', name: 'AA Linen', name_i18n: {} }],
  );
  it('tags a customer group with its name', () => {
    expect(lookup('aa-napkins')).toEqual({
      kind: 'named',
      customerId: 'aa',
      name: 'AA Linen',
      nameI18n: {},
    });
  });
  it('gives our goods no tag', () => {
    expect(lookup('ours')).toBeNull();
    expect(lookup('unknown')).toBeNull();
    expect(lookup(null)).toBeNull();
  });
  it('falls back to a generic tag when the customer name is not readable', () => {
    expect(lookup('other')).toEqual({ kind: 'generic', customerId: 'hidden' });
  });
});

describe('groupOptionText', () => {
  it("adds the customer's name to a customer's group only", () => {
    expect(groupOptionText('Napkins', null)).toBe('Napkins');
    expect(groupOptionText('Napkins', 'AA Linen')).toBe('Napkins · AA Linen');
  });
});
