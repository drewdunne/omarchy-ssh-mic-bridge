#!/bin/bash

# Tests for server/vbridge-attach, two-way mode's server half, against stub pacat, parec and
# pactl and a throwaway HOME: hooks, one talker at a time, idle, the ready tone, the reply's
# reserve. Run from the repository root: bash test/vbridge.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$HOME/.config/ssh-mic-bridge/hooks" "$XDG_RUNTIME_DIR" "$WORK/bin"
HOOKS=$HOME/.config/ssh-mic-bridge/hooks
LOG=$WORK/hooks.log
ATTACH=$ROOT/server/vbridge-attach

# pacat keeps what reaches the virtual mic, and for the reply sink's silent stream notes its
# process id and reads its stdin until it closes; parec plays reply.raw once if it's there, then 20 ms of silence every
# 20 ms; pactl lists no streams and waits on subscribe.
cat >"$WORK/bin/pacat" <<STUB
#!/bin/bash
[[ " \$* " == *" --stream-name=talk-awake "* ]] && { echo \$\$ >>"$WORK/awake.log"; exec cat >/dev/null; }
exec cat >>"$WORK/vmic.raw"
STUB
cat >"$WORK/bin/parec" <<STUB
#!/usr/bin/env python3
import os, sys, time
path = "$WORK/reply.raw"
data = open(path, "rb").read() if os.path.exists(path) else b""
at = 0
while True:
    chunk = data[at:at + 1920]
    at += 1920
    sys.stdout.buffer.write(chunk + bytes(1920 - len(chunk))); sys.stdout.buffer.flush(); time.sleep(0.02)
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
   echo $? >"$WORK/$name.code") 2>/dev/null &  # quiet about the attach a test kills outright
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

# ---------------------------------------------------------------- holes in the reply
# A reply as Codex's voice helper plays it when the server's audio runs late: 1 s of silence, then
# three 300 ms words of tone, each with two 10 ms runs of exact silence in it and a quiet 150 ms
# pause after it, then silence.
python3 - "$WORK/reply.raw" <<'PY'
import array, math, sys
a = array.array("h", bytes(2 * 48000))
for word in range(3):
    for i in range(14400):
        hole = 4800 <= i < 5280 or 9600 <= i < 10080
        a.append(0 if hole else int(8000 * math.sin(2 * math.pi * 440 * i / 48000)) or 1)
    a.extend(10 if i % 2 else -10 for i in range(7200))
a.extend(array.array("h", bytes(2 * 48000)))
open(sys.argv[1], "wb").write(a.tobytes())
PY

holes() {  # holes NAME: runs of exact silence of 5 ms or more with tone on both sides, in what NAME sent back
  python3 -c '
import array, re, sys
a = array.array("h"); d = open(sys.argv[1], "rb").read(); a.frombytes(d[: len(d) // 2 * 2])
a = a[int(0.9 * 48000):]
mask = bytes(0 if v == 0 else 1 for v in a)
loud = lambda lo, hi: max((abs(v) for v in a[max(0, lo):hi]), default=0) > 1000
print(sum(1 for m in re.finditer(rb"\x00{240,}", mask) if loud(m.start() - 480, m.start()) and loud(m.end(), m.end() + 480)))' "$WORK/$1.out"
}

starts_at() {  # starts_at NAME LOW HIGH: the tone NAME sent back starts between LOW and HIGH seconds
  python3 -c '
import array, sys
a = array.array("h"); d = open(sys.argv[1], "rb").read(); a.frombytes(d[: len(d) // 2 * 2])
start = next(i for i in range(int(0.9 * 48000), len(a)) if abs(a[i]) > 1000) / 48000
sys.exit(0 if float(sys.argv[2]) <= start <= float(sys.argv[3]) else 1)' "$WORK/$1.out" "$2" "$3"
}

: >"$WORK/awake.log"
attach f talk
wait_for "$WORK/f.err" "vbridge: ready"
sleep 2.6
hang_up f
check "a reply's holes still ends cleanly" exited f 0
check "the holes in a reply are taken out" test "$(holes f)" = 0
check "the reply is held back by the reserve, 70 to 80 ms" starts_at f 1.065 1.085
check "the reply sink is kept awake while attached" test -s "$WORK/awake.log"

: >"$WORK/awake.log"
VBRIDGE_REPLY_RESERVE_MS=0 attach g talk
wait_for "$WORK/g.err" "vbridge: ready"
sleep 2.6
hang_up g
check "with no reserve it ends cleanly too" exited g 0
check "with no reserve the reply goes as it plays" test "$(holes g)" = 6
check "and isn't held back" starts_at g 0.995 1.005
check "and the reply sink isn't kept awake" test ! -s "$WORK/awake.log"
rm "$WORK/reply.raw"

: >"$WORK/awake.log"
attach h talk
wait_for "$WORK/h.err" "vbridge: ready"
wait_for "$WORK/awake.log" .
awake=$(tail -1 "$WORK/awake.log")
check "the silent stream runs while attached" kill -0 "$awake"
kill -9 "$(cut -d' ' -f2 "$XDG_RUNTIME_DIR/ssh-mic-bridge/owner")"
gone() { for _ in {1..20}; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
check "and ends when vbridge-attach is killed outright" gone "$awake"
hang_up h
rm -f "$XDG_RUNTIME_DIR/ssh-mic-bridge/owner"

# ---------------------------------------------------------------- the reserve itself
# reserve CASE: runs one case against vbridge-attach's Reserve, fed in uneven reads.
reserve() {
  python3 -B - "$ATTACH" "$1" <<'PY'
import array, importlib.machinery, importlib.util, math, sys
loader = importlib.machinery.SourceFileLoader("vbridge_attach", sys.argv[1])
vb = importlib.util.module_from_spec(importlib.util.spec_from_loader("vbridge_attach", loader))
loader.exec_module(vb)
case, RATE = sys.argv[2], 48000

def word(ms, holes=()):
    """ms of tone; holes are (start ms, length ms) of exact silence in it."""
    a = array.array("h")
    for i in range(RATE * ms // 1000):
        t = i * 1000 / RATE
        hole = any(s <= t < s + l for s, l in holes)
        a.append(0 if hole else int(8000 * math.sin(2 * math.pi * 440 * i / RATE)) or 1)
    return a

def zeros(ms):
    return array.array("h", bytes(2 * (RATE * ms // 1000)))

def quiet(ms):
    return array.array("h", (10 if i % 2 else -10 for i in range(RATE * ms // 1000)))

def run(parts, ms=80):
    a = array.array("h")
    for p in parts:
        a.extend(p)
    data, r, out, at, sizes = a.tobytes(), vb.Reserve(ms), bytearray(), 0, [1919, 1921, 1920, 7, 1913]
    while at < len(data):
        n = sizes[at % 5]
        out += r.take(data[at:at + n])
        at += n
    b = array.array("h")
    b.frombytes(bytes(out[: len(out) // 2 * 2]))
    return a, b, len(data), len(out)

def onsets(a):
    """Where each word starts: the first loud sample after at least 100 ms without one."""
    found, last = [], -RATE
    for i, v in enumerate(a):
        if abs(v) > 1000:
            if i - last > RATE // 10:
                found.append(i)
            last = i
    return found

def holes(b):
    """Runs of exact silence of 5 to 200 ms with tone on both sides."""
    n, i = 0, 0
    while i < len(b):
        if b[i] == 0:
            j = i
            while j < len(b) and b[j] == 0:
                j += 1
            if 240 <= j - i <= 9600 and i > 0 and j < len(b) and max(map(abs, b[max(0, i - 480):i])) > 1000 \
                    and max(map(abs, b[j:j + 480])) > 1000:
                n += 1
            i = j
        else:
            i += 1
    return n

loud = lambda x: [v for v in x if abs(v) > vb.QUIET]
if case == "bytes":  # as many bytes out as in, give or take a half sample still held
    a, b, n_in, n_out = run([zeros(500), word(300, [(100, 10)]), quiet(150), word(300), zeros(500)])
    sys.exit(0 if n_in - n_out in (0, 1) else 1)
if case == "speech":  # every loud sample comes out, in order, through holes, pauses and silences
    a, b, *_ = run([zeros(300), word(300, [(100, 10), (200, 20)]), quiet(120), word(250, [(50, 30)]),
                    zeros(400), word(300, [(150, 10)]), zeros(900)])
    sys.exit(0 if loud(a) == loud(b) else 1)
if case == "no-holes":  # holes the reserve can cover are gone, quiet or silent pauses between
    a, b, *_ = run([zeros(300), word(300, [(100, 10), (200, 20)]), quiet(150), word(300, [(100, 30)]),
                    zeros(250), word(300, [(50, 10), (150, 10), (250, 10)]), zeros(900)])
    sys.exit(0 if holes(a) == 6 and holes(b) == 0 else 1)
if case == "delay":  # each word starts the reserve late, after short and long silences alike
    a, b, *_ = run([zeros(300), word(300), zeros(220), word(300), zeros(600), word(300),
                    quiet(400), word(300), zeros(900)])
    lags = [(y - x) * 1000 / RATE for x, y in zip(onsets(a), onsets(b))]
    sys.exit(0 if len(lags) == 4 and all(60 <= l <= 90 for l in lags) else 1)
if case == "start":  # speech already playing at the start gets the reserve, and its holes go
    a, b, *_ = run([word(400, [(100, 10), (250, 10)]), zeros(900)])
    lag = (onsets(b)[0] - onsets(a)[0]) * 1000 / RATE
    sys.exit(0 if 70 <= lag <= 90 and holes(b) == 0 else 1)
sys.exit(2)
PY
}
check "the reserve sends as many bytes as it gets" reserve bytes
check "the reserve keeps all of the speech, in order" reserve speech
check "the reserve takes out the holes it can cover" reserve no-holes
check "the reserve keeps its delay after long silences" reserve delay
check "the reserve holds back speech that's playing as it starts" reserve start

# ---------------------------------------------------------------- refusals
check "a mode that isn't a plain word is refused" bash -c "! '$ATTACH' 'x; rm -rf ~' </dev/null 2>/dev/null"

echo "$passed passed, $failed failed"
((failed == 0))
