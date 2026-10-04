# Working on IslandBar

IslandBar is a menu-bar Now Playing visualizer for Apple Silicon Macs (macOS 15.4+), built with
SwiftPM and the Command Line Tools — no Xcode project. [README.md](README.md) describes what it
does for users; [PITFALLS.md](PITFALLS.md) is the list of traps that already cost real time.
Read the PITFALLS section for whatever you are about to touch before you touch it.

Every push to `main` ships to users (see [Releases](#releases)), so a change is finished when it
has been **seen working in the real app**, not when it compiles. The harness below is how.

## Layout

| Path | What |
| --- | --- |
| `Sources/IslandBar/App` | `AppDelegate` (wires everything, watches the store), debug log, relaunch watchdog |
| `Sources/IslandBar/Audio` | process tap (`ProcessAudioTap.swift`: `TapController` owns the tap lifecycle), process registry, output volume |
| `Sources/IslandBar/Mixer` | per-app volume (muted taps re-rendered at a gain) |
| `Sources/IslandBar/NowPlaying` | MediaRemote session, browser-tab fallback, artwork palette |
| `Sources/IslandBar/StatusItem` | the pill, its slot, `MenuBarAutoHide` (is the menu bar hidden / revealed) |
| `Sources/IslandBar/Popover` | the sound card |
| `Sources/IslandBar/Updates` | self-update from GitHub Releases |
| `Scripts/harness` | build, drive and check the running app (below) |
| `Scripts/dev-signing.sh` | stable signing identity for local builds |
| `Scripts/release.sh` | the one release path, by hand or from CI |
| `Tools/Harness` | the harness's Swift helpers: a test player and a notification poster |

## Verify your work with the harness

`Scripts/harness` runs the real app — through LaunchServices, with `ISLANDBAR_DEBUG=1` — and
drives it the way a person would, without needing anyone at the Mac:

```bash
Scripts/harness build          # ./build.sh, then launch the new build with debug hooks on
Scripts/harness check          # every scenario: smoke playback pause menubar card
Scripts/harness check menubar  # or just the ones you touched
Scripts/harness restore        # when done: quit, relaunch whatever copy was running before
```

`check` prints one `PASS`/`FAIL` line per assertion and exits 0 (all passed), 1 (something
failed), 2 (usage) or **3 (blocked on a person — see below)**. Report failures as failures, with
the output; do not paraphrase a `FAIL` into "mostly works".

To look around by hand:

| Command | Does |
| --- | --- |
| `player start [title]` | launch the test player: a quiet generated tone with a real Now Playing session |
| `player play\|pause\|quit` | drive it (MediaRemote sees exactly what it would from Music or a browser) |
| `menubar hidden\|revealed\|auto` | pin the menu-bar reading: `hidden` = full screen with the pointer away, `revealed` = pointer at the top; `auto` goes back to reading the screen |
| `card` | open/close the sound card |
| `state` | the app's internal state, one `state app/menubar/tap …` line each |
| `log [n]` | the debug log without the per-second level lines |
| `shot menubar\|card [file]` | screenshot (read the PNG to look at it) |
| `status` | what is running, its signature, whether capture is blocked |

The debug hooks behind `menubar`, `card` and `state` are distributed notifications that the app
only honours under `ISLANDBAR_DEBUG=1` (`IslandBarID` in `App/main.swift`).

**When you add behaviour, add a scenario.** Scenarios are shell functions named `check_<name>`
in `Scripts/harness`: `mark` the log, act (`player_cmd`, `post`), then `wait_for '<regex>'
<seconds>` and/or assert on `state_field <name>`. If the behaviour is not visible in the log,
add a `DebugLog.line` for it — the log is the harness's eyes, and a precise line (`capture engine
stopped reason=menu-bar-hidden`) makes a precise assertion. Register the name in `run_checks`.

### What still needs a person

- **System Audio Recording, once per Mac.** A process tap needs it, and until someone clicks
  Allow the tap queue sits inside `AudioDeviceCreateIOProcIDWithBlock` (the harness detects this
  and exits 3). Local builds are signed with a stable development identity
  (`Scripts/dev-signing.sh setup`, already done on DiveMac), so one grant survives every
  rebuild. Without the identity, builds are ad-hoc and *every* rebuild needs the click again.
  `Scripts/harness permission` raises the prompt with a silent player, re-raises it every two
  minutes (an unanswered prompt gives up after ~90 s), and succeeds only when samples flow.
  If you are blocked, say so and ask for the click — DiveMac normally runs with its lid closed,
  so the person has to Screen Share in, or add `dist/IslandBar.app` under System Settings ›
  Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, which
  has no time limit. Do not try to edit TCC.db or work around it.
- **Real full screen.** macOS will not let a background process take focus, so the test player
  cannot put itself into full screen on its own (`player fullscreen` logs whether it worked). The
  `menubar` hook covers everything downstream of `MenuBarAutoHide`; only its *detection* of a
  full-screen space needs a human click on the player's window.
- **Sound.** The test tone is quiet, and DiveMac's output is usually at 0. Capture does not care
  — a tap reads what a process sends, before the system volume.

### Rules for driving the app

- Launch through LaunchServices (`open`, or the harness), never by running the binary from a
  shell: the shell becomes the TCC "responsible process" and the tap is denied.
- Do not leave things running on the user's Mac: `Scripts/harness restore` at the end.
- Shell scripts here run under `set -euo pipefail`; never `producer | grep -q` or `| head` — the
  early exit SIGPIPEs the producer and pipefail turns a match into a failure. Grep a file.

## Releases

**A push to `main` is a release.** `.github/workflows/release.yml` runs on every push, bumps the
patch of the newest `vX.Y.Z` tag, and calls `Scripts/release.sh`, which stamps `Info.plist`,
builds ad-hoc, zips, signs the zip with the Ed25519 update key (the `ISLANDBAR_SIGNING_KEY`
secret), commits `Release vX.Y.Z [skip ci]`, tags, pushes and publishes the GitHub release.
Installed copies find it within six hours and offer it to the user.

- Release notes are one bullet per commit since the last tag, so **commit subjects are
  user-facing**: write them for the people installing the update.
- Before pushing: `swift build` is clean, `Scripts/harness check` passes (or every failure is
  understood and reported), and README/PITFALLS describe what changed.
- A minor or major version: push with `[skip ci]` in the last commit's message, then
  `gh workflow run release.yml -f version=X.Y.0` and watch it with `gh run watch`.
- Docs-only or harness-only pushes that should not ship: `[skip ci]`.
- Releases are always ad-hoc signed (`ISLANDBAR_ADHOC=1`), never with the development identity.
- Key rotation takes two releases; `release.sh` enforces it. PITFALLS.md, "A release key must
  ship before it signs anything".

## Writing things down

A trap that took real debugging goes in PITFALLS.md under its area, with how to recognise it
and how to check it. User-visible behaviour goes in README.md. Match the surrounding prose and
comment density; comments here explain *why*, with the measurement that justified it.
