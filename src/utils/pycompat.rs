//! Helpers reproducing Python semantics where they differ from Rust defaults.
//! Every call site that transcribes a Python `round()` or `//` must go through
//! these — see plan.md §5.

/// Python's built-in `round()`: banker's rounding (half-to-even), returning i64.
/// Rust's `f64::round` is half-away-from-zero, which differs at exact .5 values.
///
/// Floor is taken by truncating and stepping down for negatives rather than
/// via `f64::floor`: on baseline x86_64 (no SSE4.1) `floor` is a libm call on
/// every coordinate interpolation, while the truncating form is a few inline
/// instructions everywhere. Saturating `as i64` only differs from `floor` for
/// values beyond the i64 range, which never reach here.
pub fn round_half_even(x: f64) -> i64 {
    let truncated = x as i64;
    let floor = truncated - ((x < truncated as f64) as i64);
    let diff = x - floor as f64;
    if diff > 0.5 {
        floor + 1
    } else if diff < 0.5 {
        floor
    } else if floor % 2 == 0 {
        // exactly .5 — round to even
        floor
    } else {
        floor + 1
    }
}

/// Python's `//` on integers: floor division. Rust's `/` truncates toward zero
/// and `div_euclid` rounds toward a non-negative remainder — both differ from
/// floor when signs are involved (7 // -2 == -4 in Python).
pub fn floor_div(a: i64, b: i64) -> i64 {
    let q = a / b;
    if a % b != 0 && (a < 0) != (b < 0) {
        q - 1
    } else {
        q
    }
}

/// Python's `%` on integers: result takes the sign of the divisor.
pub fn py_mod(a: i64, b: i64) -> i64 {
    let r = a % b;
    if r != 0 && (r < 0) != (b < 0) {
        r + b
    } else {
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_matches_python() {
        // Golden values from CPython: round(0.5)=0, round(1.5)=2, round(2.5)=2,
        // round(-0.5)=0, round(-1.5)=-2, round(0.4999)=0, round(1.4999)=1
        assert_eq!(round_half_even(0.5), 0);
        assert_eq!(round_half_even(1.5), 2);
        assert_eq!(round_half_even(2.5), 2);
        assert_eq!(round_half_even(3.5), 4);
        assert_eq!(round_half_even(-0.5), 0);
        assert_eq!(round_half_even(-1.5), -2);
        assert_eq!(round_half_even(-2.5), -2);
        assert_eq!(round_half_even(0.4999), 0);
        assert_eq!(round_half_even(1.4999), 1);
        assert_eq!(round_half_even(2.6), 3);
        assert_eq!(round_half_even(-2.6), -3);
        // Values that aren't exactly representable don't hit the .5 branch:
        // round(2.675) == 3 in Python (2.675 is actually 2.67499999...)
        assert_eq!(round_half_even(2.675), 3);
    }

    #[test]
    fn floor_div_matches_python() {
        assert_eq!(floor_div(7, 2), 3);
        assert_eq!(floor_div(-7, 2), -4);
        assert_eq!(floor_div(7, -2), -4);
        assert_eq!(floor_div(-7, -2), 3);
    }
}
