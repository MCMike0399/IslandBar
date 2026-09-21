# IslandBar

Menu-bar Now Playing visualizer for Apple Silicon Macs: a compact Dynamic Island pill (twelve artwork-tinted bars on a shared base and a shared ceiling) that dances only while media plays.

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

Left-click the pill to open the sound card — every source playing on the Mac, and the output they all land in. Right-click for Launch at Login, Settings, Check for Updates, and Quit. The pill is always visible: while nothing is playing it shrinks into a compact idle mark — three static bars in a miniature capsule — and grows back to full size when playback resumes. The menu bar slot contracts around the mark after it has shrunk (and expands before the pill grows), so an idle IslandBar takes about half the pill's width. The mark is drawn at the slot's final trailing inset the whole time, so the slot's instant reflow never moves it.

Bar colours come from the artwork: pixels are clustered in Oklab (k-means, plus a separate pass over the colourful pixels so a small accent on a dark cover is not averaged away) and the four most distinct dominant colours are ordered by hue and interpolated into a gradient across the bars. The runner-up colours are pulled halfway towards the dominant one, so the gradient reads as a single tint with a soft shift rather than a rainbow. Hue is kept; lightness is lifted and chroma is clamped to a pastel range for legibility on the black pill, and greyscale art gives grey bars. Before artwork arrives the bars show a lavender-to-mist default.

The bars are a waveform, not a bar chart: every bar shares one base and one ceiling, so the outline is whatever the audio is doing rather than a shape drawn in advance. Levels come from twelve log-spaced FFT bands (40 Hz–14 kHz), each measured against its own running mean so steady loud material sits mid-height and transients reach the top. On the way to the screen each band is pulled part-way towards its two neighbours, which turns twelve independently twitching columns into a single moving contour, and peaks land fast while the decay is left to glide.

The pill follows the menu bar, not the Light/Dark setting: on a light menu bar it drops the black capsule and darkens the bars into a mid-dark band of the same hues, so it reads as bars rather than a black blob on white. Settings › **Show island pill background** only applies where there is a pill to draw. `ISLANDBAR_PILL_APPEARANCE=light|dark` forces either rendering, which is the way to see the light one without changing the desktop picture.

### The sound card

The card is one list of **sources**, shaped like Control Centre: grouped glass panels, thick
sliders you can grab anywhere, and round buttons beside them.

The source with a Now Playing session leads, drawn as a tile — artwork, title, artist, the
live bars, transport — with its own fader underneath. Every *other* app holding an output
connection follows as a row: icon, name, fader, mute. Nothing appears twice, because the
playing app's fader is built into its tile rather than repeated below. The tile is joined to
its own row through the session's *pid*, not the identifier MediaRemote reports: MediaRemote
names whichever process registered the session, which for a WebKit app is the shared GPU
process (`com.apple.WebKit.GPU`) rather than Safari. Resolving the pid the same way an audio
process is resolved puts both sides in one id space — and gives the tile the name a person
would use, instead of "Safari Graphics and Media". Under all of it sits
**Sound**: the system's output volume, its mute, and the device it is playing through.

The card degrades in both directions. Nothing playing means no tile; nothing making noise
means no rows; the Sound panel is always there, so an idle card is still the fastest way to
change the volume or move the audio to your headphones. MediaRemote publishes exactly one
Now Playing session, so only that source can show a title — the rest are named by their app,
which is all macOS knows about them.

Muting keeps the fader where it was, so unmuting returns to the level you had. Hovering a
row names the app, and VoiceOver reads the name and the percentage.

Clicking a row's icon and name brings that source to the front of the list; clicking it
again lets it fall back into arrival order. It cannot do more than that: macOS publishes
exactly one Now Playing session, so the tile keeps showing whichever app the system
designates, and for every other source all the system will tell us is which app it is — not
what it is playing, and not how to control it. What the list can do is put the source you
are listening for at the top, where its fader is. Like every level here, the choice is not
persisted.

The playing app's fader survives a pause. An app drops its output connection the moment it
pauses, which would otherwise retire its row a second or two later and leave the tile — the
one source the card is built around — with a dead control, which is exactly when you reach
for its level. The row is held open for as long as the app has a live audio process, and its
process objects are re-read on every poll rather than carried over, so it can never refer to
one that has since died. An app at full volume is still never tapped, so this costs nothing
and lights no recording indicator.

#### Output and system volume

The **Sound** panel's heading is the device: click it to fold out every output the Mac has
and pick one. It is plain CoreAudio on the default output device — no tap, no permission,
nothing IslandBar invented — so it keeps working when the per-app mixer cannot. Outputs that
expose no volume control at all (most HDMI and DisplayPort monitors) show the slider
disabled rather than pretending to move. IslandBar's own private aggregate devices are
filtered out of the list; offering one would route the Mac's audio into IslandBar.

The list opens in place rather than in a menu, because a menu is a second window over a
transient popover — exactly the arrangement that dismisses the popover out from under the
click that opened it.

#### Per-app volume

Four things worth knowing, because they are consequences of how macOS works rather than
choices:

- **An app left at full volume is never touched.** Core Audio exposes no per-process volume
  (every `kAudioProcessProperty*` selector is read-only), so the only way to change one app's
  level is to sever it from the hardware with a `.muted` process tap and re-render its audio
  at the level you asked for. IslandBar does that only for apps you have actually adjusted.
  Nothing is tapped, and no recording session is opened, until you move a control.
- **The recording indicator therefore tracks "something is turned down"**, not just "something
  is playing". It lights when the first app is adjusted and goes out about three seconds after
  the last one returns to full.
- **An adjusted app picks up latency** — about 16 ms on built-in output, and noticeably more
  over Bluetooth, where the round trip was measured at ~187 ms. An app at full volume pays
  none of it, which is why returning a fader to 100% releases the app completely.
- **Control is per application, not per browser tab.** Chromium routes every tab through one
  audio helper and all WebKit apps share a single GPU process, so the finest granularity the
  system offers is the process.

Levels are deliberately not remembered across launches: a mute is a moment, and a persisted
one is how you end up with a silent browser and no memory of why. `ISLANDBAR_MIXER=0` turns
the mixer off entirely — the card then shows the now-playing tile and the Sound panel and
nothing else; `ISLANDBAR_MIXER_MUTE_ONLY=1` restricts it to full or silent, with no
partial re-rendering. `swift Tools/mixerprobe.swift` prints what the mixer sees.

### Browser tabs

Some browsers publish a Now Playing entry with no title and no artwork (Arc does this from its mini player), which used to leave the card saying just "Arc". When a session from a scriptable browser (Arc, Chrome, Brave, Edge, Vivaldi, Chromium, Opera, Safari) arrives without a title, IslandBar asks the browser for its tabs over Apple Events — a fast check every 4 seconds for the first 12 seconds after a Now Playing event, then every 15 seconds (30 while paused), because each poll is an `osascript` child plus an Apple Event to the browser — picks the tab on a known media site (preferring the active tab right after a Now Playing event, then sticking with the previous pick while it stays open), and shows its cleaned title. YouTube tabs get the channel name and thumbnail from YouTube's oEmbed endpoint and `i.ytimg.com`, which also tints the bars. Metadata the browser does report always wins; the fallback only fills gaps.

The first time this happens macOS asks "IslandBar wants access to control Arc" (Privacy & Security › Automation). Declining is remembered for the session and the right-click menu gains **Allow reading browser tabs…** to reopen the pane. Like the audio grant, the ad-hoc signature means the prompt returns after each rebuild. The hardened runtime needs the `com.apple.security.automation.apple-events` entitlement for the prompt to appear at all; without it Apple Events fail silently with -1743. `ISLANDBAR_IGNORE_BROWSER_METADATA=1` blanks browser metadata so the fallback can be exercised with any video.

Playback state comes from MediaRemote, with one exception: if MediaRemote reports the app paused while one of its processes is still producing audio (Arc's mini player does this), the pill keeps animating until that output stops for 3 seconds.

### One tap per session

Every Core Audio process tap is a recording session as far as macOS is concerned: creating one opens a session on the default output device, writes a `PlayAndRecord` route change into the `audiomxd` log, re-queries TCC for System Audio Recording, and prompts the user the first time. A tap therefore lasts as long as playback does:

- Pausing stops capture at once: the aggregate device's IO engine halts. If the pause outlasts 30 seconds the tap itself is destroyed, and the next resume rebuilds it — macOS's purple recording indicator follows the tap's recording session, and a browser keeps a paused Now Playing session alive for hours, so holding the tap any longer would keep the indicator lit with nothing playing. Resuming inside the grace restarts the engine on the same tap, so a short pause costs no new recording session.
- A tap is replaced only when it is genuinely wrong: its target processes stopped producing audio for 3 seconds, or a different process owns the same app's playback. Rebuilds are spaced by at least 15 seconds and then back off (20 s, 45 s, 90 s, 180 s, 300 s) within a session.
- Every tap creation gets a **fresh** UID. Reusing one hands back a tap that coreaudiod still holds from the previous incarnation: creation succeeds, the engine reports itself running, and every buffer arrives empty (see PITFALLS.md, "The tap UID must be fresh on every creation").
- Only a real TCC denial latches the procedural fallback, and it is retried after 5 minutes: a transient `coreaudiod` or device handover error no longer degrades the app until relaunch.
- A silent passage no longer switches to tapping every process on the machine, which used to rebuild the aggregate device on the way back.

Set `ISLANDBAR_FORCE_PROCEDURAL=1` to skip the tap entirely; Settings › Analysis source offers *All system output* and *Procedural only*.

## Updates

IslandBar updates itself from [GitHub Releases](https://github.com/MCMike0399/IslandBar/releases). Twenty seconds after launch, every six hours while running, and after the Mac wakes, it reads the latest release and compares it with the running version. When a newer one exists it posts a notification with **Install and Relaunch**, **What’s New** and **Skip This Version** actions; if notifications are off, a small *Software Update* window appears instead. The window shows the release notes and drives the install: download with progress, Ed25519 signature check, `codesign --verify` of the extracted bundle, then the new `IslandBar.app` is swapped into place and the app relaunches itself. Right-click the pill for **Check for Updates…** (the item turns into *Update to IslandBar x.y.z…* once one is waiting); Settings has the automatic-check toggle and a **Check Now** button.

Forking? Repoint `UpdateFeed.repository` at your own repository before you build, or this one's releases will install themselves over your build (see PITFALLS.md).

Because signing is ad-hoc, macOS asks for System Audio Recording again after each update. In-place updates need the app to live in a writable folder and not be running from App Translocation (an unmoved download); in those cases the window offers the release page instead.

### Cutting a release

```bash
Scripts/release.sh 0.2.0                # or: --notes CHANGELOG-entry.md, --dry-run
```

The script stamps `Resources/Info.plist`, commits `Release v0.2.0`, tags, builds, zips the bundle with `ditto`, signs the zip with the Ed25519 key in `~/.config/islandbar/update-signing.key` (`ISLANDBAR_SIGNING_KEY` overrides), pushes, and publishes the release with `IslandBar-0.2.0.zip` and `IslandBar-0.2.0.zip.sig` attached. Release notes default to one bullet per commit since the previous tag. The matching public key is compiled into `Sources/IslandBar/Updates/UpdateSignature.swift`; the script refuses a key that does not match it. Back the key up — losing it means shipping a new public key by hand (`swift Tools/update-signing.swift keygen <path>`), and every copy built before that build can no longer verify a release. Keys retired by a rotation belong in `UpdateSignature.legacyPublicKeysBase64`, which is only read by builds that already contain them; the primary key is the one the script signs with.

Rotating that key takes **two** releases, because an already-installed copy only trusts the key it shipped with: the release that first embeds the new key must still be signed with the previous one, and only the release after that may sign with the new one. `Scripts/release.sh` enforces this — it reads the key the previous tag embedded and refuses to sign with a key that has not shipped yet — so the previous key's private half has to stay around until a release carrying the new one is out. See [PITFALLS.md](PITFALLS.md) for what skipping this cost.

To exercise the updater without publishing: `ISLANDBAR_UPDATE_FEED_URL` points the checker at any GitHub-shaped `latest` JSON (a `file://` URL works, with `file://` asset URLs), `ISLANDBAR_UPDATE_CHECK_DELAY=3` shortens the launch delay, and `ISLANDBAR_UPDATE_AUTO_INSTALL=1` (only honoured together with a feed override) installs without asking. `ISLANDBAR_UPDATE_PUBLIC_KEY` swaps the verification key for the same purpose.

## Resilience

- The MediaRemote helper is health-checked every 10 seconds and restarted if it died. While idle, MediaRemote is re-read every 30 seconds in case a notification was missed.
- A detached shell watchdog relaunches the app if it exits without a clean quit (crash or `kill`). SIGTERM is treated as a clean quit, so `pkill -x IslandBar` disarms it. After 5 relaunches in 10 minutes the watchdog stops re-arming; timestamps live in `~/Library/Application Support/IslandBar/relaunches.log`. Set `ISLANDBAR_NO_WATCHDOG=1` to skip it.

## Development notes

[PITFALLS.md](PITFALLS.md) collects the traps that are expensive to rediscover: the tap UID
that must be fresh on every creation (a reused one is accepted by Core Audio and then
delivers empty buffers), TCC grants bound to the ad-hoc signature and how to re-point them
with `Scripts/grant-audio-permission.sh`, launching the binary in a way that changes TCC
attribution, and the log order to read when the bars stop moving.

The status item's action needs a real `NSApp.currentEvent`, so a synthetic accessibility
press never opens the card and there is no way to look at it from a script. Under
`ISLANDBAR_DEBUG=1` a distributed notification toggles it instead:

```bash
swift -e 'import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.burbuja-lab.islandbar.debugTogglePopover"),
    object: nil, userInfo: nil, deliverImmediately: true)'
```

`screencapture -o -x -l <window id>` then captures the card on its own.

## License

IslandBar sources are original. `Vendor/MediaRemoteAdapter` is BSD-3 (see `Vendor/MediaRemoteAdapter/LICENSE`).
