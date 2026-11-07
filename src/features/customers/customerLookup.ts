// Which outside customer a wash group belongs to (owner 2026-11-06 A: AA Linen's goods are their own
// wash groups). Pure part. A group with a customer the viewer can't read (customers is owner/manager
// only) still gets a generic "Customer" tag, so their goods are never mistaken for ours.

export interface GroupCustomerRow {
  id: string;
  customer_id: string | null;
}

export interface CustomerNameRow {
  id: string;
  name: string;
  name_i18n: unknown;
}

export type CustomerTag =
  | { kind: 'named'; customerId: string; name: string; nameI18n: unknown }
  | { kind: 'generic'; customerId: string };

export type CustomerLookup = (washGroupId: string | null | undefined) => CustomerTag | null;

export function buildCustomerLookup(
  groups: readonly GroupCustomerRow[],
  customers: readonly CustomerNameRow[],
): CustomerLookup {
  const byGroup = new Map<string, string>();
  for (const g of groups) if (g.customer_id) byGroup.set(g.id, g.customer_id);
  const byId = new Map(customers.map((c) => [c.id, c]));
  return (washGroupId) => {
    if (!washGroupId) return null;
    const customerId = byGroup.get(washGroupId);
    if (!customerId) return null;
    const c = byId.get(customerId);
    return c
      ? { kind: 'named', customerId, name: c.name, nameI18n: c.name_i18n }
      : { kind: 'generic', customerId };
  };
}

/** A wash group in a picker: "Napkins" for ours, "Napkins · AA Linen" for a customer's. */
export function groupOptionText(groupName: string, customerName: string | null): string {
  return customerName ? `${groupName} · ${customerName}` : groupName;
}
