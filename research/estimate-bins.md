# Estimates by bin fill: loads per full bin

Owner idea, 2026-11-04. Denise estimates dirty work by how full each bin is (¼, ½, ¾, full, or
several bins, e.g. 2 full + 1 half). The app turns that into wash loads using one number per
wash group: **how many washer loads one full bin makes.**

How it fits the existing schema (no schema change):
- the estimate is stored as `unit = 'basket'` and `qty` = bins (e.g. 2.5);
- `wash_groups.baskets_per_load = 1 / loads_per_full_bin`;
- `allow_basket_estimates = true`.

The app shows the result with "≈" (approximate). After 2–3 weeks of washer taps, compare the
estimated loads with the loads actually run per group, then correct these numbers.

**Owner: fill in one number per row.** A range like "5–6" can't be used as is, so pick the
midpoint or your best single guess. Also check that the same bin size is used for every group;
if mats use a different container, say so.

| Wash group | Loads per full bin | Source |
|---|---|---|
| Black mats | 5–6 (pick one) | owner: "carpets 5 to 6" |
| Colored mats | ? | |
| Charcoal mats | ? | |
| Scraper mats | ? | |
| City & Brito mats | ? | |
| Presidente logo mats | ? | |
| Logo mats | ? | |
| Dust & wet mops | ? | |
| Microfiber mops | ? | |
| Kitchen towels | 2–3 (pick one) | owner |
| Microfiber towels | ? | |
| Mechanic towels | ? | |
| White aprons | ? | |
| Black aprons | ? | |
| Coats (white) | ? | |
| White tablecloths | 2? | owner: "linens ≈ 2". Confirm which groups count as linens |
| Black tablecloths | 2? | |
| Red & blue tablecloths | 2? | |
| Napkins – Green & Red | 2? | |
| Napkins – Navy Blue w/ Stripe | 2? | |
| Napkins – Dark Navy Blue w/ Stripe | 2? | |
| Napkins – Navy Blue | 2? | |
| Napkins – Regular White | 2? | |
| Napkins – New White | 2? | |
| Napkins – Bone & Chambray | 2? | |
| Napkins – Black w/ Stripe | 2? | |
| Napkins – Black | 2? | |
| Napkins – Pink | 2? | |
| Napkins – Cotton White | 2? | |
| Napkins – Cotton Black | 2? | |
| Old sheets | 2? | |
| Regular sheets | 2? | |
| New sheets | 2? | |
