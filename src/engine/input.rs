//! Input preprocessing: the mini terminal emulator from Terminal._preprocess_input_data.
//!
//! Walks the input codepoint-by-codepoint (one char = one cell, faithfully — no
//! wcwidth upstream), tracking SGR color state and cursor movement, producing
//! rows of arena character ids. Everything here, including which malformed
//! sequences error vs. get silently ignored, transcribes terminal.py:604-862.

use std::collections::HashMap;

use crate::engine::animation::ExistingColorHandling;
use crate::engine::character::{CharId, EffectCharacter};
use crate::engine::error::EngineError;
use crate::engine::terminal::TerminalConfig;
use crate::utils::graphics::Color;

/// Insertion-ordered Color -> count map (upstream: dict[Color, int]). Iteration
/// order is behavior for get_input_colors; the population is small, linear scan.
#[derive(Debug, Default, Clone)]
pub struct ColorFrequency(pub Vec<(Color, i64)>);

impl ColorFrequency {
    fn increment(&mut self, color: &Color) {
        if let Some(entry) = self.0.iter_mut().find(|(c, _)| c == color) {
            entry.1 += 1;
        } else {
            self.0.push((color.clone(), 1));
        }
    }
}

#[derive(Clone, Default)]
struct ActiveState {
    /// Captured SGR text for native replay. Wasm packed frames read Color RGB,
    /// so these strings stay native-only.
    #[cfg(not(target_arch = "wasm32"))]
    fg_sequence: String, // "" = none, like upstream's active_sequences
    #[cfg(not(target_arch = "wasm32"))]
    bg_sequence: String,
    fg_color: Option<Color>,
    bg_color: Option<Color>,
    bold: bool,
    standard_fg_parameter: Option<i64>,
}

pub struct Preprocessor<'a> {
    pub arena: &'a mut Vec<EffectCharacter>,
    pub next_character_id: &'a mut u32,
    pub input_colors_frequency: &'a mut ColorFrequency,
    pub config: &'a TerminalConfig,
}

impl<'a> Preprocessor<'a> {
    /// Returns rows of character ids (top row first, as parsed).
    pub fn preprocess(&mut self, input_data: &str) -> Result<Vec<Vec<CharId>>, EngineError> {
        let chars: Vec<char> = input_data.chars().collect();
        let mut screen: HashMap<(i64, i64), CharId> = HashMap::new();
        let mut state = ActiveState::default();
        let (mut row, mut column) = (0i64, 0i64);
        let (mut max_row, mut max_column) = (0i64, 0i64);
        let mut i = 0usize;

        while i < chars.len() {
            if chars[i] == '\x1b' {
                let end = match_escape_sequence(&chars, i)
                    .ok_or_else(|| EngineError::UnsupportedAnsiSequence(chars[i].to_string()))?;
                let sequence: String = chars[i..end].iter().collect();
                if sequence.starts_with("\x1b[") {
                    let (params, intermediates, final_byte) = split_csi(&sequence)
                        .ok_or_else(|| EngineError::UnsupportedAnsiSequence(sequence.clone()))?;
                    if final_byte == 'm' {
                        self.apply_sgr_sequence(&sequence, &params, &mut state)?;
                    } else if is_supported_private_mode_sequence(&sequence) {
                        // ignored: cursor show/hide, autowrap on/off
                    } else {
                        let (new_row, new_column) =
                            apply_cursor_sequence(&sequence, &params, &intermediates, final_byte, row, column)?;
                        row = new_row;
                        column = new_column;
                        max_row = max_row.max(row);
                        max_column = max_column.max(column);
                    }
                } else {
                    return Err(EngineError::UnsupportedAnsiSequence(sequence));
                }
                i = end;
            } else if chars[i] == '\n' {
                row += 1;
                column = 0;
                max_row = max_row.max(row);
                i += 1;
            } else if chars[i] == '\r' {
                column = 0;
                i += 1;
            } else {
                let (symbol, count) = if chars[i] == '\t' {
                    (' ', self.config.tab_width - (column % self.config.tab_width))
                } else {
                    (chars[i], 1)
                };
                for _ in 0..count {
                    let id = self.build_character(&symbol.to_string(), &state)?;
                    screen.insert((row, column), id);
                    max_row = max_row.max(row);
                    max_column = max_column.max(column);
                    column += 1;
                }
                i += 1;
            }
        }

        let empty_state = ActiveState::default();
        let mut characters: Vec<Vec<CharId>> = Vec::new();
        for screen_row in 0..=max_row {
            let mut line: Vec<CharId> = Vec::new();
            for screen_column in 0..=max_column {
                let id = match screen.get(&(screen_row, screen_column)) {
                    Some(&id) => id,
                    None => self.build_character(" ", &empty_state)?,
                };
                line.push(id);
            }
            while let Some(&last) = line.last() {
                let ch = &self.arena[last.0 as usize];
                if ch.input_symbol == " "
                    && ch.animation.input_fg_color.is_none()
                    && ch.animation.input_bg_color.is_none()
                {
                    line.pop();
                } else {
                    break;
                }
            }
            characters.push(line);
        }
        while characters.last().is_some_and(|line| line.is_empty()) {
            characters.pop();
        }

        if characters.is_empty() {
            // Faithful: the fallback character carries the END-of-input active state.
            let id = self.build_character(" ", &state)?;
            characters.push(vec![id]);
        }
        Ok(characters)
    }

    /// build_character: allocates an id (even for characters later discarded),
    /// captures active colors, bumps the color frequency at CREATION time (even
    /// if a later cursor write overwrites the cell — see plan.md §5.13).
    fn build_character(&mut self, symbol: &str, state: &ActiveState) -> Result<CharId, EngineError> {
        let mut ch = EffectCharacter::new(*self.next_character_id, symbol, 0, 0);
        *self.next_character_id += 1;
        // fg first, then bg — upstream dict iteration order over active_sequences
        if let Some(color) = &state.fg_color {
            #[cfg(not(target_arch = "wasm32"))]
            {
                ch.input_ansi_fg_sequence = Some(state.fg_sequence.clone());
            }
            self.input_colors_frequency.increment(color);
            ch.animation.input_fg_color = Some(color.clone());
        }
        if let Some(color) = &state.bg_color {
            #[cfg(not(target_arch = "wasm32"))]
            {
                ch.input_ansi_bg_sequence = Some(state.bg_sequence.clone());
            }
            self.input_colors_frequency.increment(color);
            ch.animation.input_bg_color = Some(color.clone());
        }
        ch.animation.input_bold = state.bold;
        ch.animation.no_color = self.config.no_color;
        ch.animation.use_xterm_colors = self.config.xterm_colors;
        ch.animation.existing_color_handling = self.config.existing_color_handling;
        ch.uses_input_preexisting_colors = true;
        if ch.animation.existing_color_handling == ExistingColorHandling::Always {
            let input_symbol = ch.input_symbol.clone();
            ch.animation.set_appearance(&input_symbol, true, None, None);
        }
        let id = CharId(self.arena.len() as u32);
        self.arena.push(ch);
        Ok(id)
    }

    fn apply_sgr_sequence(
        &mut self,
        sequence: &str,
        params_text: &str,
        state: &mut ActiveState,
    ) -> Result<(), EngineError> {
        let mut parameters = parse_csi_parameters(params_text)?;
        if parameters.is_empty() {
            parameters = vec![0];
        }
        let mut idx = 0usize;
        while idx < parameters.len() {
            let parameter = parameters[idx];
            match parameter {
                0 => {
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        state.fg_sequence.clear();
                        state.bg_sequence.clear();
                    }
                    state.fg_color = None;
                    state.bg_color = None;
                    state.bold = false;
                    state.standard_fg_parameter = None;
                }
                1 => {
                    state.bold = true;
                    if let Some(p) = state.standard_fg_parameter {
                        state.fg_color = Some(xterm_color(p - 30 + 8)?);
                    }
                }
                22 => {
                    state.bold = false;
                    if let Some(p) = state.standard_fg_parameter {
                        state.fg_color = Some(xterm_color(p - 30)?);
                    }
                }
                39 => {
                    #[cfg(not(target_arch = "wasm32"))]
                    state.fg_sequence.clear();
                    state.fg_color = None;
                    state.standard_fg_parameter = None;
                }
                49 => {
                    #[cfg(not(target_arch = "wasm32"))]
                    state.bg_sequence.clear();
                    state.bg_color = None;
                }
                30..=37 => {
                    let color = xterm_color(parameter - 30 + if state.bold { 8 } else { 0 })?;
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        state.fg_sequence = format!("\x1b[{parameter}m");
                    }
                    state.fg_color = Some(color);
                    state.standard_fg_parameter = Some(parameter);
                }
                90..=97 => {
                    let color = xterm_color(parameter - 90 + 8)?;
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        state.fg_sequence = format!("\x1b[{parameter}m");
                    }
                    state.fg_color = Some(color);
                    state.standard_fg_parameter = None;
                }
                40..=47 => {
                    let color = xterm_color(parameter - 40)?;
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        state.bg_sequence = format!("\x1b[{parameter}m");
                    }
                    state.bg_color = Some(color);
                }
                100..=107 => {
                    let color = xterm_color(parameter - 100 + 8)?;
                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        state.bg_sequence = format!("\x1b[{parameter}m");
                    }
                    state.bg_color = Some(color);
                }
                38 | 48 => {
                    if idx + 1 >= parameters.len() {
                        return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string()));
                    }
                    let is_fg = parameter == 38;
                    let color_mode = parameters[idx + 1];
                    let color = match color_mode {
                        5 => {
                            if idx + 2 >= parameters.len() {
                                return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string()));
                            }
                            let code = parameters[idx + 2];
                            let color = xterm_color(code)?;
                            idx += 2;
                            #[cfg(not(target_arch = "wasm32"))]
                            {
                                let seq = format!("\x1b[{parameter};5;{code}m");
                                if is_fg {
                                    state.fg_sequence = seq;
                                } else {
                                    state.bg_sequence = seq;
                                }
                            }
                            color
                        }
                        2 => {
                            if idx + 4 >= parameters.len() {
                                return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string()));
                            }
                            let hex: String = (2..5).map(|o| format!("{:02X}", parameters[idx + o])).collect();
                            let color = Color::from_hex(&hex).map_err(EngineError::Other)?;
                            idx += 4;
                            #[cfg(not(target_arch = "wasm32"))]
                            {
                                let (r, g, b) = color.rgb_ints();
                                let seq = format!("\x1b[{parameter};2;{r};{g};{b}m");
                                if is_fg {
                                    state.fg_sequence = seq;
                                } else {
                                    state.bg_sequence = seq;
                                }
                            }
                            color
                        }
                        _ => return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string())),
                    };
                    if is_fg {
                        state.fg_color = Some(color);
                        state.standard_fg_parameter = None;
                    } else {
                        state.bg_color = Some(color);
                    }
                }
                // Faithful: any other SGR parameter value is silently ignored
                // (the upstream loop has no fallback error branch).
                _ => {}
            }
            idx += 1;
        }
        Ok(())
    }
}

fn xterm_color(code: i64) -> Result<Color, EngineError> {
    // Upstream Color(int) raises ValueError outside 0..=255; that error is not
    // an UnsupportedAnsiSequenceError but still aborts the run.
    if (0..=255).contains(&code) {
        Ok(Color::from_xterm(code as u8))
    } else {
        Err(EngineError::Other(format!("invalid xterm color code in input: {code}")))
    }
}

/// parse_csi_parameters: only digits and ';' allowed; empty fields are 0.
fn parse_csi_parameters(parameters: &str) -> Result<Vec<i64>, EngineError> {
    if parameters.chars().any(|c| !c.is_ascii_digit() && c != ';') {
        return Err(EngineError::UnsupportedAnsiSequence(format!("\x1b[{parameters}")));
    }
    if parameters.is_empty() {
        return Ok(vec![]);
    }
    Ok(parameters
        .split(';')
        .map(|p| if p.is_empty() { 0 } else { p.parse().unwrap() })
        .collect())
}

fn default_parameter(parameters: &[i64]) -> i64 {
    match parameters.first() {
        None => 1,
        Some(&p) => p.max(1),
    }
}

fn is_supported_private_mode_sequence(sequence: &str) -> bool {
    matches!(sequence, "\x1b[?25h" | "\x1b[?25l" | "\x1b[?7h" | "\x1b[?7l")
}

fn apply_cursor_sequence(
    sequence: &str,
    params_text: &str,
    intermediates: &str,
    final_byte: char,
    mut row: i64,
    mut column: i64,
) -> Result<(i64, i64), EngineError> {
    if !intermediates.is_empty() {
        return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string()));
    }
    if params_text.starts_with('?') {
        return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string()));
    }
    let parameters = parse_csi_parameters(params_text)?;
    match final_byte {
        'A' => row -= default_parameter(&parameters),
        'B' => row += default_parameter(&parameters),
        'C' => column += default_parameter(&parameters),
        'D' => column -= default_parameter(&parameters),
        'E' => {
            row += default_parameter(&parameters);
            column = 0;
        }
        'F' => {
            row -= default_parameter(&parameters);
            column = 0;
        }
        'G' => column = default_parameter(&parameters) - 1,
        'H' | 'f' => {
            row = default_parameter(&parameters) - 1;
            column = match parameters.get(1) {
                Some(&p) if p != 0 => p - 1,
                _ => 0, // (1) - 1
            };
        }
        _ => return Err(EngineError::UnsupportedAnsiSequence(sequence.to_string())),
    }
    Ok((row.max(0), column.max(0)))
}

/// Emulates upstream's ansi_escape_sequence_pattern.match at a position, with
/// the same alternation order: OSC, CSI, then `\x1b.` (any char except newline).
/// Returns the exclusive end index of the match.
fn match_escape_sequence(chars: &[char], start: usize) -> Option<usize> {
    debug_assert_eq!(chars[start], '\x1b');
    // OSC: \x1b\] [^\x07]* (\x07 | \x1b\\)  — greedy class run, longest match first
    if chars.get(start + 1) == Some(&']') {
        let run_start = start + 2;
        let mut t = run_start;
        while t < chars.len() && chars[t] != '\x07' {
            t += 1;
        }
        if t < chars.len() {
            // class run ends right before \x07: longest match consumes it
            return Some(t + 1);
        }
        // no BEL: backtrack for the rightmost \x1b\\ terminator inside the run
        let mut p = chars.len();
        while p >= run_start + 2 {
            if chars[p - 2] == '\x1b' && chars[p - 1] == '\\' {
                return Some(p);
            }
            p -= 1;
        }
        // fall through to the remaining alternatives, like regex alternation
    }
    // CSI: \x1b\[ [0-?]* [ -/]* [@-~]
    if chars.get(start + 1) == Some(&'[') {
        let mut t = start + 2;
        while t < chars.len() && ('\u{30}'..='\u{3f}').contains(&chars[t]) {
            t += 1;
        }
        while t < chars.len() && ('\u{20}'..='\u{2f}').contains(&chars[t]) {
            t += 1;
        }
        if t < chars.len() && ('\u{40}'..='\u{7e}').contains(&chars[t]) {
            return Some(t + 1);
        }
        // no valid final byte: fall through to \x1b.
    }
    // \x1b. — '.' does not match newline
    match chars.get(start + 1) {
        Some(&c) if c != '\n' => Some(start + 2),
        _ => None,
    }
}

/// splits a full CSI sequence into (params, intermediates, final) like
/// csi_sequence_pattern.fullmatch; None if it isn't a well-formed CSI sequence.
fn split_csi(sequence: &str) -> Option<(String, String, char)> {
    let chars: Vec<char> = sequence.chars().collect();
    if chars.len() < 3 || chars[0] != '\x1b' || chars[1] != '[' {
        return None;
    }
    let mut t = 2;
    let params_start = t;
    while t < chars.len() && ('\u{30}'..='\u{3f}').contains(&chars[t]) {
        t += 1;
    }
    let params: String = chars[params_start..t].iter().collect();
    let inter_start = t;
    while t < chars.len() && ('\u{20}'..='\u{2f}').contains(&chars[t]) {
        t += 1;
    }
    let intermediates: String = chars[inter_start..t].iter().collect();
    if t != chars.len() - 1 {
        return None;
    }
    let final_byte = chars[t];
    if !('\u{40}'..='\u{7e}').contains(&final_byte) {
        return None;
    }
    Some((params, intermediates, final_byte))
}
