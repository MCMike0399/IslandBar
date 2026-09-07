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

Some browsers publish a Now Playing entry with no title and no artwork (Arc does this from its mini player), which used to leave the card saying just "Arc". When a session from a scriptable browser (Arc, Chrome, Brave, Edge, Vivaldi, Chromium, Opera, Safari) arrives without a title, IslandBar asks the browser for its tabs over Apple Events every 4 seconds, picks the tab on a known media site (preferring the active tab right after a Now Playing event, then sticking with the previous pick while it stays open), and shows its cleaned title. YouTube tabs get the channel name and thumbnail from YouTube's oEmbed endpoint and `i.ytimg.com`, which also tints the bars. Metadata the browser does report always wins; the fallback only fills gaps.

The first time this happens macOS asks "IslandBar wants access to control Arc" (Privacy & Security › Automation). Declining is remembered for the session and the right-click menu gains **Allow reading browser tabs…** to reopen the pane. Like the audio grant, the ad-hoc signature means the prompt returns after each rebuild. The hardened runtime needs the `com.apple.security.automation.apple-events` entitlement for the prompt to appear at all; without it Apple Events fail silently with -1743. `ISLANDBAR_IGNORE_BROWSER_METADATA=1` blanks browser metadata so the fallback can be exercised with any video.

Playback state comes from MediaRemote, with one exception: if MediaRemote reports the app paused while one of its processes is still producing audio (Arc's mini player does this), the pill keeps animating until that output stops for 3 seconds.

## Updates

IslandBar updates itself from [GitHub Releases](https://github.com/MCMike0399/IslandBar/releases). Twenty seconds after launch, every six hours while running, and after the Mac wakes, it reads the latest release and compares it with the running version. When a newer one exists it posts a notification with **Install and Relaunch**, **What’s New** and **Skip This Version** actions; if notifications are off, a small *Software Update* window appears instead. The window shows the release notes and drives the install: download with progress, Ed25519 signature check, `codesign --verify` of the extracted bundle, then the new `IslandBar.app` is swapped into place and the app relaunches itself. Right-click the pill for **Check for Updates…** (the item turns into *Update to IslandBar x.y.z…* once one is waiting); Settings has the automatic-check toggle and a **Check Now** button.

Because signing is ad-hoc, macOS asks for System Audio Recording again after each update. In-place updates need the app to live in a writable folder and not be running from App Translocation (an unmoved download); in those cases the window offers the release page instead.

### Cutting a release

```bash
Scripts/release.sh 0.2.0                # or: --notes CHANGELOG-entry.md, --dry-run
```

The script stamps `Resources/Info.plist`, commits `Release v0.2.0`, tags, builds, zips the bundle with `ditto`, signs the zip with the Ed25519 key in `~/.config/islandbar/update-signing.key` (`ISLANDBAR_SIGNING_KEY` overrides), pushes, and publishes the release with `IslandBar-0.2.0.zip` and `IslandBar-0.2.0.zip.sig` attached. Release notes default to one bullet per commit since the previous tag. The matching public key is compiled into `Sources/IslandBar/Updates/UpdateSignature.swift`; the script refuses a key that does not match it, and losing the private key means shipping a new public key by hand (`swift Tools/update-signing.swift keygen`). Back the key up.

To exercise the updater without publishing: `ISLANDBAR_UPDATE_FEED_URL` points the checker at any GitHub-shaped `latest` JSON (a `file://` URL works, with `file://` asset URLs), `ISLANDBAR_UPDATE_CHECK_DELAY=3` shortens the launch delay, and `ISLANDBAR_UPDATE_AUTO_INSTALL=1` (only honoured together with a feed override) installs without asking. `ISLANDBAR_UPDATE_PUBLIC_KEY` swaps the verification key for the same purpose.

## Resilience

- The MediaRemote helper is health-checked every 10 seconds and restarted if it died. While idle, MediaRemote is re-read every 30 seconds in case a notification was missed.
- A detached shell watchdog relaunches the app if it exits without a clean quit (crash or `kill`). SIGTERM is treated as a clean quit, so `pkill -x IslandBar` disarms it. After 5 relaunches in 10 minutes the watchdog stops re-arming; timestamps live in `~/Library/Application Support/IslandBar/relaunches.log`. Set `ISLANDBAR_NO_WATCHDOG=1` to skip it.

## License

IslandBar sources are original. `Vendor/MediaRemoteAdapter` is BSD-3 (see `Vendor/MediaRemoteAdapter/LICENSE`).
