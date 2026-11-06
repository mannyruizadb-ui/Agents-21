# Estimates by container fill: loads per full bin / basket

Owner, 2026-11-04. Denise estimates dirty work by container: a **bin** (tall, 5–6 ft, mostly
linen) or a **basket** (half the height, longer; mats, sometimes linen). She picks the container
and enters full ones plus a partial (¼ ½ ¾). The app converts that to wash loads using one number
per wash group and container. All the numbers are estimates, not rules ("don't make that a
rule"). After 2–3 weeks of washer taps, compare estimated loads with the loads actually run and
correct them.

Schema (migration `20261104163713_add_container_load_factors.sql`):
- the columns are `wash_groups.loads_per_basket` and `wash_groups.loads_per_bin`;
- `allow_basket_estimates` / `allow_bin_estimates` control which containers are offered;
- units are `'basket'` / `'bin'`;
- conversion goes through `app.to_loads()`;
- a missing number means the screen shows "no number set" and never guesses;
- `baskets_per_load` is deprecated (no longer read).

| Wash group | Loads per full basket | Loads per full bin | Status |
|---|---|---|---|
| All 7 mat groups | 3.5 | **?** (AA Linen brings mats in bins) | owner |
| Kitchen towels | 2 | 2.5 | owner |
| All 3 sheet groups | **?** | 2 | owner |
| All 12 napkin groups (14 colors) | **?** | 2 | owner |
| All 3 tablecloth groups | **?** | 2 | **confirm**: owner wrote "2 baskets per full bin" |
| Dust & wet mops, Microfiber mops | ? | ? | missing |
| Microfiber towels, Mechanic towels | ? | ? | missing |
| White / black aprons, Coats (white) | ? | ? | missing |

AA Linen (a second customer, volume varies) sends everything in bins: kitchen towels, aprons,
mats, napkins and tablecloths. It is not modeled separately yet; see CLAUDE.md.
