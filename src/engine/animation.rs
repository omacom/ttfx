//! CharacterVisual, Frame, Scene, and Animation, ported from engine/animation.py.
//! Scene/Animation stepping that fires events lives on EngineCtx (ctx.rs);
//! everything here is state plus event-free logic.

use std::collections::{HashMap, VecDeque};
use std::rc::Rc;

use crate::utils::ansi::{self, ColorCode};
use crate::utils::easing::Easing;
use crate::utils::graphics::{Color, ColorPair, Gradient};
use crate::utils::hexterm;
use crate::utils::ordered_map::OrderedMap;

/// Handling of preexisting SGR colors in the input (TerminalConfig option).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExistingColorHandling {
    Always,
    Dynamic,
    Ignore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMetric {
    Distance,
    Step,
}

#[inline]
fn resolve_color_code(
    color: Option<&Color>,
    no_color: bool,
    use_xterm_colors: bool,
    reusable: Option<ColorCode>,
) -> Option<ColorCode> {
    let color = color?;
    if no_color {
        return None;
    }
    if use_xterm_colors {
        return Some(ColorCode::Xterm(
            color.xterm_color.unwrap_or_else(|| hexterm::hex_to_xterm(&color.rgb_color)),
        ));
    }
    let hex = match reusable {
        Some(ColorCode::Rgb(mut hex)) => {
            color.rgb_color.as_ref().clone_into(&mut hex);
            hex
        }
        _ => color.rgb_color.as_ref().to_owned(),
    };
    Some(ColorCode::Rgb(hex))
}

thread_local! {
    /// Reused assembly buffer for CharacterVisual::new's SGR string.
    static FORMAT_SCRATCH: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
    /// Live visuals, one per distinct symbol and styling, shared by every
    /// frame that shows them (beams: 227,002 frames, 378 visuals). Weak
    /// references, swept as the table grows, so effects that keep making
    /// new colors do not accumulate dead ones.
    static SHARED_VISUALS: std::cell::RefCell<SharedVisuals> = std::cell::RefCell::new(SharedVisuals {
        table: HashMap::new(),
        sweep_at: SharedVisuals::MIN_SWEEP,
    });
}

struct SharedVisuals {
    table: HashMap<VisualKey, std::rc::Weak<CharacterVisual>>,
    /// Size at which dead entries are dropped; doubles after each sweep.
    sweep_at: usize,
}

impl SharedVisuals {
    const MIN_SWEEP: usize = 1024;

    fn get(&self, symbol: &str, params: &VisualParams) -> Option<Rc<CharacterVisual>> {
        self.table.get(&(symbol, params) as &dyn VisualLookup)?.upgrade()
    }

    fn insert(&mut self, key: VisualKey, visual: &Rc<CharacterVisual>) {
        self.table.insert(key, Rc::downgrade(visual));
        if self.table.len() >= self.sweep_at {
            self.table.retain(|_, weak| weak.strong_count() > 0);
            self.sweep_at = (self.table.len() * 2).max(SharedVisuals::MIN_SWEEP);
        }
    }
}

/// Everything that determines a CharacterVisual, owned, for the share table.
struct VisualKey {
    symbol: Box<str>,
    params: VisualParams,
}

/// The share table is keyed by `dyn VisualLookup`, which the owned key and a
/// borrowed `(&str, &VisualParams)` pair both implement with the same Hash
/// and Eq, so a lookup allocates nothing. Equality is field by field with
/// colors compared by their ColorArg, the equality upstream gives visuals.
trait VisualLookup {
    fn symbol(&self) -> &str;
    fn params(&self) -> &VisualParams;
}

impl VisualLookup for VisualKey {
    fn symbol(&self) -> &str {
        &self.symbol
    }
    fn params(&self) -> &VisualParams {
        &self.params
    }
}

impl VisualLookup for (&str, &VisualParams) {
    fn symbol(&self) -> &str {
        self.0
    }
    fn params(&self) -> &VisualParams {
        self.1
    }
}

impl<'a> std::borrow::Borrow<dyn VisualLookup + 'a> for VisualKey {
    fn borrow(&self) -> &(dyn VisualLookup + 'a) {
        self
    }
}

impl std::hash::Hash for dyn VisualLookup + '_ {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.symbol().hash(state);
        let p = self.params();
        [p.bold, p.dim, p.italic, p.underline, p.blink, p.reverse, p.hidden, p.strike].hash(state);
        p.colors.is_some().hash(state);
        p.colors.as_ref().and_then(|c| c.fg_color).hash(state);
        p.colors.as_ref().and_then(|c| c.bg_color).hash(state);
        p.fg_color_code.hash(state);
        p.bg_color_code.hash(state);
    }
}

impl PartialEq for dyn VisualLookup + '_ {
    fn eq(&self, other: &Self) -> bool {
        let (a, b) = (self.params(), other.params());
        self.symbol() == other.symbol()
            && [a.bold, a.dim, a.italic, a.underline, a.blink, a.reverse, a.hidden, a.strike]
                == [b.bold, b.dim, b.italic, b.underline, b.blink, b.reverse, b.hidden, b.strike]
            && a.colors.is_some() == b.colors.is_some()
            && a.colors.as_ref().and_then(|c| c.fg_color) == b.colors.as_ref().and_then(|c| c.fg_color)
            && a.colors.as_ref().and_then(|c| c.bg_color) == b.colors.as_ref().and_then(|c| c.bg_color)
            && a.fg_color_code == b.fg_color_code
            && a.bg_color_code == b.bg_color_code
    }
}

impl Eq for dyn VisualLookup + '_ {}

impl std::hash::Hash for VisualKey {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        (self as &dyn VisualLookup).hash(state)
    }
}

impl PartialEq for VisualKey {
    fn eq(&self, other: &Self) -> bool {
        (self as &dyn VisualLookup) == (other as &dyn VisualLookup)
    }
}

impl Eq for VisualKey {}

/// Inline capacity for a formatted symbol. A 24-bit foreground and background
/// pair plus a reset is 42 bytes, so all but pathological styling fits.
const INLINE_SYMBOL_CAPACITY: usize = 63;

/// The precomputed ANSI string for one cell, stored inline when it fits.
///
/// The frame writer emits one of these per visible cell — millions of times
/// over a run — and a `str` copy of a couple of dozen bytes is dominated by the
/// memcpy call itself. An inline buffer lets the writer copy a fixed block and
/// then advance by the real length. The common foreground-only
/// case fits in 32 bytes; heavily styled symbols use the full inline buffer.
#[derive(Debug, Clone)]
pub enum FormattedSymbol {
    Inline { bytes: [u8; INLINE_SYMBOL_CAPACITY], len: u8 },
    Heap(Box<str>),
}

impl FormattedSymbol {
    fn new(text: &str) -> Self {
        if text.len() <= INLINE_SYMBOL_CAPACITY {
            let mut bytes = [0u8; INLINE_SYMBOL_CAPACITY];
            bytes[..text.len()].copy_from_slice(text.as_bytes());
            FormattedSymbol::Inline { bytes, len: text.len() as u8 }
        } else {
            FormattedSymbol::Heap(text.into())
        }
    }

    #[inline]
    pub fn as_str(&self) -> &str {
        match self {
            FormattedSymbol::Inline { bytes, len } => {
                // SAFETY: built from a &str prefix, so the range is valid UTF-8.
                unsafe { std::str::from_utf8_unchecked(&bytes[..*len as usize]) }
            }
            FormattedSymbol::Heap(text) => text,
        }
    }

    /// Append a fixed-size block, then discard its unused padding.
    #[inline]
    pub fn append_to(&self, out: &mut Vec<u8>) {
        match self {
            FormattedSymbol::Inline { bytes, len } => {
                let start = out.len();
                if *len <= 32 {
                    out.extend_from_slice(&bytes[..32]);
                } else {
                    out.extend_from_slice(bytes);
                }
                out.truncate(start + *len as usize);
            }
            FormattedSymbol::Heap(text) => out.extend_from_slice(text.as_bytes()),
        }
    }
}

impl PartialEq for FormattedSymbol {
    fn eq(&self, other: &Self) -> bool {
        self.as_str() == other.as_str()
    }
}

/// animation.CharacterVisual with the formatted ANSI string precomputed.
#[derive(Debug, Clone, PartialEq)]
pub struct CharacterVisual {
    pub symbol: String,
    pub bold: bool,
    pub dim: bool, // stored but never emitted, faithfully
    pub italic: bool,
    pub underline: bool,
    pub blink: bool,
    pub reverse: bool,
    pub hidden: bool,
    pub strike: bool,
    pub colors: Option<ColorPair>,
    pub fg_color_code: Option<ColorCode>,
    pub bg_color_code: Option<ColorCode>,
    pub formatted_symbol: FormattedSymbol,
}

#[derive(Debug, Clone, Default)]
pub struct VisualParams {
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub blink: bool,
    pub reverse: bool,
    pub hidden: bool,
    pub strike: bool,
    pub colors: Option<ColorPair>,
    pub fg_color_code: Option<ColorCode>,
    pub bg_color_code: Option<ColorCode>,
}

impl CharacterVisual {
    pub fn new(symbol: &str, p: VisualParams) -> Self {
        Self::with_symbol(symbol.to_owned(), p)
    }

    fn with_symbol(symbol: String, p: VisualParams) -> Self {
        let mut vis = CharacterVisual {
            symbol,
            bold: p.bold,
            dim: p.dim,
            italic: p.italic,
            underline: p.underline,
            blink: p.blink,
            reverse: p.reverse,
            hidden: p.hidden,
            strike: p.strike,
            colors: p.colors,
            fg_color_code: p.fg_color_code,
            bg_color_code: p.bg_color_code,
            formatted_symbol: FormattedSymbol::Inline { bytes: [0; INLINE_SYMBOL_CAPACITY], len: 0 },
        };
        // Effects rebuild visuals every frame, so the SGR string is assembled in
        // a reused scratch buffer rather than a fresh allocation per visual.
        FORMAT_SCRATCH.with(|scratch| {
            let mut scratch = scratch.borrow_mut();
            scratch.clear();
            vis.format_symbol_into(&mut scratch);
            vis.formatted_symbol = FormattedSymbol::new(&scratch);
        });
        vis
    }

    pub fn plain(symbol: &str) -> Self {
        CharacterVisual::new(symbol, VisualParams::default())
    }

    /// The one shared visual for this symbol and styling, built on first use.
    /// Visuals are immutable once built and compared by content everywhere,
    /// so sharing is not observable; it just stops every frame of every
    /// character owning its own copy.
    pub fn shared(symbol: &str, params: VisualParams) -> Rc<CharacterVisual> {
        SHARED_VISUALS.with(|shared| {
            if let Some(visual) = shared.borrow().get(symbol, &params) {
                return visual;
            }
            let visual = Rc::new(CharacterVisual::new(symbol, params.clone()));
            shared.borrow_mut().insert(VisualKey { symbol: symbol.into(), params }, &visual);
            visual
        })
    }

    /// SGR emission in upstream's fixed order; `dim` intentionally omitted;
    /// bare symbol when nothing applies.
    fn format_symbol_into(&self, fmt: &mut String) {
        if self.bold {
            fmt.push_str(ansi::BOLD);
        }
        if self.italic {
            fmt.push_str(ansi::ITALIC);
        }
        if self.underline {
            fmt.push_str(ansi::UNDERLINE);
        }
        if self.blink {
            fmt.push_str(ansi::BLINK);
        }
        if self.reverse {
            fmt.push_str(ansi::REVERSE);
        }
        if self.hidden {
            fmt.push_str(ansi::HIDDEN);
        }
        if self.strike {
            fmt.push_str(ansi::STRIKETHROUGH);
        }
        if let Some(code) = &self.fg_color_code {
            ansi::fg(code, fmt);
        }
        if let Some(code) = &self.bg_color_code {
            ansi::bg(code, fmt);
        }
        fmt.push_str(&self.symbol);
        if fmt.len() != self.symbol.len() {
            fmt.push_str(ansi::RESET_ALL);
        }
    }
}

/// animation.Frame. Frames live in Scene.all_frames (stable storage);
/// Scene.frames / Scene.played_frames hold indices into it, preserving the
/// upstream object-identity semantics of frame_index_map.
#[derive(Debug, Clone)]
pub struct Frame {
    pub character_visual: Rc<CharacterVisual>,
    pub duration: i64,
    pub ticks_elapsed: i64,
}

/// animation.Scene.
#[derive(Debug, Clone)]
pub struct Scene {
    pub scene_id: String,
    pub is_looping: bool,
    pub sync: Option<SyncMetric>,
    pub ease: Option<Easing>,
    pub no_color: bool,
    pub use_xterm_colors: bool,
    /// Stable frame storage; never reordered.
    pub all_frames: Vec<Frame>,
    /// Remaining frame queue (indices into all_frames).
    pub frames: VecDeque<usize>,
    /// Played frames (indices into all_frames).
    pub played_frames: VecDeque<usize>,
    /// Tick index -> frame index (upstream frame_index_map).
    pub frame_index_map: Vec<usize>,
    pub easing_total_steps: i64,
    pub easing_current_step: i64,
    pub preexisting_colors: Option<ColorPair>,
    pub preexisting_bold: bool,
}

impl Scene {
    pub fn new(
        scene_id: &str,
        is_looping: bool,
        sync: Option<SyncMetric>,
        ease: Option<Easing>,
        no_color: bool,
        use_xterm_colors: bool,
    ) -> Self {
        Scene {
            scene_id: scene_id.to_string(),
            is_looping,
            sync,
            ease,
            no_color,
            use_xterm_colors,
            all_frames: Vec::new(),
            frames: VecDeque::new(),
            played_frames: VecDeque::new(),
            frame_index_map: Vec::new(),
            easing_total_steps: 0,
            easing_current_step: 0,
            preexisting_colors: None,
            preexisting_bold: false,
        }
    }

    /// Scene._get_color_code. Upstream memoizes into a process-global ClassVar
    /// dict; the memo is value-transparent so we just recompute.
    fn get_color_code(&self, color: Option<&Color>) -> Option<ColorCode> {
        resolve_color_code(color, self.no_color, self.use_xterm_colors, None)
    }

    /// Scene.add_frame with the preexisting-color/bold overrides.
    pub fn add_frame(&mut self, symbol: &str, duration: i64, mut params: VisualParams) -> Result<(), String> {
        if let Some(pre) = &self.preexisting_colors {
            params.colors = Some(pre.clone());
        }
        if self.preexisting_bold {
            params.bold = true;
        }
        if let Some(colors) = &params.colors {
            params.fg_color_code = self.get_color_code(colors.fg_color.as_ref());
            params.bg_color_code = self.get_color_code(colors.bg_color.as_ref());
        } else {
            params.fg_color_code = None;
            params.bg_color_code = None;
        }
        if duration < 1 {
            return Err(format!("Frame duration must be at least 1. Received: {duration}"));
        }
        let visual = CharacterVisual::shared(symbol, params);
        let frame_index = self.all_frames.len();
        self.all_frames.push(Frame { character_visual: visual, duration, ticks_elapsed: 0 });
        self.frames.push_back(frame_index);
        for _ in 0..duration {
            self.frame_index_map.push(frame_index);
            self.easing_total_steps += 1;
        }
        Ok(())
    }

    /// Scene.activate: first frame's visual, error when empty.
    pub fn activate(&self) -> Result<Rc<CharacterVisual>, String> {
        match self.frames.front() {
            Some(&idx) => Ok(self.all_frames[idx].character_visual.clone()),
            None => Err(format!("Scene {} has no frames.", self.scene_id)),
        }
    }

    /// Scene.get_next_visual: tick the head frame, retiring it (and looping)
    /// exactly as upstream.
    pub fn get_next_visual(&mut self) -> Rc<CharacterVisual> {
        let head = self.frames[0];
        let next_visual = self.all_frames[head].character_visual.clone();
        self.all_frames[head].ticks_elapsed += 1;
        if self.all_frames[head].ticks_elapsed == self.all_frames[head].duration {
            self.all_frames[head].ticks_elapsed = 0;
            self.played_frames.push_back(self.frames.pop_front().unwrap());
            if self.is_looping && self.frames.is_empty() {
                self.frames.append(&mut self.played_frames);
            }
        }
        next_visual
    }

    /// Scene.apply_gradient_to_symbols with the exact cyclic_distribution
    /// generator semantics (repeat factor + overflow-remainder rule).
    pub fn apply_gradient_to_symbols(
        &mut self,
        symbols: &[String],
        duration: i64,
        fg_gradient: Option<&Gradient>,
        bg_gradient: Option<&Gradient>,
    ) -> Result<(), String> {
        fn cyclic_distribution<'a, T, R>(
            larger: &'a [T],
            smaller: &'a [R],
        ) -> impl Iterator<Item = (&'a T, &'a R)> {
            let repeat_factor = larger.len() / smaller.len();
            let mut overflow_count = larger.len() % smaller.len();
            let mut overflow_used = false;
            let mut smaller_index = 0usize;
            let mut current_repeat_factor = 0usize;
            larger.iter().map(move |element| {
                if current_repeat_factor >= repeat_factor {
                    if overflow_count > 0 {
                        if overflow_used {
                            smaller_index += 1;
                            current_repeat_factor = 0;
                            overflow_used = false;
                        } else {
                            overflow_used = true;
                            overflow_count -= 1;
                        }
                    } else {
                        smaller_index += 1;
                        current_repeat_factor = 0;
                    }
                }
                current_repeat_factor += 1;
                (element, &smaller[smaller_index])
            })
        }

        let fg_has = fg_gradient.is_some_and(|g| !g.spectrum.is_empty());
        let bg_has = bg_gradient.is_some_and(|g| !g.spectrum.is_empty());
        if fg_gradient.is_none() && bg_gradient.is_none() {
            return Err("Foreground and background gradient are None. At least one gradient must be provided.".into());
        }
        if !fg_has && !bg_has {
            return Err(
                "Foreground and background gradient are empty. At least one gradient must have at least one color."
                    .into(),
            );
        }
        for symbol in symbols {
            if symbol.chars().count() > 1 {
                return Err(format!("Symbol must be a string with a length of 1. Received: `{symbol}`."));
            }
        }
        let color_pairs: Vec<ColorPair> = if fg_has && bg_has {
            let fg = &fg_gradient.unwrap().spectrum;
            let bg = &bg_gradient.unwrap().spectrum;
            if fg.len() >= bg.len() {
                cyclic_distribution(fg, bg)
                    .map(|(f, b)| ColorPair::new(Some(*f), Some(*b)))
                    .collect()
            } else {
                cyclic_distribution(bg, fg)
                    .map(|(b, f)| ColorPair::new(Some(*f), Some(*b)))
                    .collect()
            }
        } else if fg_has {
            fg_gradient.unwrap().spectrum.iter().map(|c| ColorPair::new(Some(c.clone()), None)).collect()
        } else {
            bg_gradient.unwrap().spectrum.iter().map(|c| ColorPair::new(None, Some(c.clone()))).collect()
        };

        // Every frame of the scene is known up front; size the stores once
        // instead of letting them double their way up.
        let frame_count = symbols.len().max(color_pairs.len());
        self.all_frames.reserve_exact(frame_count);
        self.frames.reserve_exact(frame_count);
        self.frame_index_map.reserve_exact(frame_count * duration.max(0) as usize);

        if symbols.len() >= color_pairs.len() {
            for (symbol, colors) in cyclic_distribution(symbols, &color_pairs) {
                self.add_frame(symbol, duration, VisualParams { colors: Some(*colors), ..Default::default() })?;
            }
        } else {
            for (colors, symbol) in cyclic_distribution(&color_pairs, symbols) {
                self.add_frame(symbol, duration, VisualParams { colors: Some(*colors), ..Default::default() })?;
            }
        }
        Ok(())
    }

    /// Scene.reset_scene: restore played + remaining frames in original order
    /// (played first), zero tick counters and the easing step.
    pub fn reset_scene(&mut self) {
        // Remaining frames get ticks_elapsed zeroed as they move to played;
        // already-played frames were zeroed when they retired.
        for idx in self.frames.drain(..) {
            self.all_frames[idx].ticks_elapsed = 0;
            self.played_frames.push_back(idx);
        }
        self.frames.extend(self.played_frames.drain(..));
        self.easing_current_step = 0;
    }
}

/// engine/animation.py Animation: per-character animation state.
#[derive(Debug, Clone)]
pub struct Animation {
    pub scenes: OrderedMap<Scene>,
    pub active_scene: Option<Rc<str>>,
    pub use_xterm_colors: bool,
    pub no_color: bool,
    pub existing_color_handling: ExistingColorHandling,
    pub input_fg_color: Option<Color>,
    pub input_bg_color: Option<Color>,
    pub input_bold: bool,
    pub active_scene_current_step: i64,
    pub current_character_visual: Rc<CharacterVisual>,
}

impl Animation {
    pub fn new(input_symbol: &str) -> Self {
        Animation {
            scenes: OrderedMap::new(),
            active_scene: None,
            use_xterm_colors: false,
            no_color: false,
            existing_color_handling: ExistingColorHandling::Ignore,
            input_fg_color: None,
            input_bg_color: None,
            input_bold: false,
            active_scene_current_step: 0,
            current_character_visual: CharacterVisual::shared(input_symbol, VisualParams::default()),
        }
    }

    /// Animation._get_color_code (identical logic to Scene's; the upstream
    /// per-instance memo is value-transparent and omitted).
    pub fn get_color_code(&mut self, color: Option<&Color>) -> Option<ColorCode> {
        resolve_color_code(color, self.no_color, self.use_xterm_colors, None)
    }

    /// Animation.new_scene: auto-ids are stringified integers probing upward;
    /// duplicate explicit ids silently overwrite (faithful).
    pub fn new_scene(
        &mut self,
        is_looping: bool,
        sync: Option<SyncMetric>,
        ease: Option<Easing>,
        scene_id: &str,
        uses_input_preexisting_colors: bool,
    ) -> String {
        let scene_id = if scene_id.is_empty() {
            let mut current_id = self.scenes.len();
            loop {
                let candidate = current_id.to_string();
                if !self.scenes.contains_key(&candidate) {
                    break candidate;
                }
                current_id += 1;
            }
        } else {
            scene_id.to_string()
        };
        let (preexisting_colors, preexisting_bold) =
            if self.existing_color_handling == ExistingColorHandling::Always && uses_input_preexisting_colors {
                (
                    Some(ColorPair::new(self.input_fg_color.clone(), self.input_bg_color.clone())),
                    self.input_bold,
                )
            } else {
                (None, false)
            };
        let mut scene = Scene::new(&scene_id, is_looping, sync, ease, self.no_color, self.use_xterm_colors);
        scene.preexisting_colors = preexisting_colors;
        scene.preexisting_bold = preexisting_bold;
        self.scenes.insert(scene_id.clone(), scene);
        scene_id
    }

    /// Animation.active_scene_is_complete: no scene, no remaining frames, or looping.
    pub fn active_scene_is_complete(&self) -> bool {
        match &self.active_scene {
            None => true,
            Some(id) => {
                let scene = self.scenes.get(id).expect("active scene must exist");
                scene.frames.is_empty() || scene.is_looping
            }
        }
    }

    /// Animation.set_appearance.
    pub fn set_appearance(
        &mut self,
        input_symbol: &str,
        uses_input_preexisting_colors: bool,
        symbol: Option<&str>,
        colors: Option<ColorPair>,
    ) {
        let symbol = symbol.unwrap_or(input_symbol);
        let mut colors = colors.unwrap_or_default();
        let mut bold = false;
        if self.existing_color_handling == ExistingColorHandling::Always && uses_input_preexisting_colors {
            colors = ColorPair::new(self.input_fg_color.clone(), self.input_bg_color.clone());
            bold = self.input_bold;
        }
        // Appearance-driven effects usually own their visual outright. Reuse
        // its allocation and strings; a scene or caller retaining a strong or
        // weak reference still receives an independent replacement.
        let mut reusable = Rc::get_mut(&mut self.current_character_visual);
        let (symbol_buffer, fg_code, bg_code) = match reusable.as_deref_mut() {
            Some(visual) => {
                let mut buffer = std::mem::take(&mut visual.symbol);
                symbol.clone_into(&mut buffer);
                (buffer, visual.fg_color_code.take(), visual.bg_color_code.take())
            }
            None => (symbol.to_owned(), None, None),
        };
        let fg_code = resolve_color_code(colors.fg_color.as_ref(), self.no_color, self.use_xterm_colors, fg_code);
        let bg_code = resolve_color_code(colors.bg_color.as_ref(), self.no_color, self.use_xterm_colors, bg_code);
        let visual = CharacterVisual::with_symbol(
            symbol_buffer,
            VisualParams {
                bold,
                colors: Some(colors),
                fg_color_code: fg_code,
                bg_color_code: bg_code,
                ..Default::default()
            },
        );
        match reusable {
            Some(current) => *current = visual,
            None => self.current_character_visual = Rc::new(visual),
        }
    }

    /// Animation.adjust_color_brightness: hand-rolled RGB->HSL->RGB with
    /// round() (banker's) at the end — unlike shift_color_towards's truncation.
    pub fn adjust_color_brightness(color: &Color, brightness: f64) -> Color {
        use crate::utils::pycompat::round_half_even;

        fn hue_to_rgb(lightness_scaled: f64, color_intensity: f64, mut hue_value: f64) -> f64 {
            if hue_value < 0.0 {
                hue_value += 1.0;
            }
            if hue_value > 1.0 {
                hue_value -= 1.0;
            }
            if hue_value < 1.0 / 6.0 {
                return lightness_scaled + (color_intensity - lightness_scaled) * 6.0 * hue_value;
            }
            if hue_value < 1.0 / 2.0 {
                return color_intensity;
            }
            if hue_value < 2.0 / 3.0 {
                return lightness_scaled + (color_intensity - lightness_scaled) * (2.0 / 3.0 - hue_value) * 6.0;
            }
            lightness_scaled
        }

        let (r, g, b) = color.rgb_ints();
        let normalized_red = r as f64 / 255.0;
        let normalized_green = g as f64 / 255.0;
        let normalized_blue = b as f64 / 255.0;

        let max_val = normalized_red.max(normalized_green).max(normalized_blue);
        let min_val = normalized_red.min(normalized_green).min(normalized_blue);
        let mut lightness = (max_val + min_val) / 2.0;

        let lightness_threshold = 0.5;
        let (hue_value, saturation) = if max_val == min_val {
            (0.0, 0.0)
        } else {
            let diff = max_val - min_val;
            let saturation = if lightness > lightness_threshold {
                diff / (2.0 - max_val - min_val)
            } else {
                diff / (max_val + min_val)
            };
            let mut hue_value = if max_val == normalized_red {
                (normalized_green - normalized_blue) / diff + if normalized_green < normalized_blue { 6.0 } else { 0.0 }
            } else if max_val == normalized_green {
                (normalized_blue - normalized_red) / diff + 2.0
            } else {
                (normalized_red - normalized_green) / diff + 4.0
            };
            hue_value /= 6.0;
            (hue_value, saturation)
        };

        lightness = (lightness * brightness).min(1.0).max(0.0);

        let (red, green, blue) = if saturation == 0.0 {
            (lightness, lightness, lightness)
        } else {
            let color_intensity = if lightness < lightness_threshold {
                lightness * (1.0 + saturation)
            } else {
                lightness + saturation - lightness * saturation
            };
            let lightness_scaled = 2.0 * lightness - color_intensity;
            (
                hue_to_rgb(lightness_scaled, color_intensity, hue_value + 1.0 / 3.0),
                hue_to_rgb(lightness_scaled, color_intensity, hue_value),
                hue_to_rgb(lightness_scaled, color_intensity, hue_value - 1.0 / 3.0),
            )
        };

        Color::from_rgb(
            round_half_even(red * 255.0) as u8,
            round_half_even(green * 255.0) as u8,
            round_half_even(blue * 255.0) as u8,
        )
    }
}

#[cfg(test)]
mod shared_visual_tests {
    use super::*;

    fn params(hex: &str) -> VisualParams {
        let color = Color::from_hex(hex).unwrap();
        VisualParams {
            colors: Some(ColorPair::new(Some(color), None)),
            fg_color_code: Some(ColorCode::Rgb(hex.to_string())),
            ..Default::default()
        }
    }

    #[test]
    fn equal_symbol_and_styling_share_one_visual() {
        let a = CharacterVisual::shared("█", params("ff0000"));
        let b = CharacterVisual::shared("█", params("ff0000"));
        assert!(Rc::ptr_eq(&a, &b));
        assert_eq!(a.formatted_symbol.as_str(), "\x1b[38;2;255;0;0m█\x1b[0m");
    }

    #[test]
    fn different_symbol_or_styling_do_not_share() {
        let base = CharacterVisual::shared("█", params("00ff00"));
        assert!(!Rc::ptr_eq(&base, &CharacterVisual::shared("▀", params("00ff00"))));
        assert!(!Rc::ptr_eq(&base, &CharacterVisual::shared("█", params("00ff01"))));
        let mut bold = params("00ff00");
        bold.bold = true;
        assert!(!Rc::ptr_eq(&base, &CharacterVisual::shared("█", bold)));
        // dim is never emitted, but it is still part of the visual
        let mut dim = params("00ff00");
        dim.dim = true;
        assert!(!Rc::ptr_eq(&base, &CharacterVisual::shared("█", dim)));
    }

    #[test]
    fn dropped_visuals_are_swept_out_of_the_table() {
        let before = SHARED_VISUALS.with(|s| s.borrow().table.len());
        for i in 0..(SharedVisuals::MIN_SWEEP * 4) {
            drop(CharacterVisual::shared(&format!("{i}"), VisualParams::default()));
        }
        let after = SHARED_VISUALS.with(|s| s.borrow().table.len());
        assert!(after < before + SharedVisuals::MIN_SWEEP * 2, "table kept growing: {before} -> {after}");
    }

    #[test]
    fn scene_frames_share_visuals_across_scenes() {
        let mut a = Scene::new("a", false, None, None, false, false);
        let mut b = Scene::new("b", false, None, None, false, false);
        a.add_frame("x", 1, params("123456")).unwrap();
        b.add_frame("x", 1, params("123456")).unwrap();
        assert!(Rc::ptr_eq(&a.all_frames[0].character_visual, &b.all_frames[0].character_visual));
    }
}
