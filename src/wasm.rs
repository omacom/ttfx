//! Browser bindings: run any effect against a packed cell frame.

use js_sys::{Uint32Array, Uint8Array};
use wasm_bindgen::prelude::*;

use crate::engine::canvas::Anchor;
use crate::engine::ctx::{Clock, EngineCtx};
use crate::engine::effect::Effect;
use crate::engine::terminal::{PackedFrame, TerminalConfig};
use crate::utils::graphics::Color;
use crate::utils::palette::Palette;
use crate::utils::rng::Rng;

#[wasm_bindgen]
pub struct Session {
    effect: Box<dyn Effect>,
    ctx: EngineCtx,
    frame: PackedFrame,
    done: bool,
}

#[wasm_bindgen]
impl Session {
    #[wasm_bindgen(constructor)]
    pub fn new(
        input: &str,
        effect: &str,
        columns: u32,
        rows: u32,
        seed: Option<f64>,
        frame_rate: u32,
        palette: Option<String>,
        background: Option<String>,
        bands: Option<bool>,
    ) -> Result<Session, JsError> {
        if input.trim().is_empty() {
            return Err(JsError::new("NO INPUT."));
        }
        let columns = columns.max(1) as i64;
        let rows = rows.max(1) as i64;
        let frame_rate = frame_rate as i64;
        let rng = match seed {
            Some(s) if s.is_finite() => Rng::seeded(s as u64),
            _ => Rng::from_entropy(),
        };
        let config = TerminalConfig {
            frame_rate,
            canvas_width: 0,
            canvas_height: 0,
            anchor_canvas: Anchor::C,
            anchor_text: Anchor::C,
            reuse_canvas: true,
            no_eol: true,
            no_restore_cursor: true,
            terminal_background_color: match background.as_deref() {
                Some(hex) => Color::from_hex(hex).map_err(|e| JsError::new(&e))?,
                None => Color::from_hex("000000").unwrap(),
            },
            terminal_size: Some((columns, rows)),
            existing_color_handling: if bands.unwrap_or(false) {
                crate::engine::animation::ExistingColorHandling::Always
            } else {
                crate::engine::animation::ExistingColorHandling::Ignore
            },
            ..TerminalConfig::default()
        };
        let clock = Clock::virtual_with_frame_rate(if frame_rate > 0 { frame_rate } else { 60 });
        let mut ctx =
            EngineCtx::new(input, config, rng, clock).map_err(|e| JsError::new(&e.to_string()))?;
        let palette = match palette.as_deref() {
            Some(s) => Some(Palette::from_hex_list(s).map_err(|e| JsError::new(&e))?),
            None => None,
        };
        if bands.unwrap_or(false) {
            let Some(palette) = palette.as_ref() else {
                return Err(JsError::new("--bands requires a palette"));
            };
            crate::utils::bands::apply_field_bands(&mut ctx.terminal, palette);
            ctx.preexisting_colors_present = true;
        }
        let mut effect = build_effect(effect, palette.as_ref())?;
        effect
            .build(&mut ctx)
            .map_err(|e| JsError::new(&e.to_string()))?;
        Ok(Session {
            effect,
            ctx,
            frame: PackedFrame {
                width: 0,
                height: 0,
                symbols: Vec::new(),
                fg: Vec::new(),
                bg: Vec::new(),
                flags: Vec::new(),
            },
            done: false,
        })
    }

    /// Advance one animation frame. Returns false when the effect is finished.
    pub fn step(&mut self) -> bool {
        if self.done {
            return false;
        }
        match self.effect.next_frame(&mut self.ctx) {
            Some(_output) => {
                self.frame = self.ctx.terminal.pack_display_frame();
                true
            }
            None => {
                self.done = true;
                false
            }
        }
    }

    pub fn done(&self) -> bool {
        self.done
    }

    pub fn width(&self) -> u32 {
        self.frame.width as u32
    }

    pub fn height(&self) -> u32 {
        self.frame.height as u32
    }

    /// Copy the current frame into caller-owned typed arrays.
    ///
    /// Each array must be at least `width * height` long. Extra length is left
    /// untouched. Symbols are Unicode scalar values, one per cell.
    pub fn fill(
        &self,
        symbols: &Uint32Array,
        fg: &Uint32Array,
        bg: &Uint32Array,
        flags: &Uint8Array,
    ) -> Result<(), JsError> {
        let n = self.frame.cell_count();
        if (symbols.length() as usize) < n
            || (fg.length() as usize) < n
            || (bg.length() as usize) < n
            || (flags.length() as usize) < n
        {
            return Err(JsError::new("frame buffers are too small"));
        }
        if n == 0 {
            return Ok(());
        }
        if self.frame.symbols.len() != n
            || self.frame.fg.len() != n
            || self.frame.bg.len() != n
            || self.frame.flags.len() != n
        {
            return Err(JsError::new("packed frame is truncated"));
        }
        let end = n as u32;
        symbols.subarray(0, end).copy_from(&self.frame.symbols);
        fg.subarray(0, end).copy_from(&self.frame.fg);
        bg.subarray(0, end).copy_from(&self.frame.bg);
        flags.subarray(0, end).copy_from(&self.frame.flags);
        Ok(())
    }
}

fn build_effect(name: &str, palette: Option<&Palette>) -> Result<Box<dyn Effect>, JsError> {
    crate::effects::build_named_effect_with_palette(name, palette)
        .ok_or_else(|| JsError::new(&format!("unknown effect '{name}'")))
}

/// Which 4-3-4-3-5 band `t` (0 at the top, 1 at the bottom) falls in.
#[wasm_bindgen]
pub fn field_band_index(t: f64) -> u32 {
    crate::utils::bands::field_band_index(t) as u32
}

/// JSON array of `{name, about}` for every registered effect.
#[wasm_bindgen]
pub fn effect_catalog() -> String {
    let mut out = String::from("[");
    for (i, (name, about)) in crate::effects::catalog_entries().iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"name\":");
        json_string(&mut out, name);
        out.push_str(",\"about\":");
        json_string(&mut out, about);
        out.push('}');
    }
    out.push(']');
    out
}

fn json_string(out: &mut String, value: &str) {
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {
                out.push_str("\\u");
                let code = c as u32;
                let hex = format!("{code:04x}");
                out.push_str(&hex);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}
