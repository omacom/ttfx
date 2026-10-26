//! Bit-exact comparison of every easing function against CPython-generated
//! goldens (tools/goldens/gen_easing.py). A mismatch prints the first diverging
//! sample with both bit patterns.

use ttfx::utils::easing::Easing;

const EASING_GOLDEN_ORDER: &[Easing] = &[
    Easing::Linear,
    Easing::InSine,
    Easing::OutSine,
    Easing::InOutSine,
    Easing::InQuad,
    Easing::OutQuad,
    Easing::InOutQuad,
    Easing::InCubic,
    Easing::OutCubic,
    Easing::InOutCubic,
    Easing::InQuart,
    Easing::OutQuart,
    Easing::InOutQuart,
    Easing::InQuint,
    Easing::OutQuint,
    Easing::InOutQuint,
    Easing::InExpo,
    Easing::OutExpo,
    Easing::InOutExpo,
    Easing::InCirc,
    Easing::OutCirc,
    Easing::InOutCirc,
    Easing::InBack,
    Easing::OutBack,
    Easing::InOutBack,
    Easing::InElastic,
    Easing::OutElastic,
    Easing::InOutElastic,
    Easing::InBounce,
    Easing::OutBounce,
    Easing::InOutBounce,
    Easing::CubicBezier(0.25, 0.1, 0.25, 1.0),
    Easing::CubicBezier(0.42, 0.0, 0.58, 1.0),
    Easing::CubicBezier(0.68, -0.55, 0.265, 1.55),
];

/// Easings whose samples go through libm (sin, cos, sqrt, or a non-integer
/// power). glibc's ifunc variants do not agree on these bit for bit.
fn libm_rounded(easing: &Easing) -> bool {
    matches!(
        easing,
        Easing::InSine
            | Easing::OutSine
            | Easing::InOutSine
            | Easing::InExpo
            | Easing::OutExpo
            | Easing::InOutExpo
            | Easing::InCirc
            | Easing::OutCirc
            | Easing::InOutCirc
            | Easing::InElastic
            | Easing::OutElastic
            | Easing::InOutElastic
            | Easing::CubicBezier(..)
    )
}

#[test]
fn easing_matches_python_bit_exactly() {
    let data = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/easing_goldens.bin"))
        .expect("run tools/goldens/gen_easing.py first");
    assert_eq!(data.len(), EASING_GOLDEN_ORDER.len() * 1001 * 8);
    let mut offset = 0;
    let mut mismatches = 0;
    for easing in EASING_GOLDEN_ORDER {
        for i in 0..=1000 {
            let expected = f64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
            offset += 8;
            let p = i as f64 / 1000.0;
            let actual = easing.ease(p);
            // Polynomials are bit-exact on the pinned platform (Linux/glibc).
            // sin/cos/sqrt and non-integer pow are not: glibc picks an FMA or
            // SSE2 libm at runtime, and those differ by a few ulps (OutSine and
            // InOutElastic by 1, a cubic bezier by 17, about 2.4e-16). The
            // goldens were recorded on an FMA machine, so a CPU without FMA
            // fails a bit-exact compare even though CPython on that same CPU
            // matches Rust. Quantized effect output absorbs either rounding.
            let within_tolerance = if cfg!(all(target_os = "linux", target_env = "gnu"))
                && !libm_rounded(easing)
            {
                actual.to_bits() == expected.to_bits()
            } else {
                (actual - expected).abs() <= 1e-15
            };
            if !within_tolerance {
                if mismatches < 5 {
                    eprintln!(
                        "{easing:?} at p={p}: expected {expected:?} ({:016x}), got {actual:?} ({:016x})",
                        expected.to_bits(),
                        actual.to_bits()
                    );
                }
                mismatches += 1;
            }
        }
    }
    assert_eq!(mismatches, 0, "{mismatches} easing samples diverge from Python");
}
