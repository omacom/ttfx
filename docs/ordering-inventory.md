# Unordered-iteration inventory (plan.md §4.3)

Every site where upstream TTE iterates an unordered container (set) or relies
on dict insertion order, with the canonical deterministic order used by ttfx
and matched by the parity shim. Extend this file as effect ports discover new
sites — the parity harness surfaces them as first-divergence failures.

## Engine (sets → canonical order)

| Upstream site | Container | Canonical order | ttfx | shim patch |
|---|---|---|---|---|
| `BaseEffectIterator.update` (base_effect.py:92) | `active_characters` set | ascending `character_id` | `BTreeSet<CharId>` | sort snapshot by id |
| `Terminal._update_terminal_state` (terminal.py:1376) layer ties | `_visible_characters` set | `(layer, character_id)` | sort at render | sort key patched |
| `EffectCharacter.links` iteration in `BreadthFirst.step` (breadthfirst.py:90) | `links` set | ascending `character_id` | id-sorted `Vec` | `sorted(links, key=id)` |

## Effects (sets → canonical order)

| Upstream site | Container | Canonical order | ttfx | shim patch |
|---|---|---|---|---|
| `MiddleOutIterator.__next__` full-phase activation loop (effect_middleout.py:229) | rebuilt `active_characters` set | ascending `character_id` | iterate `BTreeSet<CharId>` | `MiddleOutIterator.__next__` sorts by id |
| `UnstableIterator.__next__` explosion/reassembly tick loops (effect_unstable.py:332, :354) | `active_characters` set | ascending `character_id` | iterate `BTreeSet<CharId>` snapshot | `UnstableIterator.__next__` sorts by id |

## Engine (dict insertion order = behavior)

| Upstream site | ttfx |
|---|---|
| `Motion.paths` / `Animation.scenes` values iteration (e.g. swarm chains `paths.values()`) | `OrderedMap` |
| `Terminal._input_colors_frequency` (equal-count ties in `get_input_colors`) | insertion-ordered `ColorFrequency` |
| `Gradient.build_coordinate_color_mapping` returned dict | `CoordColorMap` (insertion-ordered) |
| `character.neighbors` (north, east, south, west) | fixed-field struct in that order |
| `Scene.frame_index_map` | `Vec<usize>` tick map |
| `PrimsWeighted._pending_weighted_links` (defaultdict; `min` over keys) | `BTreeMap` (order-independent result) |
| distance buckets in `get_characters_grouped` CENTER/OUTSIDE | insertion-ordered vec of buckets |

## Effect-level sets

**Audit complete: all 37 effects reviewed.** Two needed canonical ordering and
carry shim patches; the rest are documented below as order-unobservable.

- middleout (effect_middleout.py:229) — set iteration — patched
- unstable (effect_unstable.py:332, :354) — set iteration — patched

Audited, no patch needed (set iteration present but order-unobservable):

| Effect | Site | Why order-unobservable |
|---|---|---|
| slice | `for character in self.active_characters` at end of `build` (effect_slice.py) | only calls `set_character_visibility(True)`, a commutative per-character flag; render order is already canonicalized by the `_update_terminal_state` patch. ttfx iterates its `BTreeSet` (ascending id). |
| decrypt | `for char in self.active_characters` at the typing→decrypting transition (effect_decrypt.py:263) | only calls `activate_scene("fast_decrypt")`, which mutates each character alone; no SCENE_ACTIVATED handlers registered, so order is unobservable. ttfx iterates its `BTreeSet` (ascending id). |
| print, overflow | none | no set iteration or dict-order reliance beyond `active_characters` membership; ticking covered by the `BaseEffectIterator.update` patch, rows/lists are ordered Python lists. |
| expand, scattered | none beyond `active_characters` membership | build loops iterate `get_characters()` lists; `active_characters` ticking covered by the `BaseEffectIterator.update` patch. |
| colorshift, highlight, sweep, waves | none beyond `active_characters` membership (`add`/`update` only) | build loops iterate `get_characters()`/`get_characters_grouped()` lists; colorshift's `loop_tracker_map` dict is keyed access only (never iterated); ticking covered by the `BaseEffectIterator.update` patch. |
| crumble | none beyond `active_characters` membership | falling/vacuuming pop from lists (`pending_chars`, `unvacuumed_chars`); resetting iterates `get_characters()`. |
| blackhole | `all(character in self.blackhole_chars for ...)` over `active_characters` (effect_blackhole.py:372) | pure membership test (commutative); all activation loops iterate lists. |
| swarm | `swarm_area_coordinate_map` is a dict (effect_swarm.py:218) | insertion-ordered dict with key-overwrite-in-place; ttfx uses an ordered `Vec<(Coord, Vec<Coord>)>` with identical semantics. No set iteration. |
| spotlights | `chars_in_range` / `illuminated_chars` set iteration in `illuminate_chars` (effect_spotlights.py:272,283) | per-character `set_appearance` only, disjoint targets, no RNG inside the loops — commutative. ttfx iterates `ActiveCharacters` (ascending id, including the set difference). |
| burn, smoke, vhstape, synthgrid, matrix | none | no set iteration; ignition/flood/line/column/rain state is held in Python lists and dicts whose order ttfx mirrors. burn's ignition order comes from `PrimsSimple.char_link_order` (a list); smoke's flood order from `BreadthFirst.explored_last_step` (list, and its `links` iteration is already shimmed). |
| laseretch | `color_shifted_chars: set[...]` declared at effect_laseretch.py:336 | dead code upstream — the set is never read, written, or iterated. `beam_chars` is a list. |
| thunderstorm | none | `pending_strike_chars` / `active_strike_chars` / `pending_glow_chars` are all lists (effect_thunderstorm.py:194-198); particle pools iterate their own deques. |

## lru_cache mutation quirk (plan §5 addendum)

Plan.md's "Deliberate divergences" claims the geometry `lru_cache` layers are
value-transparent. **False for swarm**: `SwarmIterator.build` calls
`random.shuffle(...)` directly on the list returned by the cached
`find_coords_on_circle`, mutating the cache entry in place. Later calls with
the same focus coord return the *previously shuffled* list. ttfx reproduces
this with an effect-local cache in `src/effects/swarm.rs` whose entries
persist the shuffle mutation. Other ported call sites (blackhole, spotlights)
only read the returned lists, so dropping the cache stays value-transparent
there. Audit any future effect that mutates a geometry function's return
value.
| fireworks | `active_characters.add` in `__next__` (effect_fireworks.py) | membership only; shells are lists popped from the end. Ticking covered by the `BaseEffectIterator.update` patch. |
| bubbles | `active_characters.union(bubble.characters)` in `__next__` (effect_bubbles.py) | membership only; bubbles and their character groups are lists, and `Bubble.move` steps animations in list order. Ticking covered by the `BaseEffectIterator.update` patch. |
| beams | `active_characters.add` / `not self.active_characters` in `__next__` (effect_beams.py) | membership and emptiness only; pending/active groups and wipe groups are lists. Ticking covered by the `BaseEffectIterator.update` patch. |
| rings | none beyond `active_characters` membership | `Ring.characters`, `pending_chars`, `non_ring_chars` are lists; `rings` dict iterated in insertion order (radius ascending, `Vec<Ring>` in ttfx); RNG order fixed by list order. |
| orbittingvolley | `any(launcher.magazine ...)` / `len(self.active_characters) > 1` | membership/length checks only; `_launchers` and magazines are lists; effect consumes no RNG. |
| binarypath | none beyond `active_characters` membership | `pending_binary_representations`, `active_binary_reps`, `binary_characters`, `final_wipe_chars` are lists; the travel-phase `randrange` pops from a list, order preserved. |
| laseretch | `active_chars` passed into ParticlePool; `color_shifted_chars` (effect_laseretch.py:336) | pool uses the set for membership add/discard only; `color_shifted_chars` is created but never read or iterated upstream (dead attribute, omitted in ttfx). Pool `available` is a deque, `pending_chars`/`beam_chars` are lists; RecursiveBacktracker only checks `links` for emptiness (no links iteration). Ticking covered by the `BaseEffectIterator.update` patch. |
| synthgrid | none beyond `active_characters` membership | `pending_groups`, `grid_lines`, and each GridLine's character lists are Python lists; `group_tracker` dict is only summed over `.values()` (commutative count of nonzero entries, ttfx `Vec<i64>` indexed by group number); blocks look up `character_by_input_coord` by explicit coord list, no dict iteration. |
