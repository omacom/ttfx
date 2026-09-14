#!/usr/bin/env bash
# CLI contract corpus: exit codes and stream routing per plan.md §8
# (0 success; 1 runtime errors — no-input/file errors on STDOUT,
# unsupported-ANSI on STDERR; 2 usage errors).
set -u
cd "$(dirname "$0")/../.."
RUST=./target/release/ttfx
export COLUMNS=80 LINES=24
pass=0; fail=0; failed=()

check() {
  local name="$1" expected_rc="$2"; shift 2
  "$@" > /tmp/claude-cli-out 2>/tmp/claude-cli-err
  local rc=$?
  if [ "$rc" -eq "$expected_rc" ]; then pass=$((pass+1)); else fail=$((fail+1)); failed+=("$name rc=$rc want=$expected_rc"); fi
}

# usage errors -> 2
check unknown-subcommand 2 bash -c "printf x | $RUST nosucheffect"
check unknown-option 2 bash -c "printf x | $RUST --no-such-option wipe"
check bad-value 2 bash -c "printf x | $RUST --frame-rate -- -1 wipe"
check bad-tab-width 2 bash -c "printf x | $RUST --tab-width 0 wipe"
check root-opt-after-subcommand 2 bash -c "printf x | $RUST wipe --no-color"
check include-exclude-conflict 2 bash -c "printf x | $RUST -R --include-effects a --exclude-effects b"
check bad-easing 2 bash -c "printf x | $RUST wipe --wipe-ease not_an_ease"

# runtime errors -> 1
check no-input 1 bash -c "printf '' | $RUST --parity-dump --seed 1 wipe"
check whitespace-input 1 bash -c "printf '  \n  ' | $RUST --parity-dump --seed 1 wipe"
check missing-file 1 bash -c "$RUST -i /nonexistent/file wipe"
check no-effect 1 bash -c "printf x | $RUST"
check bad-ansi-input 1 bash -c "printf 'a\x1b[2Jb' | $RUST --parity-dump --seed 1 wipe"
check bad-utf8-file 1 bash -c "printf '\xff\xfe' > /tmp/claude-bad-utf8; $RUST -i /tmp/claude-bad-utf8 wipe"

# stream routing
printf '' | $RUST --parity-dump --seed 1 wipe > /tmp/claude-cli-out 2>/tmp/claude-cli-err
grep -q "NO INPUT." /tmp/claude-cli-out && pass=$((pass+1)) || { fail=$((fail+1)); failed+=("no-input-on-stdout"); }
$RUST -i /nonexistent/file wipe > /tmp/claude-cli-out 2>/tmp/claude-cli-err
[ -s /tmp/claude-cli-out ] && pass=$((pass+1)) || { fail=$((fail+1)); failed+=("file-error-on-stdout"); }
printf 'a\x1b[2Jb' | $RUST --parity-dump --seed 1 wipe > /tmp/claude-cli-out 2>/tmp/claude-cli-err
grep -qi "unsupported ansi" /tmp/claude-cli-err && pass=$((pass+1)) || { fail=$((fail+1)); failed+=("ansi-error-on-stderr"); }

# success -> 0
check success 0 bash -c "printf 'hi' | $RUST --parity-dump --seed 1 --max-frames 5 wipe"
check success-negative-canvas 0 bash -c "printf 'hi' | $RUST --canvas-width -1 --parity-dump --seed 1 --max-frames 2 wipe"
check success-multi-stops 0 bash -c "printf 'hi' | $RUST --parity-dump --seed 1 --max-frames 2 wipe --final-gradient-stops ff0000 00ff00 0000ff"
check success-palette 0 bash -c "printf 'hi' | $RUST --palette ff0000,00ff00 --parity-dump --seed 1 --max-frames 2 wipe"
check bad-palette 2 bash -c "printf x | $RUST --palette not-a-color wipe"

echo "cli corpus: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then printf 'FAILED: %s\n' "${failed[@]}"; exit 1; fi
