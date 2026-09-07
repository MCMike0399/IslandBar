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

Left-click the pill to expand (artwork, title, transport). Right-click for Launch at Login, Settings, and Quit. The pill is always visible: while nothing is playing the bars collapse to a flat gray line.

Bar colours come from the artwork: pixels are clustered in Oklab (k-means, plus a separate pass over the colourful pixels so a small accent on a dark cover is not averaged away) and the four most distinct dominant colours are ordered by hue and interpolated into a gradient across the bars. The runner-up colours are pulled halfway towards the dominant one, so the gradient reads as a single tint with a soft shift rather than a rainbow. Hue is kept; lightness is lifted and chroma is clamped to a pastel range for legibility on the black pill, and greyscale art gives grey bars. Before artwork arrives the bars show a lavender-to-mist default.

Playback state comes from MediaRemote, with one exception: if MediaRemote reports the app paused while one of its processes is still producing audio (Arc's mini player does this), the pill keeps animating until that output stops for 3 seconds.

## Resilience

- The MediaRemote helper is health-checked every 10 seconds and restarted if it died. While idle, MediaRemote is re-read every 30 seconds in case a notification was missed.
- A detached shell watchdog relaunches the app if it exits without a clean quit (crash or `kill`). SIGTERM is treated as a clean quit, so `pkill -x IslandBar` disarms it. After 5 relaunches in 10 minutes the watchdog stops re-arming; timestamps live in `~/Library/Application Support/IslandBar/relaunches.log`. Set `ISLANDBAR_NO_WATCHDOG=1` to skip it.

## License

IslandBar sources are original. `Vendor/MediaRemoteAdapter` is BSD-3 (see `Vendor/MediaRemoteAdapter/LICENSE`).
