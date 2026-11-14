#!/bin/bash
# orbit/novoboot/tests/board_boot.sh: the bootloader and the A/B layout
# on a board, through its probe.  Each board's tests/boot.sh sets the
# board's facts and sources this file.
#
# The board's script sets:
#
#   SLUG        the board's --target slug
#   CHIP        the probe-rs chip name
#   BENCH_VAR   the name of the variable that selects the board's probe
#   BOARD_DIR   the board package's directory, whose tests/boot_app.nv
#               is the application
#   LED_ADDR    the GPIO output register of the board's LED, as hex
#   LED_BIT     the LED's bit in it
#
# and may set TRIAL_MS, a trial timeout for the bench's main bootloader
# in place of the table's, for a board whose probe takes longer than the
# default's 4 s to attach to an image on trial, and may define
# SETTLE_WATCHDOG, which leaves no watchdog running behind blink on a
# chip whose watchdog the probe's reset does not stop (the nRF52's),
# run after blink is written.  A board whose probe or reset needs more may
# set DL_FLAGS (flags for every `probe-rs download`), SLOT_ERASE_BYTES (the
# bytes written 0xFF into a slot to empty it, the slot's size by default:
# a board whose writes are slow empties the header and the start of the
# slot, which is all the bootloader reads of an empty slot) and define
# BOARD_RESET, the reset that starts the board in place of `probe-rs reset`, and
# PROBE_RESET_MAX, the latest second at which the suite resets the board during a
# swap (7.0 by default): a board whose swap of the test image ends sooner sets the
# time the swap ends, since a reset after it falls in the trial of the new image,
# which the bootloader reverts by design.
#
# The slots, the status region, the header size and the erase unit come
# from the board's [flash] table through the build.
#
# Without a board the suite builds: the bootloader for the board with
# `--role=bootloader`, with and without coverage hooks and with
# `signing = "required"` from a project table, the applications with
# `--role=application`, unsigned and signed, and checks the stamped
# headers on the host.
#
# With the board's probe named, through the probe and the lines the
# bootloader and the applications print:
#
#   1. the bootloader and app1 flashed: the bootloader checks slot A,
#      starts it, and app1 confirms itself (the confirmed word read
#      through the probe);
#   2. app2 written into slot B as pending: swapped into slot A, started
#      on trial under the watchdog, never confirmed; the watchdog resets
#      the board and the next boot reverts it: slot A is app1 again, and
#      slot B holds app2 marked tried, which is never tried again;
#   3. a swap of app4 into slot A cut by a reset of the core at each
#      point of each step (after the step's word is written, after its
#      destination is erased, after half its copy), after the record's
#      header and after its complete word and its cleared magic, each from a
#      bootloader built to cut there: the next boot finishes the swap
#      from the step it was in, both slots check whole, and app4 runs;
#      then the probe resets the board at moments the suite does not
#      choose during a swap, with the same outcome;
#   4. app2 pending in slot B with one bit of its image changed is
#      refused for its hash and slot A runs;
#   5. app2 pending in slot B with its image half written is refused;
#   6. slot A with one bit of its header changed is refused for its CRC,
#      and the image in slot B is restored into slot A and runs;
#   7. headers built for another chip, another board, another header
#      version and a size past the slot are each refused;
#   8. a bootloader built with `signing = "required"`: an unsigned image
#      is refused and nothing starts; a signed image starts; the same
#      image with one bit changed is refused for its hash, re-hashed it
#      is refused for its signature, and with S + L in place of S it is
#      refused; a bootloader with no key refuses a signed image;
#   9. the measured time of the hash and the signature check, from the
#      bootloader without coverage hooks;
#  10. every line of the bootloader's and the header library's device
#      path ran, but for a line a `cov: skip` marker excuses;
#  11. blink built with `--role=application`, flashed into slot A, and
#      started by the bootloader, its LED pin read toggling.
#
# The board is left with the bootloader in its first sectors and blink
# in slot A.  One probe-rs runs at a time on the board's probe: each call
# waits for any other on the same probe to finish.

set -uo pipefail

NV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$NV/../.." && pwd)"
NOVO="${NOVO:-$REPO/bin/novo}"
BLINK="$REPO/examples/intro/blink.nv"
APP_SRC="$BOARD_DIR/tests/boot_app.nv"
TOOL="$NV/tests/imgtool.py"

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1"; }
finish() {
  echo "══════════════════════════════════════════"
  echo "  pass=$PASS fail=$FAIL"
  echo "══════════════════════════════════════════"
  [ "$FAIL" = "0" ]
  exit $?
}

echo ""
echo "══════════════════════════════════════════"
echo "  the bootloader and the A/B layout on the $SLUG"
echo "══════════════════════════════════════════"

[ -x "$NOVO" ] || { echo "ERROR: $NOVO not found; build first" >&2; exit 1; }
for tool in arm-none-eabi-nm openssl python3; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "  (skipped: $tool not installed)"
    finish
  fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/novoboot_board_XXXXXX")
[ -n "${NOVOBOOT_KEEP:-}" ] && echo "  (keeping $WORK)" || trap 'rm -rf "$WORK"' EXIT

# ── 1. the builds ──────────────────────────────────────────────────────────
echo ""
echo "1. the builds"
# A signing key of this run's own, named by a configuration of its own,
# so the user's configuration is never read.  Decoding a public key takes
# one of two square roots and may negate x; the base point is built in,
# so only the key's decoding runs those lines on the device, and the
# suite takes a key whose decoding takes the second root and negates.
key_branches() {
  openssl pkey -in "$1" -pubout -outform DER 2> /dev/null | tail -c 32 | python3 -c '
import sys
b = sys.stdin.buffer.read()
p = 2**255 - 19
d = (-121665 * pow(121666, p - 2, p)) % p
y = int.from_bytes(b, "little") & ((1 << 255) - 1)
u = (y * y - 1) % p
v = (d * y * y + 1) % p
x = u * pow(v, 3, p) * pow(u * pow(v, 7, p), (p - 5) // 8, p) % p
second = v * x * x % p != u
if second:
    x = x * pow(2, (p - 1) // 4, p) % p
print("yes" if second and (x & 1) != b[31] >> 7 else "no")'
}
for _ in $(seq 1 64); do
  openssl genpkey -algorithm ed25519 -out "$WORK/key.pem" 2> /dev/null
  [ "$(key_branches "$WORK/key.pem")" = yes ] && break
done
printf '[signing]\nkey = "%s"\n' "$WORK/key.pem" > "$WORK/config.toml"
printf '' > "$WORK/nokey.toml"
export NOVO_CONFIG="$WORK/nokey.toml"

# build <out.elf> <log> <flags...>: the bootloader, from a copy of the
# package whose `HOLD_MS` waits before the jump, so the probe reads its
# log and its coverage table before the image clears the RAM.
stage_boot() {
  local dir="$1" table="$2"
  mkdir -p "$dir"
  cp -r "$NV/src" "$dir/"
  sed -i 's/^let HOLD_MS = .*/let HOLD_MS = 4000/' "$dir/src/main.nv"
  cp "$NV/novo.toml" "$dir/novo.toml"
  [ -n "$table" ] && printf '\n%s\n' "$table" >> "$dir/novo.toml"
}
# The board's table with signing switched to required and a trial
# timeout of its own, as a project's table, which wins over the board's.
REQ_TABLE=$(sed -n '/^\[flash\]/,/^# hand-edit flash end/p' "$BOARD_DIR/novo.toml" \
              | grep -v '^#' | grep -v '^trial_ms' \
              | sed 's/^signing .*/signing     = "required"\ntrial_ms    = 2500/')
OPT_TABLE=""
if [ -n "${TRIAL_MS:-}" ]; then
  OPT_TABLE=$(sed -n '/^\[flash\]/,/^# hand-edit flash end/p' "$BOARD_DIR/novo.toml" \
                | grep -v '^#' | grep -v '^trial_ms'; echo "trial_ms    = $TRIAL_MS")
fi
stage_boot "$WORK/b_opt" "$OPT_TABLE"
stage_boot "$WORK/b_req" "$REQ_TABLE"
build_boot() {
  local dir="$1" out="$2" log="$3"; shift 3
  (cd "$dir" && "$NOVO" build --target="$SLUG" --role=bootloader "$@" -o "$dir/main.elf" src/main.nv) \
    > "$log" 2>&1 && cp "$dir/main.elf" "$out"
}
if NOVO_CONFIG="$WORK/config.toml" build_boot "$WORK/b_opt" "$WORK/boot.elf" "$WORK/boot.log" --cov; then
  pass "the bootloader builds for $SLUG with --role=bootloader and --cov, signing optional, the run's key"
else
  fail "the bootloader does not build" "$(tail -8 "$WORK/boot.log")"; finish
fi
if NOVO_CONFIG="$WORK/config.toml" build_boot "$WORK/b_req" "$WORK/boot_req.elf" "$WORK/boot_req.log" --cov; then
  pass "and with signing = \"required\" from a project's [flash] table"
else
  fail "the required-signing bootloader does not build" "$(tail -8 "$WORK/boot_req.log")"; finish
fi
if build_boot "$WORK/b_req" "$WORK/boot_nokey.elf" "$WORK/boot_nokey.log" --cov; then
  pass "and with no signing key configured"
else
  fail "the bootloader with no key does not build" "$(tail -8 "$WORK/boot_nokey.log")"; finish
fi
mkdir -p "$WORK/b_fast"
cp -r "$NV/src" "$WORK/b_fast/"
cp "$NV/novo.toml" "$WORK/b_fast/novo.toml"
printf '\n%s\n' "$REQ_TABLE" >> "$WORK/b_fast/novo.toml"
sed -i 's/^let HOLD_MS = .*/let HOLD_MS = 4000/' "$WORK/b_fast/src/main.nv"
if NOVO_CONFIG="$WORK/config.toml" build_boot "$WORK/b_fast" "$WORK/boot_fast.elf" "$WORK/boot_fast.log"; then
  pass "and without coverage hooks, for the times"
else
  fail "the bootloader without coverage hooks does not build" "$(tail -8 "$WORK/boot_fast.log")"; finish
fi
for elf in boot.elf boot_fast.elf; do
  size=$(arm-none-eabi-size "$WORK/$elf" | awk 'NR == 2 {print $1 + $2}')
  echo "    $elf: $size bytes of flash"
done
BOOT_BYTES=$(arm-none-eabi-size "$WORK/boot_fast.elf" | awk 'NR == 2 {print $1 + $2}')
BOOT_REGION=$(sed -n 's/^bootloader *= *\[[^,]*, *\(0x[0-9A-Fa-f]*\)\].*/\1/p' "$BOARD_DIR/novo.toml")
BOOT_REGION=$((BOOT_REGION))
if [ "$BOOT_BYTES" -lt 65536 ] && [ "$BOOT_BYTES" -le "$BOOT_REGION" ]; then
  pass "the bootloader without coverage hooks is $BOOT_BYTES bytes, under 65,536 and inside its $BOOT_REGION-byte region: $(grep -o 'flash  .*' "$WORK/boot_fast.log" | head -1)"
else
  fail "the bootloader is $BOOT_BYTES bytes, against 65,536 and its $BOOT_REGION-byte region"
fi
if grep -q "hal.watchdog on" "$WORK/boot.log"; then
  pass "the bootloader's hal.watchdog is the board's driver: $(grep -o 'hal.watchdog on [A-Za-z0-9_]*' "$WORK/boot.log")"
else
  fail "the bootloader's image has no watchdog driver" "$(grep "board's drivers" "$WORK/boot.log")"
fi

# app <name> <confirm> <version> [--sign]: the application built into
# slot A, as <name>.elf and <name>.img.
app() {
  local name="$1" confirm="$2" version="$3"; shift 3
  mkdir -p "$WORK/$name"
  sed -e "s/^let NAME = .*/let NAME = \"$name\"/" -e "s/^let CONFIRM = .*/let CONFIRM = $confirm/" \
    "$APP_SRC" > "$BOARD_DIR/tests/.boot_app_$name.nv"
  (cd "$WORK/$name" && NOVO_CONFIG="$WORK/config.toml" "$NOVO" build --target="$SLUG" \
     --role=application --image-version="$version" --memory-report=none "$@" \
     -o "$WORK/$name.elf" "$BOARD_DIR/tests/.boot_app_$name.nv") > "$WORK/$name.log" 2>&1
  local rc=$?
  rm -f "$BOARD_DIR/tests/.boot_app_$name.nv"
  [ $rc = 0 ] && [ -f "$WORK/$name.img" ]
}
for spec in "app1 true 1.0.0" "app2 false 2.0.0" "app3 true 3.0.0 --sign" "app4 true 2.0.0"; do
  # shellcheck disable=SC2086
  if app $spec; then
    pass "$(cut -d' ' -f1 <<< "$spec") builds with --role=application: $(grep -o 'stamped the image header[^;]*' "$WORK/$(cut -d' ' -f1 <<< "$spec").log" | cut -c1-120)"
  else
    fail "$(cut -d' ' -f1 <<< "$spec") does not build" "$(tail -6 "$WORK/$(cut -d' ' -f1 <<< "$spec").log")"; finish
  fi
done
HDR=$(python3 -c "import struct,sys; print(struct.unpack_from('<H', open(sys.argv[1],'rb').read(), 6)[0])" "$WORK/app1.img")
SLOT_A=$(arm-none-eabi-nm "$WORK/app1.elf" | awk '$3 == "novo_isr_vectors" {print $1}')
SLOT_A=$(printf '%08X' $((16#$SLOT_A - HDR)))
if grep -q "header_bytes=$HDR" <<< "$(python3 "$TOOL" show "$WORK/app1.img")" \
   && grep -q "crc_ok=1" <<< "$(python3 "$TOOL" show "$WORK/app3.img")" \
   && grep -q "flags=0" <<< "$(python3 "$TOOL" show "$WORK/app3.img")"; then
  pass "the headers read back on the host: $HDR header bytes, the vector table at 0x$SLOT_A + $HDR, app3 signed with its CRC whole"
else
  fail "the stamped headers do not read back" "$(python3 "$TOOL" show "$WORK/app3.img")"
fi
SLOT_B=$(sed -n 's/^slot_b *= *\[0x\([0-9A-Fa-f]*\),.*/\1/p' "$BOARD_DIR/novo.toml")
SLOT_LEN=$(sed -n 's/^slot_b *= *\[[^,]*, *\(0x[0-9A-Fa-f]*\)\].*/\1/p' "$BOARD_DIR/novo.toml")
SLOT_LEN=$((SLOT_LEN))
if (cd "$WORK" && "$NOVO" build --target="$SLUG" --role=application --memory-report=none \
      -o "$WORK/blink.elf" "$BLINK") > "$WORK/blink.log" 2>&1 && [ -f "$WORK/blink.img" ]; then
  pass "blink builds with --role=application"
else
  fail "blink does not build with --role=application" "$(tail -6 "$WORK/blink.log")"; finish
fi

# ── the board ──────────────────────────────────────────────────────────────
SEL="${!BENCH_VAR:-}"
if [ -z "$SEL" ]; then
  echo ""
  skip "$BENCH_VAR is unset; set it to the board's probe to run sections 2 to 11"
  finish
fi
if ! command -v probe-rs > /dev/null 2>&1; then
  fail "$BENCH_VAR is set and probe-rs is not installed"
  finish
fi
wait_probe() {
  while grep -qF -- "$SEL" <<< "$(pgrep -a -x probe-rs)"; do sleep 1; done
}
pr() {
  local verb="$1" try flags=""; shift
  [ "$verb" = download ] && flags="${DL_FLAGS:-}"
  for try in 1 2 3; do
    wait_probe
    # shellcheck disable=SC2086
    timeout 120 probe-rs "$verb" --chip "$CHIP" --probe "$SEL" $flags "$@" && return 0
    sleep 2
  done
  return 1
}
# The reset that starts the board: probe-rs's, or the board's own when its
# script defines BOARD_RESET (the nRF54LM20 DK starts an image reliably
# with a pin reset only).
board_reset() {
  if declare -F BOARD_RESET > /dev/null; then BOARD_RESET; else pr reset; fi
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
clean() {
  sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\[Terminal\] //g' -e 's/^[0-9:.]*: //' "$1" | tr -d '\r'
}
OUT=""
expect() {
  if grep -qxF -- "$1" <<< "$OUT"; then pass "$2"
  else fail "$2: no line '$1'" "$(grep -av '^\s*$' <<< "$OUT" | tail -14)"; fi
}
value() { sed -n "s/^$1=\\(-\\?[0-9]*\\)$/\\1/p" <<< "$OUT" | tail -1; }
word() { pr read b32 "0x$(printf '%08X' $(( $1 )))" 1 2> /dev/null | awk '{print $2}' | tail -1; }

COV_N=0
# boot <elf> <step> [wait]: reset the board, or with `wait` let the board
# reset itself within 30 s, and read the bootloader's lines, then its
# coverage table while it waits before the jump.
boot() {
  local elf="$1" step="$2" secs=20 addr size
  [ "${3:-}" = wait ] || board_reset > /dev/null 2>&1
  # A session attached across the board's own reset ends at the reset,
  # and one cannot attach while the core stalls on a flash erase, so the
  # suite attaches again until a session reads the boot's lines, which
  # wait in the RTT buffer until read.
  local t0=$SECONDS
  : > "$WORK/$step.log"
  while [ $((SECONDS - t0)) -lt 60 ]; do
    watch "$WORK/$step.try" "start 0x|no image to start" 10 attach "$elf"
    cat "$WORK/$step.try" >> "$WORK/$step.log"
    grep -aqE "start 0x|no image to start" "$WORK/$step.try" && break
    sleep 1
  done
  OUT=$(clean "$WORK/$step.log")
  read -r addr size < <(arm-none-eabi-nm -S "$elf" | awk '$4 == "novo_cov_bits" {print "0x" $1, $2}')
  if [ -n "${addr:-}" ]; then
    COV_N=$((COV_N + 1))
    pr read b8 "$addr" "$((16#$size))" -o "$WORK/cov_$(basename "$elf" .elf)_$COV_N.bin" -f binary > /dev/null 2>&1
  fi
}
# run_app <elf> <want> <step>: the application's lines, attached with its
# own image once the bootloader's wait before the jump is over and the
# application has set up its RTT control block.
run_app() {
  sleep 5
  watch "$WORK/$3.log" "$2" 15 attach "$1"
  # A probe whose USB transport fails to open is asked once more.
  if ! grep -aqE -- "$2" "$WORK/$3.log" && grep -aq "Failed to open probe" "$WORK/$3.log"; then
    sleep 1
    watch "$WORK/$3.log" "$2" 15 attach "$1"
  fi
  OUT=$(clean "$WORK/$3.log")
}
# put <file> <hex addr>: bytes written into the flash by address, the
# units they touch erased first.
put() { pr download --binary-format bin --base-address "0x$2" "$1" > "$WORK/put.log" 2>&1; }
erased() { python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * $1)" > "$2"; }

# ── 2. the first boot ──────────────────────────────────────────────────────
echo ""
echo "2. the bootloader starts app1, which confirms itself"
erased "${SLOT_ERASE_BYTES:-$SLOT_LEN}" "$WORK/erased_slot.bin"
# The half-written image of section 5 needs the bytes after its first half
# erased too, or old bytes of an image written there before could complete it.
erased "$SLOT_LEN" "$WORK/erased_full.bin"
if pr download "$WORK/boot.elf" > "$WORK/dl.log" 2>&1 && put "$WORK/erased_slot.bin" "$SLOT_A" \
   && put "$WORK/erased_slot.bin" "$SLOT_B" && put "$WORK/app1.img" "$SLOT_A"; then
  pass "the bootloader flashed, both slots erased, app1 written into slot A"
else
  fail "the images could not be flashed" "$(tail -3 "$WORK/dl.log" "$WORK/put.log")"; finish
fi
boot "$WORK/boot.elf" s2
expect "novoboot"                                  "the bootloader runs from the flash's reset address"
expect "signing required=0"                        "with signing optional, the board's table"
if [ -n "${TRIAL_MS:-}" ]; then
  expect "trial ms=$TRIAL_MS"                      "and the trial's timeout the bench's, $TRIAL_MS ms"
else
  expect "trial ms=4000"                           "and the trial's timeout the default, 4000 ms, the board's table naming none"
fi
expect "key=1"                                     "and the run's public key built in"
expect "slot a: ok v1.0.0 unsigned"                "slot A: app1's header, hash and policy pass"
expect "slot b: empty"                             "slot B holds no header"
expect "rule: boot a"                              "the rule starts slot A"
expect "start 0x$(printf '%08x' $((16#$SLOT_A + HDR)))" "at its vector table, after the header"
run_app "$WORK/app1.elf" "app running" s2app
expect "app app1"                                  "app1 runs"
expect "confirmed before=0"                        "unconfirmed at first"
expect "confirm rc=0"                              "hal.boot.confirm() writes the confirmed word"
expect "confirmed after=1"                         "and hal.boot.confirmed() reads it"
w=$(word "0x$SLOT_A + 0xF8")
[ "$w" = "464e4f43" ] && pass "the probe reads slot A's confirmed word: 0x$w (\"CONF\")" \
                     || fail "slot A's confirmed word reads ${w:-nothing}"

# ── 3. an update that never confirms ───────────────────────────────────────
echo ""
echo "3. app2 pending in slot B: tried once, never confirmed, reverted"
python3 "$TOOL" pend "$WORK/app2.img" "$WORK/app2_pend.img"
put "$WORK/app2_pend.img" "$SLOT_B" || fail "app2 could not be written into slot B"
boot "$WORK/boot.elf" s3
expect "slot b: ok v2.0.0 unsigned pending"        "slot B: app2, pending"
expect "rule: swap, trial a"                       "the rule swaps it into slot A for a trial"
expect "slot a: ok v2.0.0 unsigned pending"        "slot A holds app2 after the swap"
expect "tried mark=0"                              "the tried word is written"
expect "watchdog started=1"                        "the watchdog is armed for the trial"
expect "watchdog ms=${TRIAL_MS:-4000}"             "with the table's trial_ms as its timeout"
swapped=$(value "swap bytes")
STEPS=$(value "swap steps")
[ -n "$swapped" ] && pass "the swap moved $swapped bytes of each slot through the swap area, recording $(value "swap steps") steps in the status region"
run_app "$WORK/app2.elf" "app running" s3app
expect "app app2"                                  "app2 runs on trial"
expect "confirmed after=0"                         "and does not confirm itself, nor feed the watchdog"
# The watchdog's reset, then the bootloader's revert, with nothing done
# through the probe.
boot "$WORK/boot.elf" s3b wait
expect "reset reason=3"                            "the watchdog resets the board: the next boot reads reason 3"
expect "rule: revert"                              "the rule reverts the trial"
expect "slot a: ok v1.0.0 unsigned confirmed"      "slot A holds app1 again, confirmed"
run_app "$WORK/app1.elf" "app running" s3bapp
expect "app app1"                                  "and app1 runs"
w=$(word "0x$SLOT_B + 0xF0"); t=$(word "0x$SLOT_B + 0xF4"); c=$(word "0x$SLOT_B + 0xF8")
if [ "$w" = "444e4550" ] && [ "$t" = "44595254" ] && [ "$c" = "ffffffff" ]; then
  pass "slot B holds app2 marked pending and tried, never confirmed: it is not tried again"
else
  fail "slot B's state words read $w $t $c"
fi
boot "$WORK/boot.elf" s3c
why=$(value "reset reason")
[ -n "$why" ] && [ "$why" != 3 ] && pass "a boot by the probe's reset reads reason $why, not the watchdog's" \
  || fail "the boot by the probe's reset reads reason ${why:-nothing}"
expect "slot a: ok v1.0.0 unsigned confirmed"      "slot A is app1, confirmed"
expect "slot b: ok v2.0.0 unsigned pending tried"  "slot B is the failed trial"
expect "rule: boot a"                              "which the rule leaves alone"
python3 "$TOOL" pend "$WORK/app1.img" "$WORK/app1_pend.img"
put "$WORK/app1_pend.img" "$SLOT_A"
boot "$WORK/boot.elf" s3d
expect "slot a: ok v1.0.0 unsigned pending"        "an update written straight into slot A, pending"
expect "rule: trial a"                             "is started on trial where it is"
expect "tried mark=0"                              "marked tried"
run_app "$WORK/app1.elf" "app running" s3dapp
expect "confirmed after=1"                         "and confirms itself"
put "$WORK/app2_pend.img" "$SLOT_A"
boot "$WORK/boot.elf" s3e
expect "rule: trial a"                             "app2 written straight into slot A is started on trial"
boot "$WORK/boot.elf" s3f wait
expect "reset reason=3"                            "and reset by the watchdog"
expect "slot b: ok v2.0.0 unsigned pending tried"  "with slot B holding a failed trial too"
expect "rule: boot a"                              "the failed trial starts again, there being nothing to go back to"
if grep -q "^watchdog started" <<< "$OUT"; then
  fail "the image that failed its trial is started under the watchdog again"
else
  pass "and not under the watchdog, so it runs"
fi
put "$WORK/app1.img" "$SLOT_A"

# ── 4. a reset at every step of a swap ────────────────────────────────────
echo ""
echo "4. a swap cut by a reset at each step, finished by the next boot"
# app1 in slot A and app4, which confirms itself, pending in slot B: the
# rule swaps them.  Each bootloader here is built to reset the core at one
# point of the swap the boot starts (swaprec.nv, CUT_AT); the boot after
# the reset finds the record, finishes the swap from the step it was in,
# checks both slots whole and starts app4 on trial.
python3 "$TOOL" pend "$WORK/app4.img" "$WORK/app4_pend.img"
STATUS=$(sed -n 's/^status *= *\[0x\([0-9A-Fa-f]*\),.*/\1/p' "$BOARD_DIR/novo.toml")
cut_case() {
  local p="$1" want="$2" dir="$WORK/b_cut_$1"
  stage_boot "$dir" ""
  sed -i "s/^let CUT_AT = .*/let CUT_AT = $p/" "$dir/src/swaprec.nv"
  # A build that resolves the registry dependency again can meet a
  # registry it does not reach for a moment; it is tried twice.
  if ! NOVO_CONFIG="$WORK/config.toml" build_boot "$dir" "$WORK/boot_cut_$p.elf" "$WORK/boot_cut_$p.log" --cov \
     && ! { sleep 5; NOVO_CONFIG="$WORK/config.toml" build_boot "$dir" "$WORK/boot_cut_$p.elf" "$WORK/boot_cut_$p.log" --cov; }; then
    fail "the bootloader cutting at point $p does not build" "$(tail -6 "$WORK/boot_cut_$p.log")"
    return
  fi
  pr download "$WORK/boot_cut_$p.elf" > "$WORK/dl.log" 2>&1
  put "$WORK/app1.img" "$SLOT_A"
  put "$WORK/app4_pend.img" "$SLOT_B"
  boot "$WORK/boot_cut_$p.elf" "s4_$p"
  local ok=1 line
  for line in "cut=$p" "$want" "slot a: ok v2.0.0 unsigned pending" "slot b: ok v1.0.0 unsigned" "rule: trial a"; do
    grep -qxF -- "$line" <<< "$OUT" || { ok=0; fail "cut at point $p: no line '$line'" "$(grep -av '^\s*$' <<< "$OUT" | tail -16)"; }
  done
  [ $ok = 1 ] || return
  run_app "$WORK/app4.elf" "app running" "s4_${p}app"
  if grep -qxF "confirmed after=1" <<< "$OUT"; then
    pass "cut at point $p: '$want', both slots whole after it (app4 in A, app1 in B, each hash checked), and app4 runs and confirms"
  else
    fail "cut at point $p: app4 did not run after the finished swap" "$OUT"
  fi
}
# The three points of each step of the first unit and of the last, which
# on a board whose image spans one unit are the same three steps.
STEPS=${STEPS:-3}
for i in $( (seq 0 2; seq $((STEPS - 3)) $((STEPS - 1))) | sort -nu); do
  for k in $((3 * i)) $((3 * i + 1)) $((3 * i + 2)); do
    cut_case "$k" "swap resumed at step=$i"
  done
done
cut_case 9999 "swap resumed at step=0"
cut_case 10000 "swap record complete, cleared"
st=$(word "0x$STATUS")
[ "$st" = "ffffffff" ] && pass "and the record whose swap had finished is erased" \
                        || fail "the status region's first word reads ${st:-nothing}"
# After the magic is cleared the record is over: the next boot reads the
# slots as the swap left them, app4 pending in A and app1 in B, and
# leaves the region as it is until the next swap erases it.
cut_case 10001 "signing required=0"
st=$(word "0x$STATUS")
[ "$st" = "00000000" ] && pass "and a record whose magic is cleared is not read as one: its first word reads 0" \
                        || fail "the status region's first word reads ${st:-nothing}"

# A reset by the probe at a moment the suite does not choose: some time
# from 0.3 s to 7 s into the boot, over the whole of a swap.
pr download "$WORK/boot.elf" > "$WORK/dl.log" 2>&1
for n in 1 2 3 4; do
  put "$WORK/app1.img" "$SLOT_A"
  put "$WORK/app4_pend.img" "$SLOT_B"
  delay=$(python3 -c "import random; print(round(random.uniform(0.3, ${PROBE_RESET_MAX:-7.0}), 2))")
  board_reset > /dev/null 2>&1
  sleep "$delay"
  board_reset > /dev/null 2>&1
  boot "$WORK/boot.elf" "s4r_$n" wait
  how=$(grep -aoE "swap resumed at step=[0-9]+|swap record complete, cleared|rule: swap, trial a|rule: trial a" <<< "$OUT" | head -1)
  run_app "$WORK/app4.elf" "app running" "s4r_${n}app"
  boot "$WORK/boot.elf" "s4r_${n}v"
  if grep -qxF "slot a: ok v2.0.0 unsigned pending tried confirmed" <<< "$OUT" \
     && grep -qxF "slot b: ok v1.0.0 unsigned" <<< "$OUT"; then
    pass "a probe reset ${delay} s into the boot ($how): app4 in A confirmed and app1 in B, both whole"
  else
    fail "after a probe reset ${delay} s into the boot ($how)" "$(grep -av '^\s*$' <<< "$OUT" | tail -12)"
  fi
done
st=$(word "0x$STATUS")
[ "$st" = "ffffffff" ] && pass "the status region is erased once each swap is over" \
                        || fail "the status region's first word reads ${st:-nothing}"
put "$WORK/app1.img" "$SLOT_A"
put "$WORK/erased_slot.bin" "$SLOT_B"

# ── 5. a corrupt update ────────────────────────────────────────────────────
echo ""
echo "5. a corrupt image and a half-written image are refused"
python3 "$TOOL" flip "$WORK/app2_pend.img" "$WORK/app2_bad.img" $((HDR + 0x400)) 3
put "$WORK/app2_bad.img" "$SLOT_B"
boot "$WORK/boot.elf" s4
expect "slot b: bad hash pending"                  "app2 with one bit of its image changed: refused for its hash"
expect "rule: boot a"                              "and slot A runs"
n=$(stat -c %s "$WORK/app2_pend.img")
python3 "$TOOL" trunc "$WORK/app2_pend.img" "$WORK/app2_half.img" $(( (n / 2 + 3) / 4 * 4 ))
put "$WORK/erased_full.bin" "$SLOT_B"
put "$WORK/app2_half.img" "$SLOT_B"
boot "$WORK/boot.elf" s4b
expect "slot b: bad hash pending"                  "app2 with the second half of its image never written: refused"
expect "rule: boot a"                              "and slot A runs"
run_app "$WORK/app1.elf" "app running" s4app
expect "app app1"                                  "app1 runs"

# ── 6. a corrupt running image, and the other slot ─────────────────────────
echo ""
echo "6. slot A corrupt: refused, and slot B's image restored into it"
put "$WORK/app1.img" "$SLOT_B"
python3 "$TOOL" flip "$WORK/app1.img" "$WORK/app1_badhdr.img" 0x10 0
put "$WORK/app1_badhdr.img" "$SLOT_A"
boot "$WORK/boot.elf" s5
expect "slot a: bad header crc"                    "slot A with one bit of its header changed: refused for the header's CRC"
expect "slot b: ok v1.0.0 unsigned"                "slot B holds a good copy of app1"
expect "rule: restore from b"                      "the rule restores it"
expect "slot a: ok v1.0.0 unsigned"                "slot A holds it after the swap"
run_app "$WORK/app1.elf" "app running" s5app
expect "app app1"                                  "and it runs"

# ── 7. headers for something else ──────────────────────────────────────────
echo ""
echo "7. images built for another chip or board, or with a header this bootloader does not read"
for spec in "0x14 0x12345678 wrong chip" "0x18 0x12345678 wrong board" \
            "0x04 0x00000002 bad header" "0x08 0x7FFFFFFF bad size"; do
  read -r off val what <<< "$spec"
  python3 "$TOOL" field "$WORK/app1.img" "$WORK/x.img" "$off" "$val"
  put "$WORK/x.img" "$SLOT_B"
  boot "$WORK/boot.elf" "s6_$off"
  expect "slot b: $what"                           "a header with $off set to $val is refused: $what"
done

# ── 8. signing ─────────────────────────────────────────────────────────────
echo ""
echo "8. signing = \"required\""
put "$WORK/erased_slot.bin" "$SLOT_B"
if pr download "$WORK/boot_req.elf" > "$WORK/dl.log" 2>&1; then
  pass "the bootloader built with signing required is flashed"
else
  fail "the required-signing bootloader could not be flashed"; finish
fi
boot "$WORK/boot_req.elf" s7
expect "signing required=1"                        "it reads the project's table"
expect "trial ms=2500"                             "and its trial_ms, 2500"
expect "slot a: unsigned confirmed"                "app1, unsigned, is refused"
expect "rule: halt"                                "and with slot B empty"
expect "no image to start"                         "nothing starts"
put "$WORK/app3.img" "$SLOT_A"
boot "$WORK/boot_req.elf" s7b
expect "slot a: ok v3.0.0 signed"                  "app3, signed with the run's key, verifies"
run_app "$WORK/app3.elf" "app running" s7app
expect "app app3"                                  "and runs"
python3 "$TOOL" flip "$WORK/app3.img" "$WORK/app3_bit.img" $((HDR + 0x800)) 5
put "$WORK/app3_bit.img" "$SLOT_A"
boot "$WORK/boot_req.elf" s7c
expect "slot a: bad hash"                          "the same image with one bit changed is refused for its hash"
python3 "$TOOL" rehash "$WORK/app3_bit.img" "$WORK/app3_rehash.img"
put "$WORK/app3_rehash.img" "$SLOT_A"
boot "$WORK/boot_req.elf" s7d
expect "slot a: bad signature"                     "and with its hash and CRC recomputed, for its signature"
python3 "$TOOL" big_s "$WORK/app3.img" "$WORK/app3_bigs.img"
put "$WORK/app3_bigs.img" "$SLOT_A"
boot "$WORK/boot_req.elf" s7e
expect "slot a: bad signature"                     "S + L in place of S is refused (RFC 8032 § 5.1.7)"
put "$WORK/app3.img" "$SLOT_A"
pr download "$WORK/boot_nokey.elf" > "$WORK/dl.log" 2>&1
boot "$WORK/boot_nokey.elf" s7f
expect "key=0"                                     "a bootloader built with no signing key configured"
expect "slot a: no key"                            "refuses the signed image it cannot check"

# ── 9. the times ───────────────────────────────────────────────────────────
echo ""
echo "9. the hash and the signature check, timed without coverage hooks"
pr download "$WORK/boot_fast.elf" > "$WORK/dl.log" 2>&1
boot "$WORK/boot_fast.elf" s8
expect "slot a: ok v3.0.0 signed"                  "the signed image verifies"
hash_us=$(value "hash us"); hash_b=$(value "hash bytes"); ver_us=$(value "verify us")
if [ -n "$hash_us" ] && [ -n "$ver_us" ] && [ "$hash_us" = 0 ]; then
  pass "the times are printed, and read 0: the board's hal.timer counts only the time spent in its delays"
elif [ -n "$hash_us" ] && [ -n "$ver_us" ]; then
  pass "SHA-256 of $hash_b bytes: $hash_us us ($(( hash_b * 1000000 / hash_us / 1024 )) KB/s); Ed25519 verification: $ver_us us"
else
  fail "the times were not printed" "$OUT"
fi
echo "    bootloader: $BOOT_BYTES bytes of flash"

# ── 10. coverage ────────────────────────────────────────────────────────────
echo ""
echo "10. line coverage of the bootloader and the header library, on the board"
merge() {
  python3 - "$@" <<'PY'
import sys
out, ins = sys.argv[1], sys.argv[2:]
acc = None
for p in ins:
    b = open(p, "rb").read()
    acc = bytearray(b) if acc is None else bytearray(x | y for x, y in zip(acc, b))
open(out, "wb").write(bytes(acc or b""))
PY
}
# The coverage builds come from the same source with the same lines,
# the cut builds differing only in a constant, so their tables are the
# same shape and merge by OR.
shopt -s nullglob
tables=("$WORK"/cov_*.bin)
shopt -u nullglob
if [ ${#tables[@]} -gt 0 ]; then
  merge "$WORK/cov.bin" "${tables[@]}"
  for f in main bootimg abrule swaprec imghash sha2 fe25519 ed25519 bytes32; do
    if cov=$(cd "$WORK/b_opt" && python3 "$REPO/scripts/device_coverage.py" "$WORK/boot.elf" "$WORK/cov.bin" \
               "$WORK/b_opt/_novo/main_$SLUG" "src/$f.nv" 2>&1); then
      pass "every line of $f.nv with a hook ran: $(grep -o 'covered .*' <<< "$cov" | tail -1)"
    else
      fail "lines of $f.nv that did not run" "$cov"
    fi
  done
else
  fail "no coverage table was read"
fi

# ── 11. blink, last ────────────────────────────────────────────────────────
echo ""
echo "11. blink in slot A, started by the bootloader"
# The bootloader as it ships: the board's table, no wait before the
# jump, and no key, so it starts an unsigned image.
if (cd "$NV" && NOVO_CONFIG="$WORK/nokey.toml" "$NOVO" build --target="$SLUG" --role=bootloader \
      --memory-report=none -o "$WORK/boot_final.elf" src/main.nv) > "$WORK/final.log" 2>&1 \
   && pr download "$WORK/boot_final.elf" > /dev/null 2>&1; then
  pass "the bootloader as it ships is flashed: $(arm-none-eabi-size "$WORK/boot_final.elf" | awk 'NR == 2 {print $1 + $2}') bytes"
else
  fail "the bootloader could not be built or flashed" "$(tail -4 "$WORK/final.log")"; finish
fi
put "$WORK/erased_slot.bin" "$SLOT_B"
if put "$WORK/blink.img" "$SLOT_A" && board_reset > /dev/null 2>&1; then
  pass "blink written into slot A behind the bootloader, the board reset"
else
  fail "blink could not be written"; finish
fi
if declare -F SETTLE_WATCHDOG > /dev/null; then
  SETTLE_WATCHDOG
fi
sleep 3
seen=""
for _ in 1 2 3 4 5 6 7 8; do
  v=$(pr read b32 "0x$LED_ADDR" 1 2>/dev/null | awk '{print $2}' | tail -1)
  [ -n "$v" ] && seen="$seen $(( (16#$v >> LED_BIT) & 1 ))"
  sleep 0.25
done
if grep -q 0 <<< "$seen" && grep -q 1 <<< "$seen"; then
  pass "blink runs through the bootloader: the LED's pin read$seen"
else
  fail "the LED's pin did not toggle: it read${seen:- nothing}"
fi

finish
