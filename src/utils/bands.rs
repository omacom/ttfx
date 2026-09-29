//! Vertical field bands on the input word: 4, 3, 4, 3, 5 units crest to dim.
//!
//! The field is 19 units tall, one per wordmark bitmap row. `t` is 0 at the
//! top of the word and 1 at the bottom. Palette color 0 is crest, then hover,
//! lit, mid, dim.

use crate::engine::character::{CharId, EffectCharacter};
use crate::engine::terminal::Terminal;
use crate::fx::{Engine, CF_PREEXISTING};
use crate::utils::palette::Palette;

/// Crest, hover, lit, mid, dim — top to bottom.
pub const FIELD_BAND_UNITS: &[u32] = &[4, 3, 4, 3, 5];

pub fn field_band_rows() -> u32 {
    FIELD_BAND_UNITS.iter().sum()
}

/// Which band `t` (0 at the top, 1 at the bottom) falls in.
pub fn field_band_index(t: f64) -> usize {
    field_band_index_in(t, FIELD_BAND_UNITS)
}

pub fn field_band_index_in(t: f64, units: &[u32]) -> usize {
    let total: u32 = units.iter().copied().sum();
    if total == 0 || units.is_empty() {
        return 0;
    }
    let u = t.clamp(0.0, 1.0) * total as f64;
    let mut acc = 0.0;
    for (i, &n) in units.iter().enumerate() {
        acc += n as f64;
        if u < acc {
            return i;
        }
    }
    units.len() - 1
}

/// How many of `n` discrete rows each band gets. Hamilton / largest remainder
/// so a 1-unit hover is never dropped when `n` is not a multiple of 19.
pub fn field_band_counts(n: u32) -> Vec<u32> {
    let bands = FIELD_BAND_UNITS.len();
    if n == 0 {
        return vec![0; bands];
    }
    let total = field_band_rows() as f64;
    let exact: Vec<f64> = FIELD_BAND_UNITS
        .iter()
        .map(|&u| n as f64 * u as f64 / total)
        .collect();
    let mut counts: Vec<u32> = exact.iter().map(|e| e.floor() as u32).collect();
    let mut remain = n - counts.iter().sum::<u32>();
    let mut order: Vec<usize> = (0..bands).collect();
    order.sort_by(|&a, &b| {
        exact[b]
            .fract()
            .partial_cmp(&exact[a].fract())
            .unwrap()
            .then(a.cmp(&b))
    });
    for i in order {
        if remain == 0 {
            break;
        }
        counts[i] += 1;
        remain -= 1;
    }
    if n >= bands as u32 {
        while let Some(zero) = counts.iter().position(|&c| c == 0) {
            let Some(donor) = counts
                .iter()
                .enumerate()
                .rev()
                .find(|(_, &c)| c > 1)
                .map(|(i, _)| i)
            else {
                break;
            };
            counts[donor] -= 1;
            counts[zero] += 1;
        }
    }
    counts
}

/// Band for discrete row `i` of `n` (0 at the top).
pub fn field_band_index_n(i: u32, n: u32) -> usize {
    if n == 0 {
        return 0;
    }
    let i = i.min(n - 1);
    let counts = field_band_counts(n);
    let mut acc = 0u32;
    for (b, &c) in counts.iter().enumerate() {
        acc += c;
        if i < acc {
            return b;
        }
    }
    counts.len() - 1
}

fn band_for_display(display: usize, body_top: usize, body_bot: usize, body_n: u32) -> usize {
    if display < body_top {
        0
    } else if display > body_bot {
        FIELD_BAND_UNITS.len() - 1
    } else {
        field_band_index_n((display - body_top) as u32, body_n)
    }
}

/// Color each input character from the palette by its row in the word.
///
/// `input_coord.row` is 1-based and grows up, so the largest row is the top.
/// 4-3-4-3-5 is laid out on the *body* rows (lines with at least half the
/// ink of the densest line). The Omarchy FIGlet's M peak and Y tail are
/// sparse; counting them in the span stole a crest row, so O/A/R only got
/// a one-row cap. Sparse rows above the body stay crest; below stay dim.
pub fn apply_field_bands(terminal: &mut Terminal, palette: &Palette) {
    let mut min_row = i64::MAX;
    let mut max_row = i64::MIN;
    for &id in &terminal.input_characters {
        let ch = &terminal.arena[id.0 as usize];
        if skip_char(ch) {
            continue;
        }
        min_row = min_row.min(ch.input_coord.row);
        max_row = max_row.max(ch.input_coord.row);
    }
    if min_row > max_row {
        return;
    }
    let n_lines = (max_row - min_row + 1) as usize;
    let mut ink = vec![0u32; n_lines];
    for &id in &terminal.input_characters {
        let ch = &terminal.arena[id.0 as usize];
        if skip_char(ch) {
            continue;
        }
        ink[(max_row - ch.input_coord.row) as usize] += 1;
    }
    let (body_top, body_bot, body_n) = body_span(&ink);
    let ids: Vec<CharId> = terminal.input_characters.clone();
    for id in ids {
        let ch = &mut terminal.arena[id.0 as usize];
        if skip_char(ch) {
            continue;
        }
        let display = (max_row - ch.input_coord.row) as usize;
        let band = band_for_display(display, body_top, body_bot, body_n);
        ch.animation.input_fg_color = Some(palette.color(band));
        ch.uses_input_preexisting_colors = true;
    }
}

/// Color fx input slots the same way [`apply_field_bands`] colors the arena.
pub fn apply_field_bands_fx(engine: &mut Engine, palette: &Palette) {
    let mut min_row = i64::MAX;
    let mut max_row = i64::MIN;
    for &slot in &engine.input_chars {
        if skip_slot(engine, slot) {
            continue;
        }
        let row = engine.ch.input_coord[slot as usize].row;
        min_row = min_row.min(row);
        max_row = max_row.max(row);
    }
    if min_row > max_row {
        return;
    }
    let n_lines = (max_row - min_row + 1) as usize;
    let mut ink = vec![0u32; n_lines];
    for &slot in &engine.input_chars {
        if skip_slot(engine, slot) {
            continue;
        }
        let row = engine.ch.input_coord[slot as usize].row;
        ink[(max_row - row) as usize] += 1;
    }
    let (body_top, body_bot, body_n) = body_span(&ink);
    let slots: Vec<u32> = engine.input_chars.clone();
    for slot in slots {
        if skip_slot(engine, slot) {
            continue;
        }
        let display = (max_row - engine.ch.input_coord[slot as usize].row) as usize;
        let band = band_for_display(display, body_top, body_bot, body_n);
        engine.ch.fg[slot as usize] = Some(palette.color(band));
        engine.ch.flags[slot as usize] |= CF_PREEXISTING;
    }
    engine.preexisting_colors_present = true;
}

fn body_span(ink: &[u32]) -> (usize, usize, u32) {
    let max_ink = ink.iter().copied().max().unwrap_or(0);
    let threshold = max_ink / 2;
    let mut body_top = 0usize;
    let mut body_bot = ink.len().saturating_sub(1);
    if let Some(top) = ink.iter().position(|&n| n > threshold) {
        body_top = top;
        body_bot = ink.iter().rposition(|&n| n > threshold).unwrap_or(top);
    }
    let body_n = (body_bot - body_top + 1) as u32;
    (body_top, body_bot, body_n)
}

fn skip_char(ch: &EffectCharacter) -> bool {
    ch.is_fill_character || ch.input_symbol.trim().is_empty()
}

fn skip_slot(engine: &Engine, slot: u32) -> bool {
    engine.is_fill(slot) || engine.symbol(engine.input_sym(slot)).trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_units_are_four_three_four_three_five() {
        assert_eq!(FIELD_BAND_UNITS, &[4, 3, 4, 3, 5]);
        assert_eq!(field_band_rows(), 19);
    }

    #[test]
    fn index_follows_crest_hover_lit_mid_dim() {
        assert_eq!(field_band_index(0.0), 0);
        assert_eq!(field_band_index(4.0 / 19.0 - 1e-9), 0);
        assert_eq!(field_band_index(4.0 / 19.0), 1);
        assert_eq!(field_band_index(7.0 / 19.0), 2);
        assert_eq!(field_band_index(11.0 / 19.0), 3);
        assert_eq!(field_band_index(14.0 / 19.0), 4);
        assert_eq!(field_band_index(1.0), 4);
    }

    #[test]
    fn apply_colors_thirteen_rows_crest_to_dim() {
        use crate::engine::terminal::{Terminal, TerminalConfig};
        use crate::utils::palette::Palette;

        let input = ["X"; 13].join("\n");
        let mut terminal = Terminal::new(
            &input,
            TerminalConfig {
                canvas_width: 1,
                canvas_height: 13,
                ignore_terminal_dimensions: true,
                ..Default::default()
            },
        )
        .unwrap();
        let palette = Palette::from_hex_list("aa0000,00aa00,0000aa,aaaa00,00aaaa").unwrap();
        apply_field_bands(&mut terminal, &palette);

        let mut by_row: Vec<(i64, crate::utils::graphics::Color)> = terminal
            .input_characters
            .iter()
            .map(|&id| {
                let ch = &terminal.arena[id.0 as usize];
                assert!(ch.uses_input_preexisting_colors);
                (ch.input_coord.row, ch.animation.input_fg_color.unwrap())
            })
            .collect();
        by_row.sort_by_key(|(row, _)| std::cmp::Reverse(*row));

        // 4-3-4-3-5 on 13 rows is 3-2-3-2-3.
        let expected = [0, 0, 0, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4];
        assert_eq!(by_row.len(), 13);
        for (i, (row, color)) in by_row.iter().enumerate() {
            assert_eq!(*row, 13 - i as i64);
            assert_eq!(*color, palette.color(expected[i]));
        }
    }

    #[test]
    fn apply_colors_nineteen_rows_keep_unit_proportions() {
        use crate::engine::terminal::{Terminal, TerminalConfig};
        use crate::utils::palette::Palette;

        let input = ["X"; 19].join("\n");
        let mut terminal = Terminal::new(
            &input,
            TerminalConfig {
                canvas_width: 1,
                canvas_height: 19,
                ignore_terminal_dimensions: true,
                ..Default::default()
            },
        )
        .unwrap();
        let palette = Palette::from_hex_list("111111,222222,333333,444444,555555").unwrap();
        apply_field_bands(&mut terminal, &palette);

        let mut by_row: Vec<(i64, usize)> = terminal
            .input_characters
            .iter()
            .map(|&id| {
                let ch = &terminal.arena[id.0 as usize];
                let color = ch.animation.input_fg_color.unwrap();
                let idx = (0..5)
                    .find(|&i| palette.color(i) == color)
                    .expect("palette color");
                (ch.input_coord.row, idx)
            })
            .collect();
        by_row.sort_by_key(|(row, _)| std::cmp::Reverse(*row));

        let expected = [0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 4];
        assert_eq!(by_row.len(), 19);
        for (i, (row, idx)) in by_row.iter().enumerate() {
            assert_eq!(*row, 19 - i as i64);
            assert_eq!(*idx, expected[i], "row {i}");
        }
    }

    #[test]
    fn discrete_rows_never_drop_a_band() {
        assert_eq!(field_band_counts(19), vec![4, 3, 4, 3, 5]);
        assert_eq!(field_band_counts(13), vec![3, 2, 3, 2, 3]);
        assert_eq!(field_band_counts(8), vec![2, 1, 2, 1, 2]);
        for n in 5..=40 {
            let counts = field_band_counts(n);
            assert_eq!(counts.iter().sum::<u32>(), n, "n={n}");
            assert!(
                counts.iter().all(|&c| c >= 1),
                "n={n} skipped a band: {counts:?}"
            );
        }
    }

    fn band_of(ch: &crate::engine::character::EffectCharacter, palette: &Palette) -> usize {
        let color = ch.animation.input_fg_color.unwrap();
        (0..5)
            .find(|&i| palette.color(i) == color)
            .expect("palette color")
    }

    #[test]
    fn ten_line_word_shows_all_five_stripes() {
        use crate::engine::terminal::{Terminal, TerminalConfig};
        use crate::utils::palette::Palette;

        let mut lines = vec!["  ▄  ".to_string(), "▄███▄".to_string()];
        for _ in 0..6 {
            lines.push("█████".to_string());
        }
        lines.push("▀███▀".to_string());
        lines.push("  █  ".to_string());
        let input = lines.join("\n");
        let mut terminal = Terminal::new(
            &input,
            TerminalConfig {
                canvas_width: 5,
                canvas_height: 10,
                ignore_terminal_dimensions: true,
                ..Default::default()
            },
        )
        .unwrap();
        let palette = Palette::from_hex_list("111111,222222,333333,444444,555555").unwrap();
        apply_field_bands(&mut terminal, &palette);

        let mut by_row: Vec<(i64, usize)> = terminal
            .input_characters
            .iter()
            .filter_map(|&id| {
                let ch = &terminal.arena[id.0 as usize];
                if ch.input_coord.column != 3 {
                    return None;
                }
                Some((ch.input_coord.row, band_of(ch, &palette)))
            })
            .collect();
        by_row.sort_by_key(|(row, _)| std::cmp::Reverse(*row));
        let bands: Vec<usize> = by_row.into_iter().map(|(_, b)| b).collect();
        // Sparse peak (row 0) and tail stay crest/dim; 4-3-4-3-5 is 2-1-2-1-2
        // on the 8 body rows, so the first two full letter rows are crest.
        assert_eq!(bands, vec![0, 0, 0, 1, 2, 2, 3, 4, 4, 4]);
    }

    #[test]
    fn fx_engine_matches_original_thirteen_row_bands() {
        use crate::engine::ctx::Clock;
        use crate::engine::terminal::TerminalConfig;
        use crate::fx::Engine;
        use crate::utils::palette::Palette;
        use crate::utils::rng::Rng;

        let input = ["X"; 13].join("\n");
        let config = TerminalConfig {
            canvas_width: 1,
            canvas_height: 13,
            ignore_terminal_dimensions: true,
            ..Default::default()
        };
        let mut engine = Engine::new(
            &input,
            config,
            Rng::seeded(1),
            Clock::virtual_with_frame_rate(60),
        )
        .unwrap();
        let palette = Palette::from_hex_list("aa0000,00aa00,0000aa,aaaa00,00aaaa").unwrap();
        apply_field_bands_fx(&mut engine, &palette);
        assert!(engine.preexisting_colors_present);

        let mut by_row: Vec<(i64, crate::utils::graphics::Color)> = engine
            .input_chars
            .iter()
            .map(|&slot| {
                assert!(engine.uses_preexisting_colors(slot));
                (
                    engine.ch.input_coord[slot as usize].row,
                    engine.ch.fg[slot as usize].unwrap(),
                )
            })
            .collect();
        by_row.sort_by_key(|(row, _)| std::cmp::Reverse(*row));
        let expected = [0, 0, 0, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4];
        assert_eq!(by_row.len(), 13);
        for (i, (row, color)) in by_row.iter().enumerate() {
            assert_eq!(*row, 13 - i as i64);
            assert_eq!(*color, palette.color(expected[i]));
        }
    }
}
