#!/bin/bash

# Tests for server/vbridge-attach, two-way mode's server half, against stub pacat, parec and
# pactl and a throwaway HOME: hooks, one talker at a time, idle, the ready tone. Run from the
# repository root: bash test/vbridge.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$HOME/.config/ssh-mic-bridge/hooks" "$XDG_RUNTIME_DIR" "$WORK/bin"
HOOKS=$HOME/.config/ssh-mic-bridge/hooks
LOG=$WORK/hooks.log
ATTACH=$ROOT/server/vbridge-attach

# pacat keeps what reaches the virtual mic; parec plays 20 ms of silence every 20 ms; pactl
# lists no streams and waits on subscribe.
cat >"$WORK/bin/pacat" <<STUB
#!/bin/bash
exec cat >>"$WORK/vmic.raw"
STUB
cat >"$WORK/bin/parec" <<'STUB'
#!/usr/bin/env python3
import sys, time
while True:
    sys.stdout.buffer.write(bytes(1920)); sys.stdout.buffer.flush(); time.sleep(0.02)
STUB
cat >"$WORK/bin/pactl" <<'STUB'
#!/bin/bash
case "$*" in
  subscribe) exec sleep 3600 ;;
  "-f json list"*) echo "[]" ;;
esac
STUB
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

cat >"$HOOKS/on-attach" <<HOOK
#!/bin/bash
echo "attach \$1 \$2" >>"$LOG"
echo "Front desk listening"
HOOK
cat >"$HOOKS/on-detach" <<HOOK
#!/bin/bash
echo "detach \$1 \$2" >>"$LOG"
HOOK
chmod +x "$HOOKS/on-attach" "$HOOKS/on-detach"

passed=0
failed=0

check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name"
  fi
}

# attach NAME [mode]: starts vbridge-attach with its stdin held open by a fifo; NAME.err,
# NAME.out and NAME.code collect its status, its audio and its exit code.
attach() {
  local name=$1
  mkfifo "$WORK/$name.in"
  ("$ATTACH" "${2:-front-desk}" <"$WORK/$name.in" >"$WORK/$name.out" 2>"$WORK/$name.err"
   echo $? >"$WORK/$name.code") &
  exec {fd}>"$WORK/$name.in"
  eval "FD_$name=$fd"
}

hang_up() {  # closes NAME's stdin, as the laptop stopping does
  local fd
  eval "fd=\$FD_$1"
  exec {fd}>&-
}

wait_for() {  # wait_for FILE PATTERN: up to 10 s
  for _ in {1..100}; do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

exited() {  # exited NAME CODE
  wait_for "$WORK/$1.code" . && [[ $(cat "$WORK/$1.code") == "$2" ]]
}

loud_audio() {  # the stdout of NAME holds more than silence
  python3 -c '
import array, sys
a = array.array("h"); d = open(sys.argv[1], "rb").read(); a.frombytes(d[: len(d) // 2 * 2])
sys.exit(0 if a and max(abs(v) for v in a) > 1000 else 1)' "$WORK/$1.out"
}

# ---------------------------------------------------------------- one device
attach a
check "says it attached" wait_for "$WORK/a.err" "vbridge: attached 1 front-desk"
check "ready, with the hook's last line" wait_for "$WORK/a.err" "vbridge: ready Front desk listening"
check "on-attach gets the mode and generation" grep -qx "attach front-desk 1" "$LOG"
check "the owner file names the attach" grep -qx "1 [0-9]* front-desk" "$XDG_RUNTIME_DIR/ssh-mic-bridge/owner"
printf 'mic audio' >&$FD_a
sleep 0.3
check "the mic reaches the virtual mic" grep -q "mic audio" "$WORK/vmic.raw"
check "the ready tone plays back" loud_audio a
hang_up a
check "ends when the laptop stops" exited a 0
check "says it ended" grep -q "vbridge: ended" "$WORK/a.err"
check "on-detach runs for its generation" grep -qx "detach front-desk 1" "$LOG"
check "and the owner file is gone" test ! -e "$XDG_RUNTIME_DIR/ssh-mic-bridge/owner"

# ---------------------------------------------------------------- takeover
: >"$LOG"
attach b
wait_for "$WORK/b.err" "vbridge: ready"
attach c
check "a newer attach takes over" exited b 75
check "the older one says so" grep -q "vbridge: taken over" "$WORK/b.err"
check "the newer one is ready" wait_for "$WORK/c.err" "vbridge: ready"
check "the older one's clean-up doesn't detach" bash -c "! grep -q 'detach front-desk 2' '$LOG'"
hang_up b
hang_up c
check "the newer one ends" exited c 0
check "and detaches its own generation" grep -qx "detach front-desk 3" "$LOG"

# ---------------------------------------------------------------- a hook says no
: >"$LOG"
cat >"$HOOKS/on-attach" <<HOOK
#!/bin/bash
echo "attach \$1 \$2" >>"$LOG"
echo "The front desk isn't running" >&2
exit 1
HOOK
attach d
check "a failing on-attach ends it" exited d 77
check "with the hook's reason" grep -q "vbridge: not ready: The front desk isn't running" "$WORK/d.err"
check "and cleans up with on-detach" grep -qx "detach front-desk 4" "$LOG"
hang_up d
rm "$HOOKS/on-attach"

# ---------------------------------------------------------------- idle, no hooks
VBRIDGE_IDLE_MINUTES=0.02 attach e talk
check "ready without hooks" wait_for "$WORK/e.err" "vbridge: ready"
check "ends when nobody speaks" exited e 76
check "says it went idle" grep -q "vbridge: idle" "$WORK/e.err"
hang_up e

# ---------------------------------------------------------------- refusals
check "a mode that isn't a plain word is refused" bash -c "! '$ATTACH' 'x; rm -rf ~' </dev/null 2>/dev/null"

echo "$passed passed, $failed failed"
((failed == 0))
