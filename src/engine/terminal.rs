//! Terminal: config, canvas assembly, character queries, renderer, tty output.
//! Ported from engine/terminal.py. Unlike upstream (which builds two Terminals
//! per run), this single Terminal owns both the simulation and the tty side.

use std::collections::HashMap;
#[cfg(not(target_arch = "wasm32"))]
use std::io::Write;
#[cfg(not(target_arch = "wasm32"))]
use std::time::Instant;

use crate::engine::animation::ExistingColorHandling;
use crate::engine::canvas::{Anchor, Canvas};
use crate::engine::character::{CharId, EffectCharacter};
use crate::engine::error::EngineError;
use crate::engine::input::{ColorFrequency, Preprocessor};
#[cfg(not(target_arch = "wasm32"))]
use crate::utils::ansi;
use crate::utils::geometry::Coord;
use crate::utils::graphics::Color;
use crate::utils::rng::Rng;

const EMPTY_RENDER_CELL: u32 = u32::MAX;
const NOT_VISIBLE: usize = usize::MAX;

#[derive(Debug, Clone)]
pub struct TerminalConfig {
    pub tab_width: i64,
    pub xterm_colors: bool,
    pub no_color: bool,
    pub terminal_background_color: Color,
    pub existing_color_handling: ExistingColorHandling,
    pub wrap_text: bool,
    pub frame_rate: i64,
    pub canvas_width: i64,
    pub canvas_height: i64,
    pub anchor_canvas: Anchor,
    pub anchor_text: Anchor,
    pub ignore_terminal_dimensions: bool,
    pub reuse_canvas: bool,
    pub no_eol: bool,
    pub no_restore_cursor: bool,
    /// When set, skip tty/`COLUMNS`/`LINES` probing and use this size.
    pub terminal_size: Option<(i64, i64)>,
}

impl Default for TerminalConfig {
    fn default() -> Self {
        TerminalConfig {
            tab_width: 4,
            xterm_colors: false,
            no_color: false,
            terminal_background_color: Color::from_hex("000000").unwrap(),
            existing_color_handling: ExistingColorHandling::Ignore,
            wrap_text: false,
            frame_rate: 60,
            canvas_width: -1,
            canvas_height: -1,
            anchor_canvas: Anchor::Sw,
            anchor_text: Anchor::Sw,
            ignore_terminal_dimensions: false,
            reuse_canvas: false,
            no_eol: false,
            no_restore_cursor: false,
            terminal_size: None,
        }
    }
}

/// CharacterSort (argutils.CharacterSort).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharacterSort {
    Random,
    TopToBottomLeftToRight,
    BottomToTopRightToLeft,
    BottomToTopLeftToRight,
    TopToBottomRightToLeft,
    OutsideRowToMiddle,
    MiddleRowToOutside,
}

/// CharacterGroup (argutils.CharacterGroup).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharacterGroup {
    ColumnLeftToRight,
    ColumnRightToLeft,
    RowTopToBottom,
    RowBottomToTop,
    DiagonalBottomLeftToTopRight,
    DiagonalTopRightToBottomLeft,
    DiagonalTopLeftToBottomRight,
    DiagonalBottomRightToTopLeft,
    CenterToOutside,
    OutsideToCenter,
}

/// ColorSort (argutils.ColorSort).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSort {
    LeastToMost,
    MostToLeast,
    Random,
}

/// Which character populations to include in a query (the four bool kwargs).
#[derive(Debug, Clone, Copy)]
pub struct CharacterFilter {
    pub input_chars: bool,
    pub inner_fill_chars: bool,
    pub outer_fill_chars: bool,
    pub added_chars: bool,
}

impl Default for CharacterFilter {
    fn default() -> Self {
        CharacterFilter { input_chars: true, inner_fill_chars: false, outer_fill_chars: false, added_chars: false }
    }
}

pub struct Terminal {
    pub config: TerminalConfig,
    pub canvas: Canvas,
    pub arena: Vec<EffectCharacter>,
    next_character_id: u32,
    pub input_colors_frequency: ColorFrequency,
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    terminal_dimensions: (i64, i64),
    #[cfg(not(target_arch = "wasm32"))]
    resize_seen_at: Option<Instant>,
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    layout: Layout,
    /// Pre-wrap input line lengths — all `compute_layout` needs from the input,
    /// so a resize can re-derive the geometry without re-preprocessing.
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    input_line_lengths: Vec<i64>,
    pub canvas_column_offset: i64,
    pub canvas_row_offset: i64,
    pub visible_top: i64,
    pub visible_bottom: i64,
    pub visible_right: i64,
    pub visible_left: i64,
    pub input_characters: Vec<CharId>,
    pub added_characters: Vec<CharId>,
    pub character_by_input_coord: HashMap<Coord, CharId>,
    pub inner_fill_characters: Vec<CharId>,
    pub outer_fill_characters: Vec<CharId>,
    visible_characters: Vec<CharId>,
    visible_positions: Vec<usize>,
    render_cells: Vec<u32>,
    #[cfg(not(target_arch = "wasm32"))]
    pub terminal_state: Vec<String>,
    #[cfg(not(target_arch = "wasm32"))]
    output_buffer: String,
    #[cfg(not(target_arch = "wasm32"))]
    move_cursor_to_top: String,
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    frame_rate: i64,
    #[cfg(not(target_arch = "wasm32"))]
    last_time_printed: Option<Instant>,
}

fn ordered_buckets(
    characters: Vec<CharId>,
    first_key: i64,
    last_key: i64,
    mut key: impl FnMut(CharId) -> i64,
) -> Vec<Vec<CharId>> {
    if first_key > last_key {
        return Vec::new();
    }
    let bucket_count = last_key
        .checked_sub(first_key)
        .and_then(|span| span.checked_add(1))
        .and_then(|span| usize::try_from(span).ok())
        .expect("terminal canvas is too large");
    let expected_bucket_len = characters.len() / bucket_count;
    let mut buckets: Vec<Vec<CharId>> = (0..bucket_count)
        .map(|_| Vec::with_capacity(expected_bucket_len))
        .collect();
    for id in characters {
        let character_key = key(id);
        if first_key <= character_key && character_key <= last_key {
            buckets[(character_key - first_key) as usize].push(id);
        }
    }
    buckets.into_iter().filter(|bucket| !bucket.is_empty()).collect()
}

impl Terminal {
    pub fn new(input_data: &str, config: TerminalConfig) -> Result<Self, EngineError> {
        let input_data = if input_data.is_empty() { "No Input." } else { input_data };
        let mut arena: Vec<EffectCharacter> = Vec::new();
        let mut next_character_id: u32 = 0;
        let mut input_colors_frequency = ColorFrequency::default();

        let preprocessed_lines = Preprocessor {
            arena: &mut arena,
            next_character_id: &mut next_character_id,
            input_colors_frequency: &mut input_colors_frequency,
            config: &config,
        }
        .preprocess(input_data)?;

        let input_line_lengths: Vec<i64> = preprocessed_lines.iter().map(|l| l.len() as i64).collect();
        let terminal_dimensions = get_terminal_dimensions(&config);
        let layout = compute_layout(&config, &input_line_lengths, terminal_dimensions.0, terminal_dimensions.1);
        let mut canvas = Canvas::new(layout.canvas_height, layout.canvas_width);
        let Layout {
            column_offset: canvas_column_offset,
            row_offset: canvas_row_offset,
            visible_top,
            visible_bottom,
            visible_right,
            visible_left,
            ..
        } = layout;

        let input_characters = setup_input_characters(&config, &mut canvas, &mut arena, preprocessed_lines)?
            .into_iter()
            .filter(|&id| {
                let coord = arena[id.0 as usize].input_coord;
                coord.row <= canvas.top && coord.column <= canvas.right
            })
            .collect::<Vec<_>>();

        let mut character_by_input_coord: HashMap<Coord, CharId> = HashMap::new();
        for &id in &input_characters {
            character_by_input_coord.insert(arena[id.0 as usize].input_coord, id);
        }

        let frame_rate = config.frame_rate;
        let arena_len = arena.len();
        #[cfg(not(target_arch = "wasm32"))]
        let move_cursor_to_top = format!(
            "{}{}{}",
            ansi::DEC_RESTORE_CURSOR,
            ansi::DEC_SAVE_CURSOR,
            ansi::move_cursor_up(visible_top.max(0) as usize)
        );
        let mut terminal = Terminal {
            config,
            canvas,
            arena,
            next_character_id,
            input_colors_frequency,
            terminal_dimensions,
            #[cfg(not(target_arch = "wasm32"))]
            resize_seen_at: None,
            layout,
            input_line_lengths,
            canvas_column_offset,
            canvas_row_offset,
            visible_top,
            visible_bottom,
            visible_right,
            visible_left,
            input_characters,
            added_characters: Vec::new(),
            character_by_input_coord,
            inner_fill_characters: Vec::new(),
            outer_fill_characters: Vec::new(),
            visible_characters: Vec::new(),
            visible_positions: vec![NOT_VISIBLE; arena_len],
            render_cells: Vec::new(),
            #[cfg(not(target_arch = "wasm32"))]
            terminal_state: Vec::new(),
            #[cfg(not(target_arch = "wasm32"))]
            output_buffer: String::new(),
            #[cfg(not(target_arch = "wasm32"))]
            move_cursor_to_top,
            frame_rate,
            #[cfg(not(target_arch = "wasm32"))]
            last_time_printed: Some(Instant::now()),
        };
        terminal.make_fill_characters();
        terminal.setup_character_neighbors();
        #[cfg(not(target_arch = "wasm32"))]
        terminal.update_terminal_state();
        Ok(terminal)
    }

    /// Terminal._make_fill_characters: row-major from (1,1), fresh space chars
    /// for unoccupied canvas coords, split inner/outer by the text bounds.
    fn make_fill_characters(&mut self) {
        for row in 1..=self.canvas.top {
            for column in 1..=self.canvas.right {
                let coord = Coord::new(column, row);
                if !self.character_by_input_coord.contains_key(&coord) {
                    let mut fill = EffectCharacter::new(self.next_character_id, " ", column, row);
                    fill.is_fill_character = true;
                    fill.animation.no_color = self.config.no_color;
                    fill.animation.use_xterm_colors = self.config.xterm_colors;
                    fill.animation.existing_color_handling = self.config.existing_color_handling;
                    fill.uses_input_preexisting_colors = false;
                    self.next_character_id += 1;
                    let id = CharId(self.arena.len() as u32);
                    self.arena.push(fill);
                    self.character_by_input_coord.insert(coord, id);
                    if self.canvas.text_left <= column
                        && column <= self.canvas.text_right
                        && self.canvas.text_bottom <= row
                        && row <= self.canvas.text_top
                    {
                        self.inner_fill_characters.push(id);
                    } else {
                        self.outer_fill_characters.push(id);
                    }
                }
            }
        }
    }

    fn setup_character_neighbors(&mut self) {
        let coords: Vec<(Coord, CharId)> = self.character_by_input_coord.iter().map(|(&c, &id)| (c, id)).collect();
        for (coord, id) in coords {
            let n = self.character_by_input_coord.get(&Coord::new(coord.column, coord.row + 1)).copied();
            let e = self.character_by_input_coord.get(&Coord::new(coord.column + 1, coord.row)).copied();
            let s = self.character_by_input_coord.get(&Coord::new(coord.column, coord.row - 1)).copied();
            let w = self.character_by_input_coord.get(&Coord::new(coord.column - 1, coord.row)).copied();
            let ch = &mut self.arena[id.0 as usize];
            ch.neighbors.north = n;
            ch.neighbors.east = e;
            ch.neighbors.south = s;
            ch.neighbors.west = w;
        }
    }

    /// Terminal.add_character: registered only in added_characters, not in
    /// character_by_input_coord or the neighbor map.
    pub fn add_character(&mut self, symbol: &str, coord: Coord) -> CharId {
        let mut ch = EffectCharacter::new(self.next_character_id, symbol, coord.column, coord.row);
        ch.animation.no_color = self.config.no_color;
        ch.animation.use_xterm_colors = self.config.xterm_colors;
        ch.animation.existing_color_handling = self.config.existing_color_handling;
        ch.uses_input_preexisting_colors = false;
        self.next_character_id += 1;
        let id = CharId(self.arena.len() as u32);
        self.arena.push(ch);
        self.added_characters.push(id);
        id
    }

    pub fn get_character_by_input_coord(&self, coord: Coord) -> Option<CharId> {
        self.character_by_input_coord.get(&coord).copied()
    }

    pub fn set_character_visibility(&mut self, id: CharId, is_visible: bool) {
        let arena_index = id.0 as usize;
        if self.arena[arena_index].is_visible == is_visible {
            return;
        }
        self.arena[arena_index].is_visible = is_visible;
        self.visible_positions.resize(self.arena.len(), NOT_VISIBLE);
        if is_visible {
            self.visible_positions[arena_index] = self.visible_characters.len();
            self.visible_characters.push(id);
        } else {
            let position = std::mem::replace(&mut self.visible_positions[arena_index], NOT_VISIBLE);
            self.visible_characters.swap_remove(position);
            if position < self.visible_characters.len() {
                let moved = self.visible_characters[position];
                self.visible_positions[moved.0 as usize] = position;
            }
        }
    }

    /// Terminal.get_input_colors. Equal-count ties keep insertion order
    /// (Python's stable sort over dict keys).
    pub fn get_input_colors(&self, rng: &mut Rng, sort: ColorSort) -> Vec<Color> {
        let mut colors: Vec<(Color, i64)> = self.input_colors_frequency.0.clone();
        match sort {
            ColorSort::MostToLeast => {
                // Python: sorted(keys, key=count, reverse=True) — reverse of a
                // stable ascending sort reverses tie order too; replicate by
                // sorting descending with stable tie order = insertion order.
                colors.sort_by(|a, b| b.1.cmp(&a.1));
            }
            ColorSort::LeastToMost => {
                colors.sort_by(|a, b| a.1.cmp(&b.1));
            }
            ColorSort::Random => {
                rng.shuffle(&mut colors);
            }
        }
        colors.into_iter().map(|(c, _)| c).collect()
    }

    pub fn collect_characters(&self, filter: CharacterFilter) -> Vec<CharId> {
        let capacity = if filter.input_chars { self.input_characters.len() } else { 0 }
            + if filter.inner_fill_chars { self.inner_fill_characters.len() } else { 0 }
            + if filter.outer_fill_chars { self.outer_fill_characters.len() } else { 0 }
            + if filter.added_chars { self.added_characters.len() } else { 0 };
        let mut all: Vec<CharId> = Vec::with_capacity(capacity);
        if filter.input_chars {
            all.extend(&self.input_characters);
        }
        if filter.inner_fill_chars {
            all.extend(&self.inner_fill_characters);
        }
        if filter.outer_fill_chars {
            all.extend(&self.outer_fill_characters);
        }
        if filter.added_chars {
            all.extend(&self.added_characters);
        }
        all
    }

    /// Terminal.get_characters with all sort variants.
    pub fn get_characters(&self, rng: &mut Rng, filter: CharacterFilter, sort: CharacterSort) -> Vec<CharId> {
        let mut all = self.collect_characters(filter);
        // default sort: (-row, column), stable
        all.sort_by_key(|&id| {
            let c = self.arena[id.0 as usize].input_coord;
            (-c.row, c.column)
        });
        match sort {
            CharacterSort::Random => rng.shuffle(&mut all),
            CharacterSort::TopToBottomLeftToRight => {}
            CharacterSort::BottomToTopRightToLeft => all.reverse(),
            CharacterSort::BottomToTopLeftToRight | CharacterSort::TopToBottomRightToLeft => {
                all.sort_by_key(|&id| {
                    let c = self.arena[id.0 as usize].input_coord;
                    (c.row, c.column)
                });
                if sort == CharacterSort::TopToBottomRightToLeft {
                    all.reverse();
                }
            }
            CharacterSort::OutsideRowToMiddle | CharacterSort::MiddleRowToOutside => {
                // upstream: alternate pop(0)/pop(-1)
                let mut deque: std::collections::VecDeque<CharId> = all.into();
                let mut interleaved = Vec::with_capacity(deque.len());
                let mut from_front = true;
                while let Some(id) = if from_front { deque.pop_front() } else { deque.pop_back() } {
                    interleaved.push(id);
                    from_front = !from_front;
                }
                all = interleaved;
                if sort == CharacterSort::MiddleRowToOutside {
                    all.reverse();
                }
            }
        }
        all
    }

    /// Terminal.get_characters_grouped with all grouping variants.
    pub fn get_characters_grouped(&self, filter: CharacterFilter, grouping: CharacterGroup) -> Vec<Vec<CharId>> {
        let mut all = self.collect_characters(filter);
        all.sort_by_key(|&id| {
            let c = self.arena[id.0 as usize].input_coord;
            (c.row, c.column)
        });
        let coord = |id: &CharId| self.arena[id.0 as usize].input_coord;
        match grouping {
            CharacterGroup::ColumnLeftToRight | CharacterGroup::ColumnRightToLeft => {
                let mut columns = ordered_buckets(all, 0, self.canvas.right, |id| coord(&id).column);
                if grouping == CharacterGroup::ColumnRightToLeft {
                    columns.reverse();
                }
                columns
            }
            CharacterGroup::RowBottomToTop | CharacterGroup::RowTopToBottom => {
                let mut rows = ordered_buckets(all, 0, self.canvas.top, |id| coord(&id).row);
                if grouping == CharacterGroup::RowTopToBottom {
                    rows.reverse();
                }
                rows
            }
            CharacterGroup::DiagonalBottomLeftToTopRight | CharacterGroup::DiagonalTopRightToBottomLeft => {
                let mut diagonals = ordered_buckets(all, 0, self.canvas.top + self.canvas.right, |id| {
                    let c = coord(&id);
                    c.row + c.column
                });
                if grouping == CharacterGroup::DiagonalTopRightToBottomLeft {
                    diagonals.reverse();
                }
                diagonals
            }
            CharacterGroup::DiagonalTopLeftToBottomRight | CharacterGroup::DiagonalBottomRightToTopLeft => {
                let mut diagonals = ordered_buckets(
                    all,
                    self.canvas.left - self.canvas.top,
                    self.canvas.right - self.canvas.bottom,
                    |id| {
                        let c = coord(&id);
                        c.column - c.row
                    },
                );
                if grouping == CharacterGroup::DiagonalBottomRightToTopLeft {
                    diagonals.reverse();
                }
                diagonals
            }
            CharacterGroup::CenterToOutside | CharacterGroup::OutsideToCenter => {
                let max_distance = all
                    .iter()
                    .map(|&id| {
                        let c = coord(&id);
                        (c.column - self.canvas.text_center.column).abs()
                            + (c.row - self.canvas.text_center.row).abs()
                    })
                    .max();
                let dense_limit = all.len().saturating_mul(4).max(256);
                let mut groups = if max_distance
                    .and_then(|distance| usize::try_from(distance).ok())
                    .is_some_and(|distance| distance <= dense_limit)
                {
                    ordered_buckets(all, 0, max_distance.unwrap(), |id| {
                        let c = coord(&id);
                        (c.column - self.canvas.text_center.column).abs()
                            + (c.row - self.canvas.text_center.row).abs()
                    })
                } else {
                    // Out-of-canvas added characters can have sparse, arbitrarily
                    // large distances; avoid allocating through the largest key.
                    let mut distances: HashMap<i64, Vec<CharId>> = HashMap::new();
                    for id in all {
                        let c = coord(&id);
                        let distance = (c.column - self.canvas.text_center.column).abs()
                            + (c.row - self.canvas.text_center.row).abs();
                        distances.entry(distance).or_default().push(id);
                    }
                    let mut distances: Vec<(i64, Vec<CharId>)> = distances.into_iter().collect();
                    distances.sort_by_key(|&(distance, _)| distance);
                    distances.into_iter().map(|(_, group)| group).collect()
                };
                if grouping == CharacterGroup::OutsideToCenter {
                    groups.reverse();
                }
                groups
            }
        }
    }

    /// Paint the visible characters into the reusable cell buffer using the
    /// canonical (layer, character_id) painter order (plan.md §4.3).
    fn update_render_cells(&mut self) -> (usize, usize) {
        let width = self.visible_right.max(0) as usize;
        let height = self.visible_top.max(0) as usize;
        let cell_count = width.checked_mul(height).expect("terminal canvas is too large");
        self.render_cells.resize(cell_count, EMPTY_RENDER_CELL);
        self.render_cells.fill(EMPTY_RENDER_CELL);

        // The old implementation sorted every visible character by painter
        // order and overwrote cells in that order.  A cell only needs the
        // maximum key, so select that winner directly and avoid the per-frame
        // allocation and O(n log n) sort.
        for &id in &self.visible_characters {
            let ch = &self.arena[id.0 as usize];
            let row = ch.motion.current_coord.row + self.canvas_row_offset;
            let column = ch.motion.current_coord.column + self.canvas_column_offset;
            if self.visible_bottom <= row
                && row <= self.visible_top
                && self.visible_left <= column
                && column <= self.visible_right
            {
                let cell = &mut self.render_cells[(row - 1) as usize * width + (column - 1) as usize];
                if *cell == EMPTY_RENDER_CELL {
                    *cell = id.0;
                } else {
                    let painted = &self.arena[*cell as usize];
                    if (ch.layer, ch.character_id) > (painted.layer, painted.character_id) {
                        *cell = id.0;
                    }
                }
            }
        }

        (width, height)
    }

    /// Terminal._update_terminal_state: materialize the row-oriented state
    /// exposed by the upstream API. Frame output uses the cell buffer directly
    /// so the hot path does not copy every rendered byte through these rows.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn update_terminal_state(&mut self) {
        let (width, height) = self.update_render_cells();

        self.terminal_state.resize_with(height, String::new);
        self.terminal_state.truncate(height);
        let arena = &self.arena;
        for (row_index, row) in self.terminal_state.iter_mut().enumerate() {
            row.clear();
            if row.capacity() < width {
                row.reserve(width);
            }
            for &cell in &self.render_cells[row_index * width..(row_index + 1) * width] {
                if cell == EMPTY_RENDER_CELL {
                    row.push(' ');
                } else {
                    row.push_str(arena[cell as usize].animation.current_character_visual.formatted_symbol.as_str());
                }
            }
        }
    }

    /// get_formatted_output_string: refresh + emit top row first.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn get_formatted_output_string(&mut self) -> String {
        let (width, height) = self.update_render_cells();
        let minimum_capacity = width
            .checked_mul(height)
            .and_then(|cells| cells.checked_add(height.saturating_sub(1)))
            .expect("terminal canvas is too large");
        let mut out = std::mem::take(&mut self.output_buffer).into_bytes();
        out.clear();
        if out.capacity() < minimum_capacity {
            out.reserve(minimum_capacity);
        }
        let arena = &self.arena;
        for row_index in (0..height).rev() {
            if row_index + 1 < height {
                out.push(b'\n');
            }
            for &cell in &self.render_cells[row_index * width..(row_index + 1) * width] {
                if cell == EMPTY_RENDER_CELL {
                    out.push(b' ');
                } else {
                    arena[cell as usize].animation.current_character_visual.formatted_symbol.append_to(&mut out);
                }
            }
        }
        // SAFETY: every appended run is a whole formatted symbol, which is UTF-8.
        unsafe { String::from_utf8_unchecked(out) }
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) fn recycle_output_string(&mut self, mut output: String) {
        output.clear();
        if output.capacity() > self.output_buffer.capacity() {
            self.output_buffer = output;
        }
    }

    /// Whether a resize has landed, settled, and actually moved something.
    ///
    /// Settled: dragging a window edge emits a SIGWINCH per step, and rebuilding
    /// for each one pins the animation at its opening frames for the whole drag.
    /// Each signal restarts a quiet window; the old canvas keeps animating until
    /// it expires, so the wait costs nothing on screen.
    ///
    /// Moved something: a new terminal size is not enough. With an input-sized
    /// canvas and no anchor offsets most resizes leave every rendered cell
    /// exactly where it was, and restarting for those is pure loss. Explicitly
    /// ignored dimensions are fixed by definition.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn resize_settled(&mut self) -> bool {
        const QUIET: std::time::Duration = std::time::Duration::from_millis(50);

        if crate::take_terminal_resize() {
            self.resize_seen_at = Some(Instant::now());
        }
        match self.resize_seen_at {
            Some(seen) if seen.elapsed() >= QUIET => self.resize_seen_at = None,
            _ => return false,
        }
        if self.config.ignore_terminal_dimensions {
            return false;
        }
        let (width, height) = get_terminal_dimensions(&self.config);
        if (width, height) == self.terminal_dimensions {
            return false;
        }
        compute_layout(&self.config, &self.input_line_lengths, width, height) != self.layout
    }

    /// After a resize: go back to the top of the area this run allocated, wipe
    /// it, and leave the cursor there so the rebuilt canvas takes the same rows
    /// instead of scrolling a second one into the terminal.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn reset_canvas_area(&self, out: &mut impl Write) -> std::io::Result<()> {
        out.write_all(ansi::DEC_RESTORE_CURSOR.as_bytes())?;
        if self.visible_top > 0 {
            out.write_all(ansi::move_cursor_up(self.visible_top as usize).as_bytes())?;
        }
        out.write_all(ansi::CLEAR_TO_END_OF_SCREEN.as_bytes())?;
        Ok(())
    }

    // --- tty side (upstream's second Terminal instance) ---

    #[cfg(not(target_arch = "wasm32"))]
    pub fn prep_canvas(&mut self, out: &mut impl Write) -> std::io::Result<()> {
        out.write_all(ansi::HIDE_CURSOR.as_bytes())?;
        if self.config.reuse_canvas {
            self.write_move_cursor_to_top(out)?;
        }
        for _ in 0..self.visible_top {
            let blank = " ".repeat(self.visible_right.max(0) as usize);
            out.write_all(blank.as_bytes())?;
            out.write_all(b"\n")?;
        }
        out.write_all(ansi::DEC_SAVE_CURSOR.as_bytes())?;
        Ok(())
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn restore_cursor(&self, out: &mut impl Write, end_symbol: &str) -> std::io::Result<()> {
        let end_symbol = if self.config.no_eol { "" } else { end_symbol };
        if !self.config.no_restore_cursor {
            out.write_all(ansi::SHOW_CURSOR.as_bytes())?;
        }
        out.write_all(end_symbol.as_bytes())?;
        Ok(())
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn print_frame(&mut self, out: &mut impl Write, output_string: &str) -> std::io::Result<()> {
        self.write_move_cursor_to_top(out)?;
        out.write_all(output_string.as_bytes())?;
        out.flush()
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn write_move_cursor_to_top(&self, out: &mut impl Write) -> std::io::Result<()> {
        out.write_all(self.move_cursor_to_top.as_bytes())
    }

    /// Terminal.enforce_framerate: sleep off the remainder; timestamp taken
    /// AFTER the sleep (drift accumulates, faithfully).
    #[cfg(not(target_arch = "wasm32"))]
    pub fn enforce_framerate(&mut self) {
        if self.frame_rate == 0 {
            return;
        }
        let frame_delay = 1.0 / self.frame_rate as f64;
        let elapsed = self
            .last_time_printed
            .map(|t| t.elapsed().as_secs_f64())
            .unwrap_or(0.0);
        if elapsed < frame_delay {
            std::thread::sleep(std::time::Duration::from_secs_f64(frame_delay - elapsed));
        }
        self.last_time_printed = Some(Instant::now());
    }

    /// Display-order cell buffer (top-left first) for non-ANSI frontends.
    pub fn pack_display_frame(&mut self) -> PackedFrame {
        let (width, height) = self.update_render_cells();
        let cells = width.saturating_mul(height);
        let mut symbols = Vec::with_capacity(cells);
        let mut fg = Vec::with_capacity(cells);
        let mut bg = Vec::with_capacity(cells);
        let mut flags = Vec::with_capacity(cells);
        let arena = &self.arena;
        for row_index in (0..height).rev() {
            for &cell in &self.render_cells[row_index * width..(row_index + 1) * width] {
                if cell == EMPTY_RENDER_CELL {
                    symbols.push(b' ' as u32);
                    fg.push(0);
                    bg.push(0);
                    flags.push(0);
                    continue;
                }
                let visual = &arena[cell as usize].animation.current_character_visual;
                let ch = visual.symbol.chars().next().unwrap_or(' ');
                symbols.push(if visual.hidden { b' ' as u32 } else { ch as u32 });
                // Wasm Session never sets xterm_colors or no_color; packed cells
                // already have 24-bit RGB on Color, so skip the ColorCode hex
                // round-trip (to_string + parse) that native SGR still needs.
                #[cfg(target_arch = "wasm32")]
                let (mut cell_fg, mut cell_bg) = {
                    let pair = visual.colors.as_ref();
                    (
                        packed_rgba(pair.and_then(|p| p.fg_color.as_ref())),
                        packed_rgba(pair.and_then(|p| p.bg_color.as_ref())),
                    )
                };
                #[cfg(not(target_arch = "wasm32"))]
                let mut cell_fg = visual
                    .fg_color_code
                    .as_ref()
                    .map(crate::utils::ansi::ColorCode::rgb_u32)
                    .unwrap_or(0);
                #[cfg(not(target_arch = "wasm32"))]
                let mut cell_bg = visual
                    .bg_color_code
                    .as_ref()
                    .map(crate::utils::ansi::ColorCode::rgb_u32)
                    .unwrap_or(0);
                if visual.reverse {
                    if cell_fg == 0 {
                        cell_fg = 0xFFC0C0C0;
                    }
                    if cell_bg == 0 {
                        cell_bg = 0xFF000000;
                    }
                    std::mem::swap(&mut cell_fg, &mut cell_bg);
                }
                let mut cell_flags = 0u8;
                if visual.bold {
                    cell_flags |= PackedFrame::BOLD;
                }
                if visual.italic {
                    cell_flags |= PackedFrame::ITALIC;
                }
                if visual.underline {
                    cell_flags |= PackedFrame::UNDERLINE;
                }
                if visual.reverse {
                    cell_flags |= PackedFrame::REVERSE;
                }
                if visual.blink {
                    cell_flags |= PackedFrame::BLINK;
                }
                if visual.hidden {
                    cell_flags |= PackedFrame::HIDDEN;
                }
                if visual.strike {
                    cell_flags |= PackedFrame::STRIKE;
                }
                fg.push(cell_fg);
                bg.push(cell_bg);
                flags.push(cell_flags);
            }
        }
        PackedFrame {
            width,
            height,
            symbols,
            fg,
            bg,
            flags,
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn packed_rgba(color: Option<&Color>) -> u32 {
    let Some(color) = color else {
        return 0;
    };
    let (r, g, b) = color.rgb_ints();
    0xFF000000 | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
}

/// One rendered frame as parallel arrays, display-order, one Unicode scalar per cell.
#[derive(Debug, Clone)]
pub struct PackedFrame {
    pub width: usize,
    pub height: usize,
    pub symbols: Vec<u32>,
    pub fg: Vec<u32>,
    pub bg: Vec<u32>,
    pub flags: Vec<u8>,
}

impl PackedFrame {
    pub const BOLD: u8 = 1;
    pub const ITALIC: u8 = 2;
    pub const UNDERLINE: u8 = 4;
    pub const REVERSE: u8 = 8;
    pub const BLINK: u8 = 16;
    pub const HIDDEN: u8 = 32;
    pub const STRIKE: u8 = 64;

    pub fn cell_count(&self) -> usize {
        self.width.saturating_mul(self.height)
    }

    /// Copy this frame into caller-owned buffers. Extra capacity is left untouched.
    pub fn fill(
        &self,
        symbols: &mut [u32],
        fg: &mut [u32],
        bg: &mut [u32],
        flags: &mut [u8],
    ) -> Result<usize, &'static str> {
        let n = self.cell_count();
        if self.symbols.len() != n || self.fg.len() != n || self.bg.len() != n || self.flags.len() != n
        {
            return Err("packed frame is truncated");
        }
        if symbols.len() < n || fg.len() < n || bg.len() < n || flags.len() < n {
            return Err("frame buffers are too small");
        }
        symbols[..n].copy_from_slice(&self.symbols);
        fg[..n].copy_from_slice(&self.fg);
        bg[..n].copy_from_slice(&self.bg);
        flags[..n].copy_from_slice(&self.flags);
        Ok(n)
    }
}

/// shutil.get_terminal_size semantics: COLUMNS/LINES env vars win; else query
/// the tty; on failure (80, 24). `TerminalConfig::terminal_size` wins over all.
fn get_terminal_dimensions(config: &TerminalConfig) -> (i64, i64) {
    if let Some(size) = config.terminal_size {
        return size;
    }
    let env_dim = |name: &str| -> Option<i64> { std::env::var(name).ok()?.parse::<i64>().ok() };
    let columns = env_dim("COLUMNS");
    let lines = env_dim("LINES");
    if let (Some(c), Some(l)) = (columns, lines) {
        return (c, l);
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        match terminal_size::terminal_size() {
            Some((terminal_size::Width(w), terminal_size::Height(h))) => {
                return (columns.unwrap_or(w as i64), lines.unwrap_or(h as i64));
            }
            None => {}
        }
    }
    (columns.unwrap_or(80), lines.unwrap_or(24))
}

/// Everything about the drawing area that is derived from the terminal size.
/// A resize only matters if recomputing this yields something different, so it
/// is factored out of Terminal::new rather than inlined there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Layout {
    canvas_height: i64,
    canvas_width: i64,
    column_offset: i64,
    row_offset: i64,
    visible_top: i64,
    visible_bottom: i64,
    visible_right: i64,
    visible_left: i64,
}

fn compute_layout(
    config: &TerminalConfig,
    line_lengths: &[i64],
    terminal_width: i64,
    terminal_height: i64,
) -> Layout {
    let (canvas_height, canvas_width) =
        get_canvas_dimensions(config, line_lengths, terminal_width, terminal_height);
    let canvas = Canvas::new(canvas_height, canvas_width);
    let (mut width, mut height) = (terminal_width, terminal_height);
    let (column_offset, row_offset) = if !config.ignore_terminal_dimensions {
        calc_canvas_offsets(config, &canvas, width, height)
    } else {
        width = canvas.right;
        height = canvas.top;
        (0, 0)
    };
    Layout {
        canvas_height,
        canvas_width,
        column_offset,
        row_offset,
        visible_top: std::cmp::min(canvas.top + row_offset, height),
        visible_bottom: std::cmp::max(canvas.bottom + row_offset, 1),
        visible_right: std::cmp::min(canvas.right + column_offset, width),
        visible_left: std::cmp::max(canvas.left + column_offset, 1),
    }
}

/// Terminal._get_canvas_dimensions -> (height, width).
fn get_canvas_dimensions(
    config: &TerminalConfig,
    line_lengths: &[i64],
    terminal_width: i64,
    terminal_height: i64,
) -> (i64, i64) {
    let canvas_width = if config.canvas_width > 0 {
        config.canvas_width
    } else if config.canvas_width == 0 {
        terminal_width
    } else {
        let input_width = line_lengths.iter().copied().max().unwrap_or(0);
        if config.ignore_terminal_dimensions {
            input_width
        } else {
            std::cmp::min(terminal_width, input_width)
        }
    };
    let canvas_height = if config.canvas_height > 0 {
        config.canvas_height
    } else if config.canvas_height == 0 {
        terminal_height
    } else {
        let input_height = line_lengths.len() as i64;
        if config.ignore_terminal_dimensions {
            input_height
        } else if config.wrap_text {
            std::cmp::min(wrapped_line_count(line_lengths, canvas_width), terminal_height)
        } else {
            std::cmp::min(terminal_height, input_height)
        }
    };
    (canvas_height, canvas_width)
}

fn wrapped_line_count(line_lengths: &[i64], width: i64) -> i64 {
    let mut count: i64 = 0;
    for &length in line_lengths {
        let mut remaining = length;
        while remaining > width {
            count += 1;
            remaining -= width;
        }
        count += 1;
    }
    count
}

/// Terminal._wrap_lines.
fn wrap_lines(lines: Vec<Vec<CharId>>, width: i64) -> Vec<Vec<CharId>> {
    let mut wrapped: Vec<Vec<CharId>> = Vec::new();
    for line in lines {
        let mut current = line;
        while current.len() as i64 > width {
            let rest = current.split_off(width as usize);
            wrapped.push(current);
            current = rest;
        }
        wrapped.push(current);
    }
    wrapped
}

fn calc_canvas_offsets(
    config: &TerminalConfig,
    canvas: &Canvas,
    terminal_width: i64,
    terminal_height: i64,
) -> (i64, i64) {
    use crate::engine::canvas::Anchor::*;
    use crate::utils::pycompat::floor_div;
    let mut column_offset = 0;
    let mut row_offset = 0;
    match config.anchor_canvas {
        S | N | C => column_offset = floor_div(terminal_width, 2) - floor_div(canvas.width, 2),
        Se | E | Ne => column_offset = terminal_width - canvas.width,
        _ => {}
    }
    match config.anchor_canvas {
        W | E | C => row_offset = floor_div(terminal_height, 2) - floor_div(canvas.height, 2),
        Nw | N | Ne => row_offset = terminal_height - canvas.height,
        _ => {}
    }
    (column_offset, row_offset)
}

/// Terminal._setup_input_characters: wrap, assign 1-based bottom-up coords,
/// drop plain spaces (they become fill), anchor, and keep in-canvas chars.
fn setup_input_characters(
    config: &TerminalConfig,
    canvas: &mut Canvas,
    arena: &mut Vec<EffectCharacter>,
    preprocessed_lines: Vec<Vec<CharId>>,
) -> Result<Vec<CharId>, EngineError> {
    let formatted_lines = if config.wrap_text {
        wrap_lines(preprocessed_lines, canvas.right)
    } else {
        preprocessed_lines
    };
    let input_height = formatted_lines.len() as i64;
    let mut input_characters: Vec<CharId> = Vec::new();
    for (row, line) in formatted_lines.iter().enumerate() {
        for (column0, &id) in line.iter().enumerate() {
            let column = column0 as i64 + 1;
            let ch = &mut arena[id.0 as usize];
            ch.input_coord = Coord::new(column, input_height - row as i64);
            if ch.input_symbol != " "
                || ch.animation.input_fg_color.is_some()
                || ch.animation.input_bg_color.is_some()
            {
                input_characters.push(id);
            }
        }
    }
    canvas
        .anchor_text(arena, input_characters, config.anchor_text)
        .map_err(EngineError::Other)
}
