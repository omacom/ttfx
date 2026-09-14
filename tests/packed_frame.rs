use ttfx::engine::terminal::{PackedFrame, Terminal, TerminalConfig};

const SPACE: u32 = b' ' as u32;
const A: u32 = b'A' as u32;
const B: u32 = b'B' as u32;

fn visible_terminal(input: &str, width: i64, height: i64) -> Terminal {
    let mut terminal = Terminal::new(
        input,
        TerminalConfig {
            canvas_width: width,
            canvas_height: height,
            ignore_terminal_dimensions: true,
            ..Default::default()
        },
    )
    .unwrap();
    let ids = terminal.input_characters.clone();
    for id in ids {
        terminal.set_character_visibility(id, true);
    }
    terminal
}

#[test]
fn pack_display_frame_puts_the_top_row_first() {
    let packed = visible_terminal("AB", 2, 1).pack_display_frame();
    assert_eq!(packed.width, 2);
    assert_eq!(packed.height, 1);
    assert_eq!(packed.symbols, vec![A, B]);
    assert_eq!(packed.fg.len(), 2);
    assert_eq!(packed.bg.len(), 2);
    assert_eq!(packed.flags.len(), 2);
}

#[test]
fn pack_display_frame_empty_cells_are_spaces() {
    let packed = visible_terminal("A", 3, 1).pack_display_frame();
    assert_eq!(packed.width, 3);
    assert_eq!(packed.symbols.len(), 3);
    assert!(packed.symbols.contains(&A));
    assert!(packed.symbols.contains(&SPACE));
    let _ = PackedFrame::BOLD;
}

#[test]
fn packed_frame_fill_copies_into_caller_buffers() {
    let packed = visible_terminal("AB", 2, 1).pack_display_frame();
    let mut symbols = [0u32; 4];
    let mut fg = [7u32; 4];
    let mut bg = [8u32; 4];
    let mut flags = [9u8; 4];
    assert_eq!(
        packed.fill(&mut symbols, &mut fg, &mut bg, &mut flags),
        Ok(2)
    );
    assert_eq!(&symbols[..2], packed.symbols.as_slice());
    assert_eq!(&fg[..2], packed.fg.as_slice());
    assert_eq!(&bg[..2], packed.bg.as_slice());
    assert_eq!(&flags[..2], packed.flags.as_slice());
    assert_eq!(symbols[2], 0);
    assert_eq!(fg[2], 7);
    assert_eq!(bg[2], 8);
    assert_eq!(flags[2], 9);
}

#[test]
fn packed_frame_fill_rejects_short_buffers() {
    let packed = visible_terminal("AB", 2, 1).pack_display_frame();
    let mut symbols = [0u32; 1];
    let mut fg = [0u32; 2];
    let mut bg = [0u32; 2];
    let mut flags = [0u8; 2];
    assert_eq!(
        packed.fill(&mut symbols, &mut fg, &mut bg, &mut flags),
        Err("frame buffers are too small")
    );
}
