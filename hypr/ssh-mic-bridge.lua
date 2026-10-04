-- SSH Mic Bridge: SUPER + ALT + V starts or stops streaming your mic to the
-- server. Loaded from ~/.config/hypr/hyprland.lua by `setup install`, before
-- ~/.config/hypr/bindings.lua, so you can move it there:
--   hl.unbind("SUPER + ALT + V")
--   o.bind("SUPER + F12", "Mic to server", "ssh-mic-bridge toggle")

local ctl = (os.getenv("HOME") or "") .. "/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/bin/ssh-mic-bridge"

o.bind("SUPER + ALT + V", "SSH Mic Bridge: stream mic to server", o.shell_quote(ctl) .. " toggle")
