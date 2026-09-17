# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo install -m 755 .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

### Upgrading

Same three steps, plus a restart if you run the LaunchAgent:

```sh
git pull
swift build -c release
sudo install -m 755 .build/release/quill /usr/local/bin/quill
launchctl kickstart -k gui/$(id -u)/com.digimata.quill   # if installed
```

Use `install`, not `cp`. See the gotcha below — `cp` produces a binary that
macOS kills on sight.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v3**
via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port —
roughly 20 seconds per hour of audio on Apple Silicon. It covers 25 European
languages and detects as it goes, so a meeting that switches between French and
English transcribes correctly without being told. Models (~470 MB) download
once on first transcription; `quill doctor` tells you whether they're already
cached so you're never downloading after an important meeting.

Set `transcription.language` to a two-letter code to hint the decoder when you
know the language in advance. `"en"` is special: it selects **Parakeet TDT
0.6B v2**, the dedicated English-only model.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option for
languages Parakeet v3 doesn't cover.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet", "language": "auto" },
  "on_stop": "my-hook",
  "hotkeys": { "toggle_recording": "cmd+opt+ctrl+r" }
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.language` — two-letter code for the language spoken in the
  meeting. Default `"auto"`: the multilingual v3 model with no hint, which
  handles bilingual meetings. Naming one of v3's 25 European languages — `fr`,
  `es`, `de`, `it`, `pt`, `nl`, `pl`, `ru`, `uk`, `el` and the rest — hints the
  decoder. `"en"` selects the English-only v2 model instead. An unrecognized
  code warns and falls back to `"auto"`.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.
- `hotkeys.toggle_recording` — global keyboard shortcut that starts/stops
  recording from anywhere in macOS, no menu click needed. Default
  `cmd+opt+ctrl+r`. Combos: any of `cmd`/`shift`/`opt`/`ctrl` plus a letter,
  digit, `space`, `tab`, `return`, `escape`, `delete`, or `f1`–`f12`, joined
  with `+` (e.g. `ctrl+opt+space`). Set to `""` to disable. If the combo is
  already claimed by another app, quill logs a warning to stderr and runs
  without it — the menu still works.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Upgrading with `sudo cp` produces a binary that dies instantly with exit 137
  (SIGKILL) and no output. `cp` writes through the existing inode, and the
  kernel still has the *old* contents' code signature cached against it, so
  every exec fails the hash check and AMFI kills the process. The binary is
  fine — `codesign -v` passes and it runs from the build directory. Use
  `install`, which writes a temp file and renames it into place, so the new
  contents land on a new inode. `sudo rm` before `sudo cp` works too.
- Setting `transcription.language` to `"en"` opts into the English-only v2
  model, which fails quietly on everything else — it transcribes French
  phonetically into English-looking nonsense rather than erroring. Leave the
  default `"auto"` unless every meeting is English.
- Switching `transcription.language` between `"en"` and anything else changes
  the model, so the first recording after the switch downloads ~470 MB.
  `quill doctor` reports whether the model for the configured language is
  cached; record a short throwaway session while online to warm it.
- Detecting a live call from outside quill: use the meeting app's own network
  state, not the microphone. Zoom holds UDP sockets to an external media server
  on port 8801 for a call's whole duration and none outside one, so
  `lsof -nP -iUDP -a -c zoom.us | grep -- '->.*:8801'` is a clean in-call
  signal — measured at 5–8 sockets during a call and zero within two seconds of
  leaving it. Zoom's other UDP sockets are unconnected LAN-discovery ones with
  no remote peer, hence matching on the remote address. CoreAudio's
  `kAudioDevicePropertyDeviceIsRunningSomewhere` looks like the better answer
  and is not: quill's own `MicRecorder` claims the default input, so once
  recording starts the mic reads as live whatever the meeting app does. On a
  measured call it stayed live for 70 seconds after the call ended. A
  mic-based detector can see a meeting start and can never see one end.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
