#!/bin/bash

# Tests for ./setup install and uninstall, and for mic matching, against a
# throwaway HOME with stub hyprctl/omarchy commands. Uses Omarchy's stock
# config files when they are installed. Run from the repository root:
# bash test/setup.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
PLUGIN="$HOME/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/extensions" "$WORK/bin" "$(dirname "$PLUGIN")"
cp -r "$ROOT" "$PLUGIN"

# Stub commands record how they were called. pactl serves a fixed list of
# sources, so mic matching runs the same on any machine.
for command in hyprctl omarchy omarchy-shell; do
  cat >"$WORK/bin/$command" <<STUB
#!/bin/bash
echo "$command \$*" >>"$WORK/calls"
STUB
  chmod +x "$WORK/bin/$command"
done
cat >"$WORK/bin/pactl" <<'STUB'
#!/bin/bash
case "$*" in
  "-f json list sources") cat <<'JSON'
[{"name":"alsa_output.usb-Desk-00.analog-stereo.monitor","description":"Monitor of Desk Speakers"},
 {"name":"alsa_input.usb-Blue_Yeti-00.analog-stereo","description":"Yeti Stereo Microphone"},
 {"name":"alsa_input.usb-Desk-00.HiFi__Mic1__source","description":"Desk Mic 1"},
 {"name":"alsa_input.usb-Desk-00.HiFi__Mic2__source","description":"Desk Mic 2"}]
JSON
  ;;
  get-default-source) echo alsa_input.usb-Desk-00.HiFi__Mic1__source ;;
esac
STUB
chmod +x "$WORK/bin/pactl"
export PATH="$WORK/bin:$PATH"

HYPR="$HOME/.config/hypr/hyprland.lua"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f /usr/share/omarchy/config/hypr/hyprland.lua ]]; then
  cp /usr/share/omarchy/config/hypr/hyprland.lua "$HYPR"
else
  printf '%s\n' 'require("default.hypr.omarchy")' '' 'require("hypr.bindings")' >"$HYPR"
fi
if [[ -f /usr/share/omarchy/config/omarchy/extensions/omarchy-menu.jsonc ]]; then
  cp /usr/share/omarchy/config/omarchy/extensions/omarchy-menu.jsonc "$MENU"
else
  printf '{\n  // "personal": {"label":"Personal"},\n}\n' >"$MENU"
fi
cp "$HYPR" "$WORK/original.lua"
cp "$MENU" "$WORK/original.jsonc"

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

resolves() {  # resolves WANT EXPECTED-SOURCE
  [[ $("$PLUGIN/bin/ssh-mic-bridge" which "$1" 2>/dev/null) == "$2" ]]
}

no_match() {
  ! "$PLUGIN/bin/ssh-mic-bridge" which "$1" >/dev/null 2>&1
}

# Omarchy's menu drops whole-line // comments and trailing commas, then parses
# JSON. Do the same here, without node.
menu_parses() {
  python3 - "$MENU" <<'PY'
import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"(?m)^\s*//[^\n]*(\n|$)", "", raw)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
items = json.loads(raw)
want = {"trigger.ssh-mic-bridge", "trigger.ssh-mic-bridge.start", "trigger.ssh-mic-bridge.stop",
        "trigger.ssh-mic-bridge.pick", "trigger.ssh-mic-bridge.test", "trigger.ssh-mic-bridge.server"}
sys.exit(0 if want <= set(items) else 1)
PY
}

# ---------------------------------------------------------------- mic matching
check "default is the system default" resolves default alsa_input.usb-Desk-00.HiFi__Mic1__source
check "exact source name" resolves alsa_input.usb-Blue_Yeti-00.analog-stereo alsa_input.usb-Blue_Yeti-00.analog-stereo
check "exact description" resolves "Desk Mic 2" alsa_input.usb-Desk-00.HiFi__Mic2__source
check "part of a name, any case" resolves yeti alsa_input.usb-Blue_Yeti-00.analog-stereo
check "ambiguous name is refused" no_match "desk mic"
check "unknown name is refused" no_match "rode"
check "monitors are not mics" no_match "speakers"

# ---------------------------------------------------------------- install
bash "$PLUGIN/setup" install --yes >/dev/null
check "hyprland.lua gets the loader" grep -qF -- "-- >>> gg.arkship.ssh-mic-bridge >>>" "$HYPR"
check "loader comes after Omarchy's defaults" awk '/require\("default.hypr.omarchy"\)/ { d = NR } /gg.arkship.ssh-mic-bridge >>>/ { exit !(d && NR > d) }' "$HYPR"
check "menu block parses" menu_parses
check "command is linked" test -L "$HOME/.local/bin/ssh-mic-bridge"
check "widget is enabled" grep -q "omarchy plugin enable gg.arkship.ssh-mic-bridge" "$WORK/calls"
check "Hyprland is reloaded" grep -q "hyprctl reload" "$WORK/calls"

cp "$HYPR" "$WORK/once.lua"
cp "$MENU" "$WORK/once.jsonc"
bash "$PLUGIN/setup" install --yes >/dev/null
check "install twice changes nothing" cmp -s "$WORK/once.lua" "$HYPR"
check "menu twice changes nothing" cmp -s "$WORK/once.jsonc" "$MENU"

# ---------------------------------------------------------------- uninstall
bash "$PLUGIN/setup" uninstall --yes >/dev/null
check "uninstall restores hyprland.lua" cmp -s "$WORK/original.lua" "$HYPR"
check "uninstall restores the menu" cmp -s "$WORK/original.jsonc" "$MENU"
check "uninstall removes the link" test ! -e "$HOME/.local/bin/ssh-mic-bridge"
check "uninstall disables the widget" grep -q "omarchy plugin disable gg.arkship.ssh-mic-bridge" "$WORK/calls"

echo "$passed passed, $failed failed"
((failed == 0))
