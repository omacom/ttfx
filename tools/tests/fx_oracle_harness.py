"""Exercise oracle failure handling with tiny fixtures, without building ttfx."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class OracleHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "tools/fx"
        self.effects = self.root / "src/fx/effects"
        self.commands = self.root / "commands"
        for directory in (self.scripts, self.effects, self.commands):
            directory.mkdir(parents=True)
        for name in ("oracle-simd.sh", "qemu-oracle.sh"):
            shutil.copy2(ROOT / "tools/fx" / name, self.scripts / name)
        for name in ("first", "second", "mod"):
            (self.effects / f"{name}.rs").touch()
        self.env = {**os.environ, "JOBS": "1", "ORACLE_TMP": str(self.root / "scratch"),
                    "ORACLE_SHARD": "1/1",
                    "BIN": str(self.commands / "ttfx"),
                    "PATH": str(self.commands) + os.pathsep + os.environ["PATH"]}
        self.write(self.commands / "qemu-x86_64", 'shift 2\nexec "$@"')
        self.write(self.commands / "ttfx", 'printf "frame\\n"')

    def write(self, path, body):
        path.write_text("#!/usr/bin/env bash\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, name, *args, success):
        result = subprocess.run(["bash", str(self.scripts / name), *args],
                                env=self.env, text=True, capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def test_native_creates_scratch_and_selects_each_kernel(self):
        self.env.update(TTFX_FX="0", TTFX_NO_AVX512="1", TTFX_NO_AVX2="1")
        self.env["CALLS"] = str(self.root / "calls")
        self.write(self.scripts / "oracle.sh", '''
[ -z "${TTFX_FX+x}" ] || exit 9
printf '%s:%s:%s\n' "$1" "${TTFX_NO_AVX512:-0}" "${TTFX_NO_AVX2:-0}" >> "$CALLS"
echo "oracle $1: 1 passed, 0 failed"
''')
        self.run_script("oracle-simd.sh", "quick", success=True)
        self.assertEqual(set((self.root / "calls").read_text().splitlines()),
                         {f"{effect}:{flags}" for effect in ("first", "second")
                          for flags in ("0:0", "1:0", "1:1")})

    def test_native_rejects_missing_effect_summary(self):
        self.write(self.scripts / "oracle.sh", '''
if [ "$1" = first ]; then echo "oracle $1: 1 passed, 0 failed"; fi
''')
        self.run_script("oracle-simd.sh", success=False)

    def test_native_can_select_one_kernel_for_ci(self):
        self.write(self.scripts / "oracle.sh", '''
[ "${TTFX_NO_AVX512:-0}" = 1 ] && [ "${TTFX_NO_AVX2:-0}" = 1 ] || exit 9
echo "oracle $1: 1 passed, 0 failed"
''')
        output = self.run_script("oracle-simd.sh", "quick", "no-avx2", success=True)
        self.assertEqual(output.count("effects pass"), 1)

    def test_native_rejects_unknown_kernel(self):
        self.write(self.scripts / "oracle.sh", 'echo "oracle $1: 1 passed, 0 failed"')
        self.run_script("oracle-simd.sh", "quick", "typo", success=False)

    def test_native_shards_partition_effects_without_gaps_or_duplicates(self):
        for name in ("third", "fourth", "fifth"):
            (self.effects / f"{name}.rs").touch()
        self.env["CALLS"] = str(self.root / "calls")
        self.write(self.scripts / "oracle.sh", '''
echo "$1" >> "$CALLS"
echo "oracle $1: 1 passed, 0 failed"
''')
        for count in (3, 4):
            with self.subTest(shards=count):
                (self.root / "calls").write_text("")
                for shard in range(1, count + 1):
                    self.env["ORACLE_SHARD"] = f"{shard}/{count}"
                    output = self.run_script("oracle-simd.sh", "quick", "widest", success=True)
                    self.assertIn(f"shard {shard}/{count}", output)
                self.assertEqual(sorted((self.root / "calls").read_text().splitlines()),
                                 ["fifth", "first", "fourth", "second", "third"])

    def test_native_rejects_invalid_or_empty_shards(self):
        self.write(self.scripts / "oracle.sh", 'echo "oracle $1: 1 passed, 0 failed"')
        for shard in ("0/2", "3/2", "1/0", "1/99", "1/02", "typo"):
            with self.subTest(shard=shard):
                self.env["ORACLE_SHARD"] = shard
                self.run_script("oracle-simd.sh", "quick", "widest", success=False)

    def test_native_shard_rejects_missing_effect_summary(self):
        self.env["ORACLE_SHARD"] = "1/2"
        self.write(self.scripts / "oracle.sh", 'exit 0')
        self.run_script("oracle-simd.sh", "quick", "widest", success=False)

    def test_native_rejects_worker_failure_even_with_passing_summary(self):
        self.write(self.scripts / "oracle.sh", 'echo "oracle $1: 1 passed, 0 failed"\nexit 1')
        self.run_script("oracle-simd.sh", success=False)

    def test_native_rejects_reported_mismatch(self):
        self.write(self.scripts / "oracle.sh", 'echo "oracle $1: 0 passed, 1 failed"')
        self.run_script("oracle-simd.sh", success=False)

    def test_both_wrappers_reject_empty_effect_suite(self):
        for path in self.effects.glob("*.rs"):
            path.unlink()
        self.write(self.scripts / "oracle.sh", 'echo "oracle $1: 1 passed, 0 failed"')
        for name in ("oracle-simd.sh", "qemu-oracle.sh"):
            with self.subTest(script=name):
                self.run_script(name, success=False)

    def test_qemu_uses_reference_and_forced_fx(self):
        self.env.update(TTFX_FX="0", TTFX_NO_AVX512="1", TTFX_NO_AVX2="1")
        self.write(self.commands / "ttfx", '''
[ -z "${TTFX_NO_AVX512+x}${TTFX_NO_AVX2+x}" ] || exit 9
case "$TTFX_FX" in 0|force) printf 'frame\n' ;; *) exit 3 ;; esac
''')
        output = self.run_script("qemu-oracle.sh", "qemu64", success=True)
        self.assertEqual(output.count("10 passed, 0 failed"), 2)

    def test_qemu_rejects_identical_errors(self):
        self.write(self.commands / "ttfx", 'echo "broken executable" >&2\nexit 1')
        self.run_script("qemu-oracle.sh", "qemu64", success=False)

    def test_qemu_rejects_empty_successful_output(self):
        self.write(self.commands / "ttfx", 'exit 0')
        self.run_script("qemu-oracle.sh", "qemu64", success=False)

    def test_qemu_rejects_output_mismatch(self):
        self.write(self.commands / "ttfx", 'echo "$TTFX_FX"')
        self.run_script("qemu-oracle.sh", "qemu64", success=False)

    def test_qemu_rejects_worker_failure_without_results(self):
        self.write(self.commands / "xargs", 'exit 1')
        self.run_script("qemu-oracle.sh", "qemu64", success=False)

    def test_qemu_rejects_missing_binary(self):
        self.env["BIN"] = str(self.root / "missing-binary")
        self.run_script("qemu-oracle.sh", "qemu64", success=False)


if __name__ == "__main__":
    unittest.main()
