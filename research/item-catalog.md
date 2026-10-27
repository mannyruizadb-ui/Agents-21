# Item Catalog: ADB (seed source for `item_types`)

*Received from the owner 2026-10-27. This file is the source for `supabase/seed.sql`. Every value is editable later in the app (PRD A2). Nothing here is invented: unknown values are marked **TBD**, and defaults are marked **assumed**.*

**Legend**

| Column | Meaning |
|---|---|
| **Count** | How finished goods are counted: `unit` (each piece) or `pack` (full packs + loose pieces) |
| **Pack** | Pieces per full pack |
| **Est.** | How managers estimate dirty work: `load` or `basket` (+ baskets per load) |
| **Pcs/load** | Approximate finished pieces per wash load, used only for reconciliation |

Status of each value: ✅ confirmed by owner · 🔸 assumed default (confirm) · ❓ TBD (needed)

## Floor mats

| Item | Count | Pack | Est. | Pcs/load | Notes |
|---|---|---|---|---|---|
| 3×5 mat | unit ✅ | — | load 🔸 | ❓ | Owner: "mats are by unit" |
| 4×6 mat | unit ✅ | — | load 🔸 | ❓ | |
| 3×10 mat | unit ✅ | — | load 🔸 | ❓ | |
| 5×7 mat | unit ✅ | — | load 🔸 | ❓ | |
| Logo mat | unit ✅ | — | load 🔸 | ❓ | One item, or one per size/customer? 🔸 one item |
| Elevator mat | unit ✅ | — | load 🔸 | ❓ | |

## Mops & cleaning products

| Item | Count | Pack | Est. | Pcs/load | Notes |
|---|---|---|---|---|---|
| Dust mop | unit 🔸 | — | load 🔸 | ❓ | |
| Wet mop | unit 🔸 | — | load 🔸 | ❓ | |
| Microfiber mop | unit 🔸 | — | load 🔸 | ❓ | |
| Microfiber wipe | pack 🔸 | ❓ | load 🔸 | ❓ | Small items are usually packed. Confirm pack size |

## Restaurant linens

| Item | Count | Pack | Est. | Pcs/load | Notes |
|---|---|---|---|---|---|
| Napkin | pack ✅ | 100 ✅ | load 🔸 | ❓ | "pack of 100 + leftover". Colors tracked separately? ❓ |
| Tablecloth 52" | pack ✅ | ❓ | load 🔸 | ❓ | Owner: each tablecloth pack size differs |
| Tablecloth 62" | pack ✅ | ❓ | load 🔸 | ❓ | |
| Tablecloth 72" | pack ✅ | ❓ | load 🔸 | ❓ | |
| Tablecloth 90" | pack ✅ | ❓ | load 🔸 | ❓ | |
| Tablecloth 120" | pack ✅ | ❓ | load 🔸 | ❓ | |
| Tablecloth 130" | pack ✅ | ❓ | load 🔸 | ❓ | |
| Kitchen towel | pack ✅ | ❓ | load 🔸 | ❓ | Owner: "towels by pack" |
| Apron | unit 🔸 | — | load 🔸 | ❓ | |
| Chef coat | unit 🔸 | — | load 🔸 | ❓ | |
| Butcher coat | unit ✅ | — | load 🔸 | ❓ | Owner: "butcher coats by unit" |

## Sheets

| Item | Count | Pack | Est. | Pcs/load | Notes |
|---|---|---|---|---|---|
| Sheet – new | ❓ | ❓ | load 🔸 | ❓ | Are new/regular/old separate stock, or quality grades sorted at finishing? |
| Sheet – regular | ❓ | ❓ | load 🔸 | ❓ | |
| Sheet – old | ❓ | ❓ | load 🔸 | ❓ | |

## Other services & products

| Item | Count | Pack | Est. | Pcs/load | Notes |
|---|---|---|---|---|---|
| Uniform | unit 🔸 | — | load 🔸 | ❓ | One item, or shirts/pants separately? |
| Sanitizer dispenser | — | — | — | — | **Proposed: not in PlantBoard.** It isn't washed or finished, so it has no place in the wash/finish flow. It belongs in rental or inventory tracking. Confirm |

## Open questions (needed before seeding)

1. **Tablecloth pack sizes** for 52", 62", 72", 90", 120", 130".
2. **Kitchen towel** and **microfiber wipe** pack sizes.
3. **Aprons, chef coats, mops, uniforms:** counted by unit? (assumed yes)
4. **Sheets:** unit or pack (and pack size)? Are new, regular and old washed together and sorted afterwards, or kept apart from the start?
5. **Colors:** should napkins and tablecloths be tracked per color (white, bone, black, …), or by size only? Per color multiplies the item list, so the default is by size only.
6. **Sanitizer dispensers:** leave out of PlantBoard?
7. **Estimates:** do managers count any of these in **baskets** instead of loads? If so, roughly how many baskets per load?
8. **Optional now:** rough pieces per load for your highest-volume items, e.g. "a load of napkins ≈ 450". Otherwise the app learns it from history (PRD G3).

## Draft translations (AI-drafted, pending AI review per owner decision)

| English | Español (draft) |
|---|---|
| 3×5 mat | Tapete 3×5 |
| Logo mat | Tapete con logo |
| Elevator mat | Tapete de elevador |
| Dust mop | Mopa de polvo |
| Wet mop | Trapeador |
| Microfiber mop | Mopa de microfibra |
| Microfiber wipe | Paño de microfibra |
| Napkin | Servilleta |
| Tablecloth | Mantel |
| Kitchen towel | Toalla de cocina |
| Apron | Delantal |
| Chef coat | Filipina de chef |
| Butcher coat | Bata de carnicero |
| Sheet (new / regular / old) | Sábana (nueva / regular / vieja) |
| Uniform | Uniforme |

The mat sizes follow the same pattern as 3×5 (Tapete 4×6, …), and the tablecloth sizes follow "Mantel 52 pulg."
