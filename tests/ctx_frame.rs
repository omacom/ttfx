use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::terminal::TerminalConfig;
use ttfx::utils::rng::Rng;

fn visible_ctx(input: &str) -> EngineCtx {
    let config = TerminalConfig {
        canvas_width: 3,
        canvas_height: 1,
        ignore_terminal_dimensions: true,
        frame_rate: 0,
        ..Default::default()
    };
    let mut ctx = EngineCtx::new(input, config, Rng::seeded(0), Clock::virtual_with_frame_rate(60))
        .unwrap();
    let ids = ctx.terminal.input_characters.clone();
    for id in ids {
        ctx.terminal.set_character_visibility(id, true);
    }
    ctx
}

#[test]
fn frame_emits_ansi_for_the_cli() {
    let mut ctx = visible_ctx("A");
    let out = ctx.frame();
    assert!(
        out.contains('A'),
        "cli frames should still format ANSI, got {out:?}"
    );
}

#[test]
fn frame_advances_virtual_clock() {
    let mut ctx = visible_ctx("A");
    let before = ctx.clock.now_monotonic();
    let _ = ctx.frame();
    assert!(ctx.clock.now_monotonic() > before);
}
