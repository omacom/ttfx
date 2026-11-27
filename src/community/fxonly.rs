//! The original engine has no implementation of the community effects. When
//! the fx engine declines one (TTFX_FX=0), this stands in and reports it.

use crate::engine::character::CharId;
use crate::engine::ctx::{EffectHooks, EngineCtx};
use crate::engine::effect::Effect;
use crate::engine::error::EngineError;
use crate::engine::events::EffectCallback;

pub struct FxOnly(pub &'static str);

impl EffectHooks for FxOnly {
    fn dispatch_callback(&mut self, _: &mut EngineCtx, _: CharId, _: &EffectCallback) {}
}

impl Effect for FxOnly {
    fn build(&mut self, _ctx: &mut EngineCtx) -> Result<(), EngineError> {
        Err(EngineError::Other(format!(
            "{} is a community effect and runs on the fx engine only",
            self.0
        )))
    }
    fn next_frame(&mut self, _ctx: &mut EngineCtx) -> Option<String> {
        None
    }
}
