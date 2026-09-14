//! Engine RNG: xoshiro256++ with Python-`random`-shaped helpers.
//!
//! The helper semantics here are the parity contract: tools/parity/shim.py
//! implements the exact same algorithms in Python and monkeypatches the
//! `random` module with them, so both implementations draw identical
//! sequences given the same seed (plan.md §7). Do not change any helper's
//! algorithm without updating the shim in lockstep.

pub struct Rng {
    s: [u64; 4],
}

/// Browser CSPRNG without the getrandom crate (its unused-target error
/// strings were larger than this import).
#[cfg(target_arch = "wasm32")]
mod wasm_entropy {
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen]
    extern "C" {
        #[wasm_bindgen(js_namespace = crypto, js_name = getRandomValues)]
        fn get_random_values(buf: &js_sys::Uint8Array);
    }

    pub fn fill(buf: &mut [u8]) {
        let array = js_sys::Uint8Array::new_with_length(buf.len() as u32);
        get_random_values(&array);
        array.copy_to(buf);
    }
}

impl Rng {
    pub fn seeded(seed: u64) -> Self {
        // SplitMix64 expansion of the seed into the xoshiro state, the
        // reference-recommended initialization.
        let mut sm = seed;
        let mut next = || {
            sm = sm.wrapping_add(0x9E3779B97F4A7C15);
            let mut z = sm;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
            z ^ (z >> 31)
        };
        Rng { s: [next(), next(), next(), next()] }
    }

    pub fn from_entropy() -> Self {
        let mut buf = [0u8; 8];
        #[cfg(target_arch = "wasm32")]
        {
            wasm_entropy::fill(&mut buf);
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            // /dev/urandom is always present on the Unix targets we support
            // (Linux and macOS).
            use std::io::Read;
            std::fs::File::open("/dev/urandom")
                .and_then(|mut f| f.read_exact(&mut buf))
                .expect("failed to read /dev/urandom");
        }
        Rng::seeded(u64::from_le_bytes(buf))
    }

    /// Core generator: xoshiro256++ next().
    fn next_u64(&mut self) -> u64 {
        let result = self.s[0].wrapping_add(self.s[3]).rotate_left(23).wrapping_add(self.s[0]);
        let t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);
        result
    }

    /// Python random.random() shape: float in [0, 1) with 53 bits of precision.
    pub fn random(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// Uniform integer in [0, n) via Lemire-free simple rejection on bit masks —
    /// deterministic and trivially portable to the Python shim.
    fn randbelow(&mut self, n: u64) -> u64 {
        assert!(n > 0, "randbelow(0)");
        let bits = 64 - (n - 1).leading_zeros();
        loop {
            let r = self.next_u64() >> (64 - bits.max(1));
            if r < n {
                return r;
            }
        }
    }

    /// random.randint(a, b): inclusive both ends.
    pub fn randint(&mut self, a: i64, b: i64) -> i64 {
        assert!(a <= b, "randint range empty: {a}..={b}");
        a + self.randbelow((b - a + 1) as u64) as i64
    }

    /// random.randrange(a, b): half-open.
    pub fn randrange(&mut self, a: i64, b: i64) -> i64 {
        assert!(a < b, "randrange range empty: {a}..{b}");
        a + self.randbelow((b - a) as u64) as i64
    }

    /// random.choice(seq): seq[randbelow(len)].
    pub fn choice<'a, T>(&mut self, seq: &'a [T]) -> &'a T {
        assert!(!seq.is_empty(), "choice on empty sequence");
        &seq[self.randbelow(seq.len() as u64) as usize]
    }

    /// random.choice by index, for callers that need an owned element.
    pub fn choice_index(&mut self, len: usize) -> usize {
        assert!(len > 0, "choice on empty sequence");
        self.randbelow(len as u64) as usize
    }

    /// random.uniform(a, b): a + (b-a) * random().
    pub fn uniform(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.random()
    }

    /// random.shuffle: Fisher-Yates from the top, exactly CPython's loop
    /// (for i in reversed(range(1, len(x))): j = randbelow(i+1); swap).
    pub fn shuffle<T>(&mut self, seq: &mut [T]) {
        for i in (1..seq.len()).rev() {
            let j = self.randbelow((i + 1) as u64) as usize;
            seq.swap(i, j);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_for_seed() {
        let mut a = Rng::seeded(42);
        let mut b = Rng::seeded(42);
        for _ in 0..100 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn ranges_respected() {
        let mut r = Rng::seeded(7);
        for _ in 0..1000 {
            let v = r.randint(-3, 3);
            assert!((-3..=3).contains(&v));
            let u = r.uniform(1.0, 2.0);
            assert!((1.0..2.0).contains(&u) || u == 2.0);
            assert!(r.random() < 1.0);
        }
    }
}
