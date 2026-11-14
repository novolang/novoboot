#!/bin/bash
# orbit/novoboot/tests/dfu_boot.sh: an update sent by dfu-nv over RTT into
# slot B of a board that runs the bootloader, swapped in at the next
# reset, tried, and confirmed or reverted.  The body of the board's
# tests/dfu_boot.sh, which sets the board's facts and sources this file,
# as tests/boot.sh sources board_boot.sh.
#
# The board's script sets:
#
#   SLUG        the board's --target slug
#   CHIP        the probe-rs chip name
#   BENCH_VAR   the name of the variable that selects the board's probe
#   BOARD_DIR   the board package's directory, whose tests/boot_app.nv is
#               the application the updates carry and whose tests/boot.sh
#               is run last
#   EXAMPLE     the dfu-nv device program, orbit/dfu-nv/examples/<name>.nv
#   TIMEOUT     the milliseconds `dfu-nv send` waits for one answer; an
#               erase of a 128 KB sector takes about a second
#
# and may set TRIAL_MS, a trial timeout for the bench's bootloader in
# place of the table's, for a board whose probe takes longer than the
# default's 4 s to attach to an image on trial.
#
# Without a board the script builds: the bootloader, the dfu-nv command,
# the device program and the three images, and checks the images on the
# host with `dfu-nv info`.
#
# With the board's probe named (planning/DFU-AND-FOTA.md, D1):
#
#   1. the device program in slot A, confirmed, the bootloader with it;
#      an update sent by `dfu-nv send` over RTT lands in slot B, is
#      swapped in at the reset, runs on trial, confirms itself, and the
#      probe reads slot A's tried and confirmed words;
#   2. an update cut by a reset of the board after one object, then after
#      two more: the bootloader starts the device program each time, slot
#      A whole; `dfu-nv send` again resumes at the last page that held
#      data and the update completes and runs;
#   3. an update that never confirms and never feeds the watchdog: swapped
#      in, reset by the watchdog, reverted: the device program runs from
#      slot A again and slot B holds the update marked pending and tried;
#   4. the same update with the confirmed word written into its slot B as
#      well, which the swap carries into slot A: after the watchdog's
#      reset the bootloader starts it again under rule 4 and does not
#      revert it.
#
# The script ends by running the board's tests/boot.sh, whose last section
# leaves the board with the bootloader and blink.  Rows 1 to 4 are the
# acceptance rows 1 to 4 of D1; the fifth row is the host suites and
# boot.sh's coverage line.  One probe-rs runs at a time on the board's
# probe: each call waits for any other on the same probe to finish, and
# the script holds the board's bench lock around its flash, reset and RTT
# steps.

set -uo pipefail

NV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$NV/../.." && pwd)"
NOVO="${NOVO:-$REPO/bin/novo}"
DFU="$REPO/orbit/dfu-nv"
APP_SRC="$BOARD_DIR/tests/boot_app.nv"

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1"; }
finish() {
  stop_bridge
  echo "══════════════════════════════════════════"
  echo "  pass=$PASS fail=$FAIL"
  echo "══════════════════════════════════════════"
  [ "$FAIL" = "0" ]
  exit $?
}
stop_bridge() { :; }

echo ""
echo "══════════════════════════════════════════"
echo "  dfu-nv into the bootloader's slot B on the $SLUG"
echo "══════════════════════════════════════════"

[ -x "$NOVO" ] || { echo "ERROR: $NOVO not found; build first" >&2; exit 1; }
for tool in arm-none-eabi-nm python3; do
  command -v "$tool" > /dev/null 2>&1 || { echo "  (skipped: $tool not installed)"; finish; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dfu_boot_XXXXXX")
BRIDGE=""
LOCK_FD=""
[ -n "${DFU_BOOT_KEEP:-}" ] && echo "  (keeping $WORK)" || trap 'stop_bridge; rm -rf "$WORK"' EXIT
export NOVO_CONFIG="$WORK/nokey.toml"
printf '' > "$NOVO_CONFIG"
REPO_ROOT="$REPO"
. "$REPO/tests/lib/novofs_pkg.sh"

# ── 1. the builds ──────────────────────────────────────────────────────────
echo ""
echo "1. the builds"
# The bootloader, from a copy of the package whose `HOLD_MS` waits before
# the jump, so the probe reads its log before the image replaces the RTT
# control block.
mkdir -p "$WORK/boot"
cp -r "$NV/src" "$NV/novo.toml" "$WORK/boot/"
sed -i 's/^let HOLD_MS = .*/let HOLD_MS = 4000/' "$WORK/boot/src/main.nv"
if [ -n "${TRIAL_MS:-}" ]; then
  { printf '\n'; sed -n '/^\[flash\]/,/^# hand-edit flash end/p' "$BOARD_DIR/novo.toml" | grep -v '^#' | grep -v '^trial_ms'
    echo "trial_ms    = $TRIAL_MS"; } >> "$WORK/boot/novo.toml"
fi
if (cd "$WORK/boot" && "$NOVO" build --target="$SLUG" --role=bootloader --memory-report=none \
      -o "$WORK/boot.elf" src/main.nv) > "$WORK/boot.log" 2>&1; then
  pass "the bootloader builds for $SLUG, waiting 4 s before the jump"
else
  fail "the bootloader does not build" "$(tail -6 "$WORK/boot.log")"; finish
fi
# The dfu-nv command.
mkdir -p "$WORK/orbit"
for p in dfu-nv novoboot; do
  mkdir -p "$WORK/orbit/$p"
  (cd "$REPO/orbit/$p" && tar --exclude=_novo --exclude="./$p" -cf - .) | (cd "$WORK/orbit/$p" && tar -xf -)
done
if (cd "$WORK/orbit/dfu-nv" && "$NOVO" pkg build) > "$WORK/cli.log" 2>&1 && [ -x "$WORK/orbit/dfu-nv/dfu-nv" ]; then
  pass "the dfu-nv command builds"
else
  fail "the dfu-nv command does not build" "$(tail -5 "$WORK/cli.log")"; finish
fi
CLI="$WORK/orbit/dfu-nv/dfu-nv"
# The device program, with the modules it needs beside it.
CRCD="$(registry_pkg_dir crc-nv "$NOVOFS_LOCK")" || { fail "crc-nv" "$REGISTRY_PKG_WHY"; finish; }
mkdir -p "$WORK/dev"
cp "$DFU/src/dfuerr.nv" "$DFU/src/dfuimg.nv" "$DFU/src/dfuserial.nv" "$DFU/src/dfulink.nv" \
   "$DFU/src/dfucrc.nv" "$DFU/src/dfuport.nv" "$DFU/src/dfudev.nv" \
   "$NV/src/bytes32.nv" "$NV/src/bootimg.nv" "$NV/src/bootslot.nv" "$NV/src/bootdev.nv" \
   "$NV/src/imghash.nv" "$NV/src/sha2.nv" "$NV/src/ed25519.nv" "$NV/src/fe25519.nv" \
   "$CRCD/src/crc.nv" "$DFU/examples/$EXAMPLE.nv" "$WORK/dev/"
if (cd "$WORK/dev" && "$NOVO" build --target="$SLUG" --role=application --image-version=1.0.0 \
      "$EXAMPLE.nv") > "$WORK/dev/build.log" 2>&1 && [ -f "$WORK/dev/$EXAMPLE.img" ]; then
  pass "$EXAMPLE builds with --role=application, its serve loop @no_alloc"
  sed -n '/memory report/,/per type/p' "$WORK/dev/build.log" | sed 's/^/    /'
else
  fail "the device program does not build" "$(grep -m4 error "$WORK/dev/build.log")"; finish
fi
# The images an update carries: the board's boot_app, confirming (app2) and
# not (app3).
app() {
  local name="$1" confirm="$2" version="$3"
  mkdir -p "$WORK/$name"
  sed -e "s/^let NAME = .*/let NAME = \"$name\"/" -e "s/^let CONFIRM = .*/let CONFIRM = $confirm/" \
    "$APP_SRC" > "$BOARD_DIR/tests/.dfu_app_$name.nv"
  (cd "$WORK/$name" && "$NOVO" build --target="$SLUG" --role=application --image-version="$version" \
     --memory-report=none -o "$WORK/$name.elf" "$BOARD_DIR/tests/.dfu_app_$name.nv") > "$WORK/$name.log" 2>&1
  local rc=$?
  rm -f "$BOARD_DIR/tests/.dfu_app_$name.nv"
  [ $rc = 0 ] && [ -f "$WORK/$name.img" ]
}
for spec in "app2 true 2.0.0" "app3 false 3.0.0"; do
  # shellcheck disable=SC2086
  if app $spec; then
    pass "$(cut -d' ' -f1 <<< "$spec") builds with --role=application: $(wc -c < "$WORK/$(cut -d' ' -f1 <<< "$spec").img") bytes"
  else
    fail "$(cut -d' ' -f1 <<< "$spec") does not build" "$(tail -4 "$WORK/$(cut -d' ' -f1 <<< "$spec").log")"; finish
  fi
done
for img in "$WORK/dev/$EXAMPLE.img" "$WORK/app2.img" "$WORK/app3.img"; do
  if "$CLI" info "$img" | grep -q "the header's CRC-32C and the image's SHA-256 hold"; then
    pass "dfu-nv info: $(basename "$img") holds"
  else
    fail "dfu-nv info of $(basename "$img")" "$("$CLI" info "$img" 2>&1)"
  fi
done

SLOT_A=$(sed -n 's/^slot_a *= *\[0x\([0-9A-Fa-f]*\),.*/\1/p' "$BOARD_DIR/novo.toml")
SLOT_B=$(sed -n 's/^slot_b *= *\[0x\([0-9A-Fa-f]*\),.*/\1/p' "$BOARD_DIR/novo.toml")
SLOT_LEN=$(sed -n 's/^slot_b *= *\[[^,]*, *\(0x[0-9A-Fa-f]*\)\].*/\1/p' "$BOARD_DIR/novo.toml")
SLOT_LEN=$((SLOT_LEN))

# ── the board ──────────────────────────────────────────────────────────────
SEL="${!BENCH_VAR:-}"
if [ -z "$SEL" ]; then
  echo ""
  skip "$BENCH_VAR is unset; set it to the board's probe to run sections 2 to 6 (owed: board not attached)"
  finish
fi
command -v probe-rs > /dev/null 2>&1 || { fail "$BENCH_VAR is set and probe-rs is not installed"; finish; }

# The board's bench lock, held to the end.
LOCKFILE="/tmp/novo-bench-${SLUG}.lock"
exec {LOCK_FD}> "$LOCKFILE"
flock -w 1800 "$LOCK_FD" || { fail "the bench lock $LOCKFILE is not free"; finish; }

wait_probe() { while grep -qF -- "$SEL" <<< "$(pgrep -a -x probe-rs)"; do sleep 1; done; }
pr() {
  local verb="$1" try; shift
  for try in 1 2 3; do
    wait_probe
    timeout 120 probe-rs "$verb" --chip "$CHIP" --probe "$SEL" "$@" && return 0
    sleep 2
  done
  return 1
}
watch() {
  local log="$1" want="$2" secs="$3" verb="$4" runner; shift 4
  wait_probe
  timeout "$((secs + 5))" probe-rs "$verb" --chip "$CHIP" --probe "$SEL" "$@" > "$log" 2>&1 &
  runner=$!
  for _ in $(seq 1 $((secs * 10))); do
    grep -aqE -- "$want" "$log" && break
    kill -0 "$runner" 2> /dev/null || break
    sleep 0.1
  done
  sleep 0.3
  kill "$runner" 2> /dev/null
  wait "$runner" 2> /dev/null
}
clean() { sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\[Terminal\] //g' -e 's/^[0-9:.]*: //' "$1" | tr -d '\r'; }
word() { pr read b32 "0x$(printf '%08X' $(( $1 )))" 1 2> /dev/null | awk '{print $2}' | tail -1; }
put() { pr download --binary-format bin --base-address "0x$2" "$1" > "$WORK/put.log" 2>&1; }
python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * $SLOT_LEN)" > "$WORK/erased_slot.bin"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
RTT="$WORK/rtt.out"
start_bridge() {
  wait_probe
  : > "$RTT"
  python3 "$DFU/tests/rtt_bridge.py" --port "$PORT" --out "$RTT" -- \
    probe-rs attach --chip "$CHIP" --probe "$SEL" --no-timestamps --rtt-up-channels 0 \
      --target-output-file "$RTT" "$WORK/dev/$EXAMPLE.elf" > "$WORK/bridge.log" 2>&1 &
  BRIDGE=$!
  local i
  for i in $(seq 1 100); do
    grep -q "listening" "$WORK/bridge.log" 2> /dev/null && break
    sleep 0.1
  done
}
stop_bridge() {
  [ -n "$BRIDGE" ] || return 0
  kill -INT "$BRIDGE" 2> /dev/null
  local i
  for i in $(seq 1 100); do kill -0 "$BRIDGE" 2> /dev/null || break; sleep 0.1; done
  BRIDGE=""
}
reset_board() { pr reset > /dev/null 2>&1; }
# state: the state line the device program printed when it last started.
state() {
  local i
  for i in $(seq 1 ${1:-100}); do grep -q "dfu-board: ready" "$RTT" 2> /dev/null && break; sleep 0.1; done
  grep -a "dfu-board: state" "$RTT" 2> /dev/null | tail -1 | sed 's/^.*\(dfu-board: state.*\)$/\1/'
}
send() { timeout 900 "$CLI" send "$1" --tcp "127.0.0.1:$PORT" --timeout "$TIMEOUT" --tries 3 2>&1; }
# run_app <elf> <want> <log>: the application's lines, attached with its own image.
run_app() {
  sleep 5
  watch "$WORK/$3.log" "$2" 15 attach "$1"
  OUT=$(clean "$WORK/$3.log")
}
# fresh: the bootloader, both slots erased, the device program in slot A,
# started, its bridge up.
fresh() {
  stop_bridge
  pr download "$WORK/boot.elf" > "$WORK/dl.log" 2>&1 && put "$WORK/erased_slot.bin" "$SLOT_A" \
    && put "$WORK/erased_slot.bin" "$SLOT_B" && put "$WORK/dev/$EXAMPLE.img" "$SLOT_A" \
    || { fail "the images could not be flashed" "$(tail -3 "$WORK/dl.log" "$WORK/put.log")"; finish; }
  reset_board
  sleep 6
  start_bridge
}
V1=16777216; V2=33554432; V3=50331648
HDR_TRIED=44595254; HDR_CONF=464e4f43

# ── 2. an update into slot B, swapped in, confirmed ───────────────────────
echo ""
echo "2. dfu-nv send app2: slot B, the swap, the trial, the confirmation"
fresh
ST=$(state)
if grep -q "a=1 version=$V1 pending=0 tried=0 confirmed=1 b=0" <<< "$ST"; then
  pass "the device program runs from slot A and has confirmed itself: $ST"
else
  fail "the device program does not start from slot A" "$ST $(tail -3 "$RTT" 2> /dev/null)"
fi
OUT=$(send "$WORK/app2.img"); RC=$?
if [ "$RC" -eq 0 ]; then pass "dfu-nv send app2.img: $(tail -1 <<< "$OUT")"; else fail "dfu-nv send app2.img rc=$RC" "$(tail -4 <<< "$OUT")"; fi
stop_bridge
reset_board
# The swap of an image moves it through the swap area; the application
# starts afterwards.
run_app "$WORK/app2.elf" "app running" s2app
if grep -qx "app app2" <<< "$OUT" && grep -qx "confirmed after=1" <<< "$OUT"; then
  pass "the bootloader swapped app2 into slot A, started it, and it confirmed itself"
else
  fail "app2 did not run and confirm after the reset" "$(grep -av '^\s*$' <<< "$OUT" | tail -8)"
fi
t=$(word "0x$SLOT_A + 0xF4"); c=$(word "0x$SLOT_A + 0xF8")
if [ "$t" = "$HDR_TRIED" ] && [ "$c" = "$HDR_CONF" ]; then
  pass "the probe reads slot A's tried word 0x$t and confirmed word 0x$c"
else
  fail "slot A's tried and confirmed words read ${t:-nothing} ${c:-nothing}"
fi
c=$(word "0x$SLOT_B + 0xF8")
[ "$c" = "$HDR_CONF" ] && pass "slot B holds the device program, which had confirmed itself" \
                       || fail "slot B's confirmed word reads ${c:-nothing}"

# ── 3. updates cut by a reset ──────────────────────────────────────────────
echo ""
echo "3. dfu-nv send app2 cut by a reset of the board, twice, then completed"
fresh
cut_after() {
  local want="$1" out="$WORK/cut_$1.out" sender i
  send "$WORK/app2.img" > "$out" &
  sender=$!
  for i in $(seq 1 3000); do
    [ "$(grep -c 'bytes durable' "$out")" -ge "$want" ] && break
    kill -0 "$sender" 2> /dev/null || break
    sleep 0.1
  done
  stop_bridge
  wait "$sender"; local rc=$?
  reset_board
  sed 's/^/    /' "$out"
  echo "$rc"
}
rc=$(cut_after 1 | tail -1)
sleep 8
start_bridge
ST=$(state)
if [ "$rc" -eq 3 ] && grep -q "a=1 version=$V1 pending=0 tried=0 confirmed=1" <<< "$ST" && ! grep -q "b=1 version=$V2 pending=1" <<< "$ST"; then
  pass "cut after one object: the bootloader started the device program, slot A whole, slot B not marked: $ST"
else
  fail "after the first cut" "rc=$rc $ST"
fi
rc=$(cut_after 2 | tail -1)
sleep 8
start_bridge
ST=$(state)
if grep -q "a=1 version=$V1 pending=0 tried=0 confirmed=1" <<< "$ST" && ! grep -q "b=1 version=$V2 pending=1" <<< "$ST"; then
  pass "cut again after the resumed run's second object: slot A whole, slot B not marked: $ST"
else
  fail "after the second cut" "rc=$rc $ST"
fi
OUT=$(send "$WORK/app2.img"); RC=$?
sed 's/^/    /' <<< "$OUT"
if [ "$RC" -eq 0 ] && grep -q "resuming at" <<< "$OUT"; then
  pass "dfu-nv send resumed past the start and completed"
else
  fail "dfu-nv send resumed and completed" "rc=$RC"
fi
stop_bridge
reset_board
run_app "$WORK/app2.elf" "app running" s3app
if grep -qx "app app2" <<< "$OUT" && grep -qx "confirmed after=1" <<< "$OUT"; then
  pass "after the last reset app2 runs and confirms itself"
else
  fail "app2 did not run after the resumed update" "$(grep -av '^\s*$' <<< "$OUT" | tail -8)"
fi

# ── 4. an update that does not confirm is reverted ────────────────────────
echo ""
echo "4. dfu-nv send app3, which never confirms: reverted by the watchdog"
fresh
OUT=$(send "$WORK/app3.img"); RC=$?
[ "$RC" -eq 0 ] && pass "dfu-nv send app3.img: $(tail -1 <<< "$OUT")" || fail "dfu-nv send app3.img rc=$RC" "$(tail -4 <<< "$OUT")"
stop_bridge
reset_board
# app3 runs on trial, feeds no watchdog; the watchdog resets the board,
# and the next boot reverts.  The device program prints its state once it
# is back.
sleep $(( ${TRIAL_MS:-4000} / 1000 + 25 ))
start_bridge
ST=$(state 600)
if grep -q "a=1 version=$V1 pending=0 tried=0 confirmed=1 b=1 version=$V3 pending=1 tried=1 confirmed=0" <<< "$ST"; then
  pass "reverted: the device program runs from slot A again, slot B holds app3 pending and tried, never confirmed: $ST"
else
  fail "the update that never confirms was not reverted" "$ST"
fi

# ── 5. pending and confirmed in slot B starts under rule 4 ────────────────
echo ""
echo "5. app3 with the confirmed word set in slot B: started under rule 4, not reverted"
fresh
OUT=$(send "$WORK/app3.img"); RC=$?
[ "$RC" -eq 0 ] && pass "dfu-nv send app3.img: $(tail -1 <<< "$OUT")" || fail "dfu-nv send app3.img rc=$RC" "$(tail -4 <<< "$OUT")"
stop_bridge
pr write b32 "0x$(printf '%08X' $(( 0x$SLOT_B + 0xF8 )))" 0x464E4F43 > /dev/null 2>&1
c=$(word "0x$SLOT_B + 0xF8"); p=$(word "0x$SLOT_B + 0xF0")
if [ "$c" = "$HDR_CONF" ] && [ "$p" = "444e4550" ]; then
  pass "slot B holds app3 with both the pending word and the confirmed word"
else
  fail "slot B's pending and confirmed words read ${p:-nothing} ${c:-nothing}"
fi
reset_board
# The first boot swaps and starts app3 on trial; the watchdog resets it;
# the second boot's lines are read.
t0=$SECONDS
: > "$WORK/s5.log"
while [ $((SECONDS - t0)) -lt 120 ]; do
  watch "$WORK/s5.try" "reset reason=3|no image to start" 10 attach "$WORK/boot.elf"
  cat "$WORK/s5.try" >> "$WORK/s5.log"
  grep -aqE "reset reason=3" "$WORK/s5.try" && break
  sleep 1
done
OUT=$(clean "$WORK/s5.log")
if grep -qx "rule: boot a" <<< "$OUT" && grep -qx "slot a: ok v3.0.0 unsigned pending tried confirmed" <<< "$OUT"; then
  pass "after the watchdog's reset the bootloader starts app3 under rule 4: valid, pending, tried and confirmed is not a failed trial"
else
  fail "app3 was not started under rule 4" "$(grep -av '^\s*$' <<< "$OUT" | tail -12)"
fi

# ── 6. the board is left with the bootloader and blink ────────────────────
echo ""
echo "6. tests/boot.sh, last"
stop_bridge
flock -u "$LOCK_FD"
if bash "$BOARD_DIR/tests/boot.sh" > "$WORK/boot_sh.log" 2>&1; then
  pass "tests/boot.sh passes and leaves the board with the bootloader and blink: $(grep -a 'pass=' "$WORK/boot_sh.log" | tail -1)"
else
  fail "tests/boot.sh" "$(tail -8 "$WORK/boot_sh.log")"
fi

finish
