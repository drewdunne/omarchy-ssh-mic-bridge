# SSH Mic Bridge

An [Omarchy](https://omarchy.org/) plugin that streams your microphone over
SSH into a virtual mic on a server. Apps on the server that record the default
mic hear you as if the mic were plugged in there.

It was built for Claude Code's `/voice`. Dictation records the machine Claude
runs on, so it can't hear you when Claude runs over SSH on a server. With the
bridge on, it can. Any recording app on the server works the same way.

```
your mic -> parec -> ssh you@server -> pacat -> vmic -> vmic_mic (server's default input)
```

## What you get

| Where | What |
|---|---|
| SUPER + ALT + V | Start or stop streaming |
| Bar mic, left click | Start or stop streaming |
| Bar mic, middle click | Choose a microphone |
| Bar mic, right click | Trigger > SSH Mic Bridge |
| Trigger > SSH Mic Bridge | Start, Stop, Choose Microphone, Hear What the Server Hears, Set Up Server |

The bar mic is dim and crossed out when off, and lit while streaming. Its
tooltip names the mic and the server.

## Requirements

- **This machine:** Omarchy 4 (Hyprland 0.56+ with Lua config, PipeWire), and
  SSH access to the server.
- **Server:** Linux with a systemd user session, `python3`, and a PulseAudio
  server that `pactl` can reach. PipeWire's `pipewire-pulse` is the usual one,
  and plain PulseAudio works too. No GUI and no open ports are needed.

## Install

```bash
omarchy plugin add https://github.com/drewdunne/omarchy-ssh-mic-bridge.git --yes
~/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/setup install
~/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/setup server you@server
```

`setup install` asks before changing anything. It backs up and adds a small
marked block to `~/.config/hypr/hyprland.lua` (the keybinding) and to
`~/.config/omarchy/extensions/omarchy-menu.jsonc` (the menu). It also links
`ssh-mic-bridge` into `~/.local/bin` and adds the bar widget next to the
volume control.

`setup server` checks the server and asks before installing its half:
`vmic-keepalive` and a user service for it. It then makes the virtual mic the
server's default input. If the server lacks something, it tells you what to
install and stops. It never runs sudo.

## Choose a microphone

Middle-click the bar mic, or pick Trigger > SSH Mic Bridge > Choose
Microphone. Every input on this machine is listed by name, and picking one
starts streaming from it. From a terminal, name it:

```bash
ssh-mic-bridge mics               # list them
ssh-mic-bridge mic "Yeti"         # any part of a mic's name, ignoring case
ssh-mic-bridge mic default        # follow the system default input
ssh-mic-bridge which              # the device that would be streamed
```

A name has to match exactly one mic. "Desk" won't do when there are "Desk Mic
1" and "Desk Mic 2"; the error lists them. The choice is saved by its name, so
it still works when a sound card switches profiles and its devices get new IDs.

Pick an input that carries only your voice. Some audio interfaces also offer
mixes (like a GoXLR's "Stream Mix") that add music or game audio. Streaming
every channel of a multichannel interface can comb-filter your voice.

## Settings

`~/.config/ssh-mic-bridge/config`, written by the commands above and fine to
edit:

```bash
SSH_MIC_BRIDGE_HOST=you@server   # where the virtual mic lives
SSH_MIC_BRIDGE_MIC=Yeti          # default, a source name, or part of a mic's name
```

To use a different key, edit `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + ALT + V")
o.bind("SUPER + F12", "Mic to server", "ssh-mic-bridge toggle")
```

## How it works

**Locally:** `ssh-mic-bridge start` runs the stream as the transient user unit
`ssh-mic-bridge.service`, so it survives shell and Hyprland restarts. It
captures your mic with `parec` (s16le, 48 kHz, mono) and pipes it into
`ssh you@server pacat --playback --device=vmic`. A dropped connection is
retried every 3 s, at most 5 times a minute. The capture stream has its own
client name, so a mute that WirePlumber stored for another app never applies
to it, and the bridge unmutes it once it starts.

**On the server:** `vmic-keepalive` creates a null sink `vmic`, remaps its
monitor as the source `vmic_mic`, and makes that the default input. It also
plays a faint, continuously fresh noise floor into it, about -52 dBFS.
Without that, the virtual mic is digital silence between words, and
speech-to-text services (Claude Code uses Deepgram) reject a silent source as
"No speech detected". A real mic always carries some room noise. The floor is
generated fresh every 50 ms, because repeating one block of noise turns it
into an audible hum.

**SSH:** the stream runs in the background with `BatchMode`, so SSH must work
without a prompt. If your key has a passphrase and the agent is empty (after a
reboot, say), starting opens a small terminal where ssh asks for it once.
`AddKeysToAgent` then keeps the key for the stream.

## Check and troubleshoot

```bash
~/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/setup status   # this machine and the server, read-only
ssh-mic-bridge test   # record what reaches the server, show its level, play it back
ssh-mic-bridge log    # this boot's log
```

| Symptom | Fix |
|---|---|
| "Failed to start", Permission denied (publickey) | Run `ssh you@server` once in a terminal, or start again and type the passphrase in the terminal that opens |
| "No virtual mic on the server" | `setup server` |
| Transcript empty, "No speech detected" | `setup status`: vmic.monitor must be RUNNING and the default input vmic_mic |
| The server hears only a flat -52 dBFS in `test` | Only the noise floor arrives: is your mic muted, or the wrong one chosen? (`ssh-mic-bridge which`) |
| It keeps reconnecting, then stops | The server or the network is down: `ssh-mic-bridge log` |

Something else on the server that changes its default input breaks the
bridge. `vmic-keepalive` sets it on every start, so
`systemctl --user restart vmic-keepalive` there puts it back.

## Uninstall

```bash
~/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/setup server --remove   # the server half
~/.config/omarchy/plugins/gg.arkship.ssh-mic-bridge/setup uninstall
omarchy plugin remove gg.arkship.ssh-mic-bridge
```

`~/.config/ssh-mic-bridge/config` stays until you delete it.

## Development

```bash
bash test/setup.sh             # setup and mic matching against a throwaway HOME
omarchy plugin validate .
```

Saved changes to `SshMicBridge.qml` reload the bar automatically. After
editing `hypr/ssh-mic-bridge.lua`, run `hyprctl reload`.

## Related projects

- [voxtunnel](https://github.com/remmmi/voxtunnel): a tray app that streams a
  mic over SSH into an ALSA loopback device on the server.
- [claude-voice-tunnel](https://github.com/omcnoe/claude-voice-tunnel):
  Claude `/voice` over an SSH-forwarded TCP port into a PipeWire null sink.
- [echocast](https://github.com/hexploder/echocast): an Omarchy widget for the
  other direction, sending your audio to another machine's speakers over SSH.

## License

[MIT](LICENSE)
