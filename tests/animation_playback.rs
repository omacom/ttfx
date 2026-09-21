use std::rc::Rc;

use ttfx::engine::animation::{Animation, CharacterVisual, ExistingColorHandling, Scene, VisualParams};
use ttfx::utils::ansi::ColorCode;
use ttfx::utils::graphics::{Color, ColorPair, Gradient};

fn scene(looping: bool) -> Scene {
    Scene::new("test", looping, None, None, false, false)
}

#[test]
fn unequal_gradients_and_symbols_follow_python_distribution() {
    // Obtained from the pinned Python reference's apply_gradient_to_symbols.
    type GradientCase = (u8, u8, u8, &'static [(char, u8, u8)]);
    let cases: &[GradientCase] = &[
        (5, 2, 3, &[('A', 1, 20), ('A', 2, 20), ('B', 3, 20), ('B', 4, 21), ('C', 5, 21)]),
        (2, 5, 7, &[('A', 1, 20), ('B', 1, 20), ('C', 1, 21), ('D', 1, 21), ('E', 1, 22), ('F', 2, 23), ('G', 2, 24)]),
        (1, 1, 5, &[('A', 1, 20), ('B', 1, 20), ('C', 1, 20), ('D', 1, 20), ('E', 1, 20)]),
        (7, 3, 2, &[('A', 1, 20), ('A', 2, 20), ('A', 3, 20), ('A', 4, 21), ('B', 5, 21), ('B', 6, 22), ('B', 7, 22)]),
    ];
    for &(fg_count, bg_count, symbol_count, expected) in cases {
        let fg = Gradient { spectrum: (1..=fg_count).map(Color::from_xterm).collect() };
        let bg = Gradient { spectrum: (20..20 + bg_count).map(Color::from_xterm).collect() };
        let symbols: Vec<String> = (b'A'..b'A' + symbol_count).map(|c| (c as char).to_string()).collect();
        let mut scene = scene(false);
        scene.apply_gradient_to_symbols(&symbols, 2, Some(&fg), Some(&bg)).unwrap();
        assert_eq!(scene.all_frames.len(), expected.len());
        assert_eq!(scene.easing_total_steps, expected.len() as i64 * 2);
        for (frame, &(symbol, foreground, background)) in scene.all_frames.iter().zip(expected) {
            let visual = &frame.character_visual;
            let colors = visual.colors.unwrap();
            assert_eq!(visual.symbol, symbol.to_string());
            assert_eq!(colors.fg_color.unwrap(), Color::from_xterm(foreground));
            assert_eq!(colors.bg_color.unwrap(), Color::from_xterm(background));
        }
        for &(symbol, _, _) in expected {
            for _ in 0..2 {
                assert_eq!(scene.get_next_visual().symbol, symbol.to_string());
            }
        }
        assert!(scene.frames.is_empty());
    }
}

#[test]
fn reset_restores_partially_played_frames_and_looping_order() {
    for looping in [false, true] {
        let mut scene = scene(looping);
        for (symbol, duration) in [("A", 2), ("B", 3), ("C", 1)] {
            scene.add_frame(symbol, duration, VisualParams::default()).unwrap();
        }
        for symbol in ["A", "A", "B"] {
            assert_eq!(scene.get_next_visual().symbol, symbol);
        }
        scene.reset_scene();
        assert!(scene.all_frames.iter().all(|frame| frame.ticks_elapsed == 0));
        assert!(scene.played_frames.is_empty());
        for symbol in ["A", "A", "B", "B", "B", "C"] {
            assert_eq!(scene.get_next_visual().symbol, symbol);
        }
        if looping {
            assert_eq!(scene.get_next_visual().symbol, "A");
        } else {
            assert!(scene.frames.is_empty());
        }
    }
}

#[test]
fn appearance_changes_preserve_shared_visuals_and_weak_observers() {
    let mut animation = Animation::new("original");
    let original = Rc::clone(&animation.current_character_visual);
    animation.set_appearance("input", false, Some("λ"), None);
    assert_eq!(original.formatted_symbol.as_str(), "original");
    assert_eq!(animation.current_character_visual.formatted_symbol.as_str(), "λ");

    let observer = Rc::downgrade(&animation.current_character_visual);
    animation.set_appearance("input", false, Some("replacement"), None);
    assert!(observer.upgrade().is_none());
    assert_eq!(animation.current_character_visual.formatted_symbol.as_str(), "replacement");
}

#[test]
fn reused_appearances_reset_styles_and_follow_color_mode_changes() {
    let mut animation = Animation::new("input");
    animation.current_character_visual = Rc::new(CharacterVisual::new(
        "styled",
        VisualParams {
            bold: true,
            dim: true,
            italic: true,
            underline: true,
            blink: true,
            reverse: true,
            hidden: true,
            strike: true,
            ..Default::default()
        },
    ));
    let colors = ColorPair::new(Some(Color::from_hex("Fa0088").unwrap()), Some(Color::from_hex("0A0B0C").unwrap()));
    animation.set_appearance("input", false, Some("字"), Some(colors));
    let expected = CharacterVisual::new(
        "字",
        VisualParams {
            colors: Some(colors),
            fg_color_code: Some(ColorCode::Rgb("Fa0088".into())),
            bg_color_code: Some(ColorCode::Rgb("0A0B0C".into())),
            ..Default::default()
        },
    );
    assert_eq!(*animation.current_character_visual, expected);
    assert_eq!(
        animation.current_character_visual.formatted_symbol.as_str(),
        "\x1b[38;2;250;0;136m\x1b[48;2;10;11;12m字\x1b[0m"
    );

    animation.use_xterm_colors = true;
    animation.set_appearance("input", false, Some("x"), Some(ColorPair::new(Some(Color::from_xterm(1)), None)));
    assert_eq!(animation.current_character_visual.formatted_symbol.as_str(), "\x1b[38;5;1mx\x1b[0m");
    assert_eq!(animation.current_character_visual.bg_color_code, None);

    animation.no_color = true;
    animation.set_appearance("input", false, Some("z"), Some(colors));
    assert_eq!(animation.current_character_visual.formatted_symbol.as_str(), "z");
    assert_eq!(animation.current_character_visual.colors, Some(colors));
    assert_eq!(animation.current_character_visual.fg_color_code, None);

    animation.no_color = false;
    animation.existing_color_handling = ExistingColorHandling::Always;
    animation.input_bold = true;
    animation.input_fg_color = Some(Color::from_xterm(196));
    animation.input_bg_color = Some(Color::from_xterm(7));
    animation.set_appearance("input", true, Some("m"), Some(colors));
    assert_eq!(
        animation.current_character_visual.formatted_symbol.as_str(),
        "\x1b[1m\x1b[38;5;196m\x1b[48;5;7mm\x1b[0m"
    );

    let long_symbol = "🥟".repeat(40);
    animation.set_appearance("input", false, Some(&long_symbol), None);
    assert_eq!(animation.current_character_visual.formatted_symbol.as_str(), long_symbol);
    animation.set_appearance("input", false, None, None);
    assert_eq!(animation.current_character_visual.formatted_symbol.as_str(), "input");
}

#[test]
fn formatted_symbols_append_across_inline_and_heap_boundaries() {
    for length in 0..=96 {
        for suffix in ["", "λ漢💫"] {
            let text = format!("{}{suffix}", "a".repeat(length));
            let visual = CharacterVisual::plain(&text);
            for capacity in [0, 1, 31, 32, 63, 64, 128] {
                for prefix_length in 0..8 {
                    let prefix = "!".repeat(prefix_length);
                    let mut bytes = Vec::with_capacity(capacity);
                    bytes.extend_from_slice(prefix.as_bytes());
                    visual.formatted_symbol.append_to(&mut bytes);
                    visual.formatted_symbol.append_to(&mut bytes);
                    assert_eq!(String::from_utf8(bytes).unwrap(), format!("{prefix}{text}{text}"));
                }
            }
        }
    }
}
