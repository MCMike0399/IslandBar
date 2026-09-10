# IslandBar

Menu-bar Now Playing visualizer for Apple Silicon Macs: a compact Dynamic Island pill (twelve artwork-tinted bars, tall at the edges and lower in the middle) that dances only while media plays.

macOS 15.4+, unsandboxed. Built with SwiftPM and Command Line Tools — no Xcode project.

## Build and run

```bash
cd /Users/burbujamc/Developer/IslandBar
./build.sh
open dist/IslandBar.app
```

`./build.sh --run` rebuilds, replaces a running instance, and opens the app. With `ISLANDBAR_DEBUG=1` in the environment it launches the new instance with debug logging.

## Permissions

The first time a track plays, macOS asks for **System Audio Recording** so the process tap can drive the bars. Audio is never saved.

Signing is **ad-hoc**. TCC keys the grant to the binary’s cdhash, which changes on every rebuild, so expect **one permission prompt per fresh build**. The entitlements disable library validation so the ad-hoc `libMediaRemoteAdapter.dylib` can load under the hardened runtime (ad-hoc binaries have no Team ID).

Debug logging (state transitions and per-second band levels):

```bash
mkdir -p ~/Library/Logs/IslandBar
ISLANDBAR_DEBUG=1 dist/IslandBar.app/Contents/MacOS/IslandBar
```

`ISLANDBAR_FORCE_PROCEDURAL=1` skips the tap and uses the fallback motion (also used when capture is denied).

## Usage

Left-click the pill to expand (artwork, title, transport). Right-click for Launch at Login, Settings, Check for Updates, and Quit. The pill is always visible: while nothing is playing the bars collapse to a flat gray line.

Bar colours come from the artwork: pixels are clustered in Oklab (k-means, plus a separate pass over the colourful pixels so a small accent on a dark cover is not averaged away) and the four most distinct dominant colours are ordered by hue and interpolated into a gradient across the bars. The runner-up colours are pulled halfway towards the dominant one, so the gradient reads as a single tint with a soft shift rather than a rainbow. Hue is kept; lightness is lifted and chroma is clamped to a pastel range for legibility on the black pill, and greyscale art gives grey bars. Before artwork arrives the bars show a lavender-to-mist default.

### Browser tabs

Some browsers publish a Now Playing entry with no title and no artwork (Arc does this from its mini player), which used to leave the card saying just "Arc". When a session from a scriptable browser (Arc, Chrome, Brave, Edge, Vivaldi, Chromium, Opera, Safari) arrives without a title, IslandBar asks the browser for its tabs over Apple Events — a fast check every 4 seconds for the first 12 seconds after a Now Playing event, then every 15 seconds (30 while paused), because each poll is an `osascript` child plus an Apple Event to the browser — picks the tab on a known media site (preferring the active tab right after a Now Playing event, then sticking with the previous pick while it stays open), and shows its cleaned title. YouTube tabs get the channel name and thumbnail from YouTube's oEmbed endpoint and `i.ytimg.com`, which also tints the bars. Metadata the browser does report always wins; the fallback only fills gaps.

The first time this happens macOS asks "IslandBar wants access to control Arc" (Privacy & Security › Automation). Declining is remembered for the session and the right-click menu gains **Allow reading browser tabs…** to reopen the pane. Like the audio grant, the ad-hoc signature means the prompt returns after each rebuild. The hardened runtime needs the `com.apple.security.automation.apple-events` entitlement for the prompt to appear at all; without it Apple Events fail silently with -1743. `ISLANDBAR_IGNORE_BROWSER_METADATA=1` blanks browser metadata so the fallback can be exercised with any video.

Playback state comes from MediaRemote, with one exception: if MediaRemote reports the app paused while one of its processes is still producing audio (Arc's mini player does this), the pill keeps animating until that output stops for 3 seconds.

### One tap per session

Every Core Audio process tap is a recording session as far as macOS is concerned: creating one opens a session on the default output device, writes a `PlayAndRecord` route change into the `audiomxd` log, re-queries TCC for System Audio Recording, and prompts the user the first time. A tap therefore lasts as long as the Now Playing session does:

- Pausing does not tear the tap down. The FFT analyzer and the 60 Hz bar pump stop (an idle pill costs nothing), and the tap waits for the session to end.
- A tap is replaced only when it is genuinely wrong: its target processes stopped producing audio for 3 seconds, or a different process owns the same app's playback. Rebuilds are spaced by at least 15 seconds and then back off (20 s, 45 s, 90 s, 180 s, 300 s) within a session.
- All tap creations reuse one stage-tap UID for the life of the process, so macOS sees the same recording identity rather than a new one each time.
- Only a real TCC denial latches the procedural fallback, and it is retried after 5 minutes: a transient `coreaudiod` or device handover error no longer degrades the app until relaunch.
- A silent passage no longer switches to tapping every process on the machine, which used to rebuild the aggregate device on the way back.

Set `ISLANDBAR_FORCE_PROCEDURAL=1` to skip the tap entirely; Settings › Analysis source offers *All system output* and *Procedural only*.

## Updates

IslandBar updates itself from [GitHub Releases](https://github.com/MCMike0399/IslandBar/releases). Twenty seconds after launch, every six hours while running, and after the Mac wakes, it reads the latest release and compares it with the running version. When a newer one exists it posts a notification with **Install and Relaunch**, **What’s New** and **Skip This Version** actions; if notifications are off, a small *Software Update* window appears instead. The window shows the release notes and drives the install: download with progress, Ed25519 signature check, `codesign --verify` of the extracted bundle, then the new `IslandBar.app` is swapped into place and the app relaunches itself. Right-click the pill for **Check for Updates…** (the item turns into *Update to IslandBar x.y.z…* once one is waiting); Settings has the automatic-check toggle and a **Check Now** button.

Because signing is ad-hoc, macOS asks for System Audio Recording again after each update. In-place updates need the app to live in a writable folder and not be running from App Translocation (an unmoved download); in those cases the window offers the release page instead.

### Cutting a release

```bash
Scripts/release.sh 0.2.0                # or: --notes CHANGELOG-entry.md, --dry-run
```

The script stamps `Resources/Info.plist`, commits `Release v0.2.0`, tags, builds, zips the bundle with `ditto`, signs the zip with the Ed25519 key in `~/.config/islandbar/update-signing.key` (`ISLANDBAR_SIGNING_KEY` overrides), pushes, and publishes the release with `IslandBar-0.2.0.zip` and `IslandBar-0.2.0.zip.sig` attached. Release notes default to one bullet per commit since the previous tag. The matching public key is compiled into `Sources/IslandBar/Updates/UpdateSignature.swift`; the script refuses a key that does not match it. Back the key up — losing it means shipping a new public key by hand (`swift Tools/update-signing.swift keygen <path>`), and every copy built before that build can no longer verify a release. Keys retired by a rotation belong in `UpdateSignature.legacyPublicKeysBase64`, which is only read by builds that already contain them; the primary key is the one the script signs with.

To exercise the updater without publishing: `ISLANDBAR_UPDATE_FEED_URL` points the checker at any GitHub-shaped `latest` JSON (a `file://` URL works, with `file://` asset URLs), `ISLANDBAR_UPDATE_CHECK_DELAY=3` shortens the launch delay, and `ISLANDBAR_UPDATE_AUTO_INSTALL=1` (only honoured together with a feed override) installs without asking. `ISLANDBAR_UPDATE_PUBLIC_KEY` swaps the verification key for the same purpose.

To exercise the updater without publishing: `ISLANDBAR_UPDATE_FEED_URL` points the checker at any GitHub-shaped `latest` JSON (a `file://` URL works, with `file://` asset URLs), `ISLANDBAR_UPDATE_CHECK_DELAY=3` shortens the launch delay, and `ISLANDBAR_UPDATE_AUTO_INSTALL=1` (only honoured together with a feed override) installs without asking. `ISLANDBAR_UPDATE_PUBLIC_KEY` swaps the verification key for the same purpose.

## Resilience

- The MediaRemote helper is health-checked every 10 seconds and restarted if it died. While idle, MediaRemote is re-read every 30 seconds in case a notification was missed.
- A detached shell watchdog relaunches the app if it exits without a clean quit (crash or `kill`). SIGTERM is treated as a clean quit, so `pkill -x IslandBar` disarms it. After 5 relaunches in 10 minutes the watchdog stops re-arming; timestamps live in `~/Library/Application Support/IslandBar/relaunches.log`. Set `ISLANDBAR_NO_WATCHDOG=1` to skip it.

## License

IslandBar sources are original. `Vendor/MediaRemoteAdapter` is BSD-3 (see `Vendor/MediaRemoteAdapter/LICENSE`).
