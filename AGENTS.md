# Working on IslandBar

IslandBar is a menu-bar Now Playing visualizer for Apple Silicon Macs (macOS 15.4+), built with
SwiftPM and the Command Line Tools — no Xcode project. [README.md](README.md) describes what it
does for users; [PITFALLS.md](PITFALLS.md) is the list of traps that already cost real time.
Read the PITFALLS section for whatever you are about to touch before you touch it.

Every push to `main` ships to real people's Macs (see [Releases](#releases)). A change is
finished when it has been **seen working in the real app** — and, for anything that changes how
the app is built or packaged, **seen working as CI builds it** — not when it compiles.

## Rules learned the hard way

Each of these cost a broken release or an hour on 2026-10-04. They are not style preferences.

1. **Verify the outcome, not the step.** `tap created` is not audio flowing (an unanswered
   permission prompt yields a tap that never calls back); `open … -> 0` is not an app running
   (`open ""` also returns 0); a local build launching is not the release launching. Assert on
   the thing a user would notice: `samplesRead>0`, the process is up, the marker was written.
2. **Make every new check fail once before you trust its PASS.** Run it against the known-bad
   case — `Scripts/launch-smoke.sh` was proven against the broken v0.5.0 archive, the update
   scenario against a release that exits at launch. A check that has never failed may be
   asserting nothing (one draft of the harness compared against the wrong folder and always
   passed).
3. **Your toolchain is not CI's.** The runner builds the release with an older Swift that
   packages resources differently, so "works on my Mac" proved nothing for v0.5.0, which crashed
   at launch everywhere else. Touching `build.sh`, `Package.swift`, `Vendor/`, resources or the
   launch path means a CI dry run before release (below).
4. **A release cannot be recalled from users' disks.** Pulling it from the feed stops new
   installs only. That is why releases are gated (launch smoke on the runner) and why installed
   copies put an update on probation and roll it back if it does not come up
   (`Updates/UpdateProbation.swift`). Do not weaken either without replacing it.
5. **Leave the user's machine as you found it.** Anything global you touch — the keychain search
   list, `defaults`, running apps, TCC — is saved first and restored after, in a script that
   restores on failure too. A zsh one-liner once replaced the keychain search list with one
   bogus path (PITFALLS.md, "An untrusted signing identity…").
6. **Nobody is at the Mac.** DiveMac runs with its lid closed; prompts time out unanswered after
   ~90 s and screenshots come back black. Plan for zero clicks; when one is unavoidable, stop
   and ask for exactly that click, with where to find it.
7. **Say what you did not verify.** If a check was skipped, blocked (exit 3) or only run
   locally, the report says so in so many words.

## Layout

| Path | What |
| --- | --- |
| `Sources/IslandBar/App` | `AppDelegate` (wires everything, watches the store), debug log, relaunch watchdog |
| `Sources/IslandBar/Audio` | process tap (`ProcessAudioTap.swift`: `TapController` owns the tap lifecycle), process registry, output volume |
| `Sources/IslandBar/Mixer` | per-app volume (muted taps re-rendered at a gain) |
| `Sources/IslandBar/NowPlaying` | MediaRemote session, browser-tab fallback, artwork palette |
| `Sources/IslandBar/StatusItem` | the pill, its slot, `MenuBarAutoHide` (is the menu bar hidden / revealed) |
| `Sources/IslandBar/Popover` | the sound card |
| `Sources/IslandBar/Updates` | self-update: feed, signature, install, and the probation/rollback after relaunch |
| `Vendor/MediaRemoteAdapter` | vendored MediaRemote bridge; local patches are marked `PATCH (IslandBar)` |
| `Scripts/harness` | build, drive and check the running app (below) |
| `Scripts/launch-smoke.sh` | launch a packaged app away from `.build`; release.sh gates on it |
| `Scripts/dev-signing.sh` | stable signing identity for local builds |
| `Scripts/release.sh` | the one release path, by hand or from CI |
| `Tools/Harness` | the harness's Swift helpers: a test player and a notification poster |

## Verify your work with the harness

`Scripts/harness` runs the real app — through LaunchServices, with `ISLANDBAR_DEBUG=1` — and
drives it the way a person would, without needing anyone at the Mac:

```bash
Scripts/harness build          # ./build.sh, then launch the new build with debug hooks on
Scripts/harness check          # every scenario (≈4 min)
Scripts/harness check menubar  # or just the ones you touched
Scripts/harness restore        # when done: quit, relaunch whatever copy was running before
```

| Scenario | Covers | Run it when you touch |
| --- | --- | --- |
| `smoke` | app is up with debug hooks | anything |
| `playback` | Now Playing → tap → audio flowing → bars moving | Audio, NowPlaying, Visualizer, AppDelegate |
| `pause` | capture stops on pause and comes back | Audio, NowPlaying |
| `menubar` | capture suspends while the menu bar is hidden; pacing of repeat reveals | StatusItem, Audio |
| `card` | the open card keeps capture on | Popover, StatusItem |
| `switch` | another app taking over Now Playing gets its own tap without waiting out the old backoff | Audio, NowPlaying |
| `packaging` | the built app launches away from `.build` | build.sh, Package.swift, Vendor, resources |
| `update` | a release that cannot start is rolled back and skipped; a good one is kept | Updates, App launch path |

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
| `shot menubar\|card [file]` | screenshot (read the PNG to look at it; black means the Mac is locked) |
| `status` | what is running, its signature, whether capture is blocked |
| `permission` | raise the System Audio Recording prompt and wait until audio actually flows |

The debug hooks behind `menubar`, `card` and `state` are distributed notifications that the app
only honours under `ISLANDBAR_DEBUG=1` (`IslandBarID` in `App/main.swift`). The update scenario
uses the updater's own test overrides (`ISLANDBAR_UPDATE_FEED_URL` with a `file://` feed,
`ISLANDBAR_UPDATE_PUBLIC_KEY`, `ISLANDBAR_UPDATE_AUTO_INSTALL`, `ISLANDBAR_UPDATE_PROBATION`),
all honoured only together with a feed override, so none can fire against the real feed.

**When you add behaviour, add a scenario.** Scenarios are shell functions named `check_<name>`
in `Scripts/harness`: `mark` the log, act (`player_cmd`, `post`), then `wait_for '<regex>'
<seconds>` and/or assert on `state_field <name>` (which moves the mark — `mark` again after it).
If the behaviour is not visible in the log, add a `DebugLog.line` for it — the log is the
harness's eyes, and a precise line (`capture engine stopped reason=menu-bar-hidden`) makes a
precise assertion. Register the name in `run_checks`, add it to the table above, and make it
fail once (rule 2).

### What still needs a person

- **System Audio Recording, once per Mac.** A process tap needs it, and until someone clicks
  Allow the tap queue sits inside `AudioDeviceCreateIOProcIDWithBlock` (the harness detects this
  and exits 3). Local builds are signed with a stable development identity
  (`Scripts/dev-signing.sh setup`, done on DiveMac; not on Macintosh), so one grant survives
  every rebuild. Without the identity, builds are ad-hoc and *every* rebuild needs the click.
  `Scripts/harness permission` raises the prompt with a silent player, re-raises it every two
  minutes, and succeeds only when samples flow. If you are blocked, say so and ask: the person
  Screen Shares in and clicks Allow, or — with no time limit — adds `dist/IslandBar.app` under
  System Settings › Privacy & Security › Screen & System Audio Recording › System Audio
  Recording Only. Do not edit TCC.db or work around it.
- **Real full screen.** macOS will not let a background process take focus, so the test player
  cannot put itself into full screen (`player fullscreen` logs whether it worked). The `menubar`
  hook covers everything downstream of `MenuBarAutoHide`; only its *detection* of a full-screen
  space needs a human click on the player's window.
- **Sound.** The test tone is quiet, and DiveMac's output is usually at 0. Capture does not care
  — a tap reads what a process sends, before the system volume.

### Rules for driving the app

- Launch through LaunchServices (`open`, or the harness), never by running the binary from a
  shell: the shell becomes the TCC "responsible process" and the tap is denied. (The launch
  smoke is the one exception: it checks that the app starts, not that it may capture.)
- Do not leave things running on the user's Mac: `Scripts/harness restore` at the end.
- Shell scripts here are bash under `set -euo pipefail`. Never `producer | grep -q` or `| head`
  — the early exit SIGPIPEs the producer and pipefail turns a match into a failure; grep a file.
  Inside a shell function `$1…$9` are the function's own arguments — name the script's
  arguments once at the top. `defaults read` wants an absolute path to a plist, or it reads a
  preferences domain of that name and says the key "does not exist".

## Releases

**A push to `main` is a release.** `.github/workflows/release.yml` runs on every push, bumps the
patch of the newest `vX.Y.Z` tag, and calls `Scripts/release.sh`, which stamps `Info.plist`,
builds ad-hoc, zips, **launches the extracted zip on the runner with `.build` moved aside**
(`launch-smoke.sh`; no launch, no release), signs the zip with the Ed25519 update key (the
`ISLANDBAR_SIGNING_KEY` secret), commits `Release vX.Y.Z [skip ci]`, tags, pushes and publishes.
Installed copies find it within six hours and offer it to the user.

Three layers stand between a bad build and a stranded user, and a change to any of them needs
its scenario re-run:

| Layer | Where | Catches |
| --- | --- | --- |
| launch smoke on the runner | `release.sh` → `launch-smoke.sh` | an archive that cannot start where it was built for |
| update probation | `UpdateProbation.swift`, the helper in `UpdateController.relaunch` | anything that still fails to start on a user's Mac: put back, skipped, user told |
| the feed | GitHub `releases/latest` skips prereleases | pulling a bad release while a fix is cut |

Before pushing:

1. `swift build` is clean and `Scripts/harness check` passes for what you touched (or every
   failure is understood and reported).
2. If the build, packaging, `Package.swift`, `Vendor/`, resources or the launch path changed:
   push with `[skip ci]`, run `gh workflow run release.yml -f dry_run=true`, and `gh run watch`
   it to green. It builds, smokes and signs on the runner and publishes nothing.
3. README/PITFALLS describe what changed. Commit subjects are the release notes — write them for
   the people installing the update, and keep `[skip ci]` in the body, not the subject.
4. Ask before pushing unless the user asked for a release: a push is a publication.

Versions: a feature is a minor (`[skip ci]` on the push, then
`gh workflow run release.yml -f version=X.Y.0`); a fix is the automatic patch. Docs- or
harness-only pushes that should not ship carry `[skip ci]`. Releases are always ad-hoc signed
(`ISLANDBAR_ADHOC=1`), never with the development identity. Key rotation takes two releases;
`release.sh` enforces it (PITFALLS.md, "A release key must ship before it signs anything").

After publishing, verify what users get, not what CI said: `gh release download`, check the
signature (`swift Tools/update-signing.swift verify`), `codesign --verify --deep --strict`, the
version, and `Scripts/launch-smoke.sh` on the extracted app.

### If a bad release is out

1. Pull it from the feed at once: `gh release edit vX.Y.Z --prerelease --latest=false`, then
   confirm `gh api repos/MCMike0399/IslandBar/releases/latest -q .tag_name` shows the previous
   one. Do not delete the release or its tag — the version number is burned either way.
2. Reproduce on the published artifact (`gh release download`), not on a local build.
3. Fix forward with a patch release through the dry run above. Copies that took the bad release
   roll back by themselves if it cannot start (from 0.5.2 on); copies whose updater is broken
   need the new version installed by hand — say so to the user.
4. Write the trap into PITFALLS.md and, if a check should have caught it, add that check and
   make it fail against the bad artifact.

## Writing things down

A trap that took real debugging goes in PITFALLS.md under its area, with how to recognise it
and how to check it. User-visible behaviour goes in README.md. A new rule of the kind above
goes in "Rules learned the hard way". Match the surrounding prose and comment density; comments
here explain *why*, with the measurement that justified it.
