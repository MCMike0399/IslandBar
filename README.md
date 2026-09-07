# IslandBar

Menu-bar Now Playing visualizer for Apple Silicon Macs: a compact Dynamic Island pill (artwork + four artwork-tinted bars) that dances only while media plays.

macOS 15.4+, unsandboxed. Built with SwiftPM and Command Line Tools — no Xcode project.

## Build and run

```bash
cd /Users/burbujamc/Developer/IslandBar
./build.sh
open dist/IslandBar.app
```

`./build.sh --run` rebuilds, replaces a running instance, and opens the app.

## Permissions

The first time a track plays, macOS asks for **System Audio Recording** so the process tap can drive the bars. Audio is never saved.

Signing is **ad-hoc**. TCC keys the grant to the binary’s cdhash, which changes on every rebuild, so expect **one permission prompt per fresh build**.

Debug logging (state transitions and per-second band levels):

```bash
mkdir -p ~/Library/Logs/IslandBar
ISLANDBAR_DEBUG=1 dist/IslandBar.app/Contents/MacOS/IslandBar
```

`ISLANDBAR_FORCE_PROCEDURAL=1` skips the tap and uses the fallback motion (also used when capture is denied).

## Usage

Left-click the pill to expand (artwork, title, transport). Right-click for Launch at Login, Settings, and Quit. The item hides when nothing is playing a session; relaunching while hidden shows it paused for 8 seconds so Settings/Quit stay reachable.

## License

IslandBar sources are original. `Vendor/MediaRemoteAdapter` is BSD-3 (see `Vendor/MediaRemoteAdapter/LICENSE`).
