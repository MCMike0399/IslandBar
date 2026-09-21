# Pitfalls

Hard-won, non-obvious traps in this codebase. Each one cost real debugging time; each
entry says how to recognize it and how to check it. If you hit something new, add it here
instead of leaving it in a chat log.

## Popover

### `NSPopover.animates` slides the card's contents across the screen

The open animation grows the *window* from the status item — 123x94, 238x182, 366x279 — and
because the hosting controller has `sizingOptions = []`, the card inside is laid out at its
final size from the first frame. So nothing scales: the full-size card is drawn and merely
revealed through a growing window. And the window's origin travels as it grows (x went -707,
-764, -828 for a 340 pt card), so the contents visibly **slide** across the screen on the way
in. The same animation on a content-size change drags the card's contents behind the new
height when a section opens.

At 300x150 this was small enough to pass for an animation. At 340 wide and 279 tall it reads
as the card's contents jumping, which is what it is. `popover.animates = false`.

**Check it** by sampling `CGWindowListCopyWindowInfo` every 40 ms while the popover opens:
intermediate frames mean the animation is on. With it off there is exactly one frame, at the
final size.

### Verifying a vibrant popover needs a *screen* capture, not a window capture

`screencapture -o -l <window id>` captures the window's own backing. An `NSVisualEffectView`
with `blendingMode = .behindWindow` is composited by WindowServer from what is *behind* the
window, which is not in that backing — so the whole vibrant area comes back flat grey and
every backdrop defect looks fixed.

Use `screencapture -x -R<x>,<y>,<w>,<h>` over the popover's frame instead. Hours were spent
declaring a backdrop bug fixed against captures that could not have shown it.

### `NSPopover` owns its content view's frame; setting it yourself narrows the card

`NSPopover` lays its content view out into an area a little *wider* than the `contentSize`
it was given — measured at 12 pt on macOS 26. Code that sets both:

```swift
popover.contentSize = size
popover.contentViewController?.view.frame = NSRect(origin: .zero, size: size)   // wrong
```

works on the first show (the popover sized the view itself) and goes wrong on the first
resize, when the assignment shrinks the view back to `size`.

While the content view was an `NSHostingView` whose SwiftUI root filled whatever it was
given, this was invisible. Once the content view is the blurred backdrop, the missing strip
is unblurred popover background — a lighter band down the right-hand edge that appears only
after the card has resized once.

**Check it** by sampling one horizontal line near the right edge in both states: the colour
transitions must land at the same x. Set `contentSize` and nothing else.

### The blurred backdrop cannot be a representable in a card that resizes

The expanded card's height is set imperatively (`NSPopover.contentSize` plus the content
view's frame, in `StatusItemController.resizeCard`), because the SwiftUI root must not
re-measure the popover on every bar frame. An `NSVisualEffectView` hosted *inside* that
SwiftUI tree is resized by a layout pass that lands **after** the window has already grown.

The result is intermittent and reads as a completely different bug. Opening the output list
grows the card by 66 pt; the blur stays at its old height; and the strip below it shows the
popover's raw backing instead of blurred desktop. Because a panel's dark fill sits on top of
that strip, the Sound panel looks like it has been **cut off below its slider**, with the
device rows floating outside it.

**Recognize it:** the rows are in the right place and the card is the right height — only the
region below the old height is wrong. A `GeometryReader` probe on the panel reports the
correct height (`139.0`), which rules out layout and points at drawing.

**Check it:** sample one pixel column in the card's 14 pt outer padding, above and below the
boundary. The backdrop must be the same colour at both; when the blur has lagged, the lower
sample shows whatever window is behind the popover, so it varies horizontally with what is
back there (dark over a terminal, light over a browser).

The fix is that the blur is the popover's own `contentViewController.view`, with the hosting
view added as an autoresizing subview. `resizeCard` then resizes the blur in the same
statement as the window, and no layout pass is involved.

## Audio capture

### The tap UID must be fresh on every creation

`AudioHardwareCreateProcessTap` takes a `CATapDescription` whose `UUID` becomes the tap's
UID. The aggregate device references the tap **by that UID**:

```swift
let tapUID = description.uuid.uuidString   // must be unique per creation
kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, ...]]
```

Reusing one UID across tap creations (for example a `static let stageUID` to make rebuilds
look identical to macOS) returns a tap that coreaudiod still holds from the previous
incarnation. The failure is silent and very convincing:

- `AudioHardwareCreateProcessTap` returns `noErr`
- the aggregate device is created
- `AudioDeviceStart` returns `noErr`, `kAudioDevicePropertyDeviceIsRunning == 1`
- the IO proc fires at the real buffer rate (~85 Hz at 48 kHz)
- **every buffer has `mDataByteSize == 0`** — 0 frames reach the ring buffer

**Recognize it:** bars flat, `rms=-120`, `fromTap=false` in the debug log, and the app's
`audiomxd` session shows `Recording = NO` while the engine claims to be running.

**Check it:** the tap-health line logged 2 s after every tap creation:

```
tap IO alive: 169 callbacks in 2s sampleRate=48000.0 engineRunning=true samplesRead=86016
IO callback missing within 2s; falling back to procedural
```

`callbacks > 0` but `samplesRead == 0` means the tap is attached to a running device that
is not feeding it — check this before suspecting TCC or the target list.

### `mDataByteSize == 0` buffers are normal, and must be skipped

The IO proc iterates an `AudioBufferList`. Buffers with a null `mData` or a zero byte size
are routine (they appear on every callback when the tap has nothing to contribute) and
dividing by them yields zero frames, which is harmless but noisy. Skip them.

### A TCC grant is bound to the exact code signature

`kTCCServiceAudioCapture` (System Audio Recording) is what a process tap needs. The grant
is keyed to the app's code requirement, and this app is signed **ad-hoc** (`build.sh` uses
`codesign --sign -`), so **every rebuild changes the cdhash and invalidates the grant**.

What makes this trap expensive: macOS does not re-prompt. It keeps the stale row, fails to
match it, and the tap silently returns silence — identical symptoms to the UID bug above.
The log says it plainly, under `tccd`:

```
Failed to match existing code requirement for subject dev.burbuja-lab.islandbar and service kTCCServiceAudioCapture
ReqResult(Auth Right: Unknown (None), promptType: 1, DB Action: None)
```

If the row is deleted (`tccutil reset AudioCapture dev.burbuja-lab.islandbar`) no prompt is
shown for this build either, so grant it deliberately:

```bash
./build.sh
./Scripts/grant-audio-permission.sh   # rebinds the grant to the current cdhash
pkill -x IslandBar && open dist/IslandBar.app
```

`grant-audio-permission.sh` writes the same row the system writes after the user approves
a prompt. It backs up `TCC.db` first and touches nothing but that one row.

**Verify a grant before blaming the code:**

```bash
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, auth_value, length(csreq), hex(csreq) from access where client like '%islandbar%';"
codesign -dvvv dist/IslandBar.app 2>&1 | grep '^CDHash='
```

The cdhash inside the stored `csreq` blob (its last 20 bytes, uppercase hex) must equal the
binary's current `CDHash`. A 40-byte blob decodes as:

```
FADE0C00 | 00000028 (length) | 00000001 (one requirement) | 00000008 (cdhash opcode) | 00000014 (20 bytes) | <20-byte cdhash>
```

`csreq -r- file` wants a **file path**, not a requirement string, and `csreq -r- -b` fails
on an empty argument — build the blob directly as above instead of fighting the tool.

### Microphone and audio-capture are different services

`coreaudiod` preflights `kTCCServiceMicrophone` for the requesting pid as well. That one is
denied outright for this app because the hardened runtime requires
`com.apple.security.device.audio-input` and `Resources/IslandBar.entitlements` does not grant
it:

```
Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement
com.apple.security.device.audio-input but it is missing
```

That message is expected and is **not** why capture fails; the service that matters is
`kTCCServiceAudioCapture`, and process tap audio flows without the mic entitlement.

### Launching the binary directly changes TCC attribution

Running `dist/IslandBar.app/Contents/MacOS/IslandBar` from a shell inside another app
(an agent harness, a Node/Electron terminal) makes that parent the **responsible process**
for TCC. The grant is then evaluated against the parent, and the tap is denied:

```
AUTHREQ_ATTRIBUTION: attribution={responsible={… identifier=node-… }, accessing={… islandbar …}}
```

Always launch through LaunchServices — `open dist/IslandBar.app` or
`open --env ISLANDBAR_DEBUG=1 dist/IslandBar.app` — when you care about permissions.

### The tap outlives a pause; the analyzer does not

A pause deliberately keeps the process tap (recreating one is a fresh recording session as
far as macOS is concerned) but stops the analyzer, so an idle pill costs nothing. Resuming
goes through `renewTap`, which decides the existing tap is still good and returns early —
and `installTap` is the only thing that calls `analyzer.start()`. The result was a live tap
feeding nothing: `SharedBarState` kept the last levels the analyzer published, the pump
eased to them and settled, and the bars sat frozen for the rest of the session while audio
played.

**Recognize it:** `bandLevels=[…] rms=… fromTap=true` repeating with *identical* values
every second, and **no `tap created` line after the resume**. `rms=-240.0` with every band
at 0.12 is the giveaway — that is the digital silence captured at the instant of the pause,
replayed forever. A relaunch fixes it, which is why it looks intermittent.

**Check it** — play, pause past the output-quiet grace, resume, and count distinct levels:

```bash
grep -o "rms=[-0-9.]*" ~/Library/Logs/IslandBar/debug.log | tail -20 | sort -u | wc -l
```

One distinct value while `fromTap=true` means frozen; live audio gives a dozen.

The invariant is now asserted in the one place that decides to keep a tap: if we are playing
and holding a running tap, the analyzer is draining it (`attachAnalyzer`, which also drops
the ring — `writeMixedMono` stalls when full rather than overwriting, so the tap left ~85 ms
of stale audio queued at the moment of the pause).

**Driving playback for a test** without touching the browser — the vendored adapter's perl
helper takes MediaRemote commands directly (absolute paths only; Apple's perl refuses a
relative dylib):

```bash
APP=dist/IslandBar.app; A="$PWD/$APP"
/usr/bin/perl "$A/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle/Contents/Resources/run.pl" \
  "$A/Contents/Frameworks/libMediaRemoteAdapter.dylib" play   # or pause, get, next_track
```

Gate any such test on `isPlaying=false applied` actually appearing in the log: a browser
pause usually does **not** reach the store straight away, because `effectivePlaying` keeps
the session playing while the app is still producing output (Arc holds its output unit open
for a few seconds). A pause shorter than that grace tests nothing.

## Per-app volume

### A `.muted` tap mutes nothing until its aggregate is *started*

Creating a `CATapDescription` with `muteBehavior = .muted` and calling
`AudioHardwareCreateProcessTap` looks like it should silence the app. It does not. The mute
engages only once that tap sits in an aggregate device whose IO proc has been started with
`AudioDeviceStart`.

Measured with a microphone against a steady tone: tap created but attached to nothing gave
`f440=0.013515` against a `0.013491` baseline — no change at all.

**Recognize it:** `mixer tap created` in the log, no `mixer engine started`, and the app is
still audible.
**Check it:** there is no cheap "just mute it" path — mute costs exactly what volume costs,
which is why `AudioMixer` treats mute as gain 0 on the same fader rather than as a separate
mechanism.

### `kAudioAggregateDeviceTapAutoStartKey` defers the mute

The visualizer's aggregate sets it to `true`, and should. The mixer's aggregate must **not**.
The key makes `AudioDeviceStart` wait for the first tapped process to produce audio, which
defers the device start — and with it the mute. A mute click would appear to do nothing
until the app next happened to make a sound.

**Recognize it:** muting a paused or quiet app has no effect, then takes effect later.
**Check it:** `MixerEngine` omits the key deliberately and comments why; copying
`ProcessAudioTap.start()` wholesale is how it gets reintroduced.

### Verifying a mute with another tap lies

A tap reads a pre-mute mix point. A second tap watching an app that a `.muted` tap has
silenced still reports it at **full amplitude**, while the speakers are provably silent.

**Recognize it:** a probe that taps its way to "the mute did not work" while the room is quiet.
**Check it:** only an acoustic measurement proves a mute. The corollary is load-bearing and
deliberate: the visualizer's `.unmuted` tap keeps receiving a muted app's audio, so the pill's
bars keep animating for an app the mixer has silenced.

### `kAudioProcessPropertyDevices` answers only in the output scope

Asked in `kAudioObjectPropertyScopeGlobal` it returns an empty array for **every** process,
including ones that are audibly playing — which reads as "nothing is using audio" rather than
as an error.

**Check it:** `swift Tools/mixerprobe.swift` prints both scopes per process. Output scope is
also what reduces ~35 process objects to the 2-3 apps actually holding an output, with no
denylist needed.

### There is no per-process volume or mute property

All six `kAudioProcessProperty*` selectors (`ppid`, `pbid`, `pdv#`, `pir?`, `piri`, `piro`)
are read-only in every scope. `kAudioHardwarePropertyProcessIsAudible` exists only on the
system object and mutes *the calling process*. Per-app level is therefore not a property
write; it is "sever the app with a `.muted` tap, then re-render its samples yourself".

### Retiring a slot is an ordered pair of writes

Returning an app to normal means dropping its gain to 0 **first**, then flipping its tap's
`muteBehavior` to `.unmuted`. Do it the other way round and both the original and the
re-rendered copy are audible for a moment, which comb-filters: measured at 56% of baseline
with a suckout at the test tone.

**Recognize it:** a brief hollow or phasey sound when a fader returns to full.

### `prefix3` is unsound for grouping WebKit processes

`AudioProcessRegistry.matches` compares three-component bundle prefixes, which is right for
matching a now-playing session. It cannot group mixer rows: two simultaneous processes both
reporting `com.apple.WebKit.GPU` belonged to Safari and to WebThumbnailExtension, and no
string function separates them. Only `responsibility_get_pid_responsible_for_pid` does.

## Diagnosing "the bars are not moving"

Read the debug log (`ISLANDBAR_DEBUG=1`, `~/Library/Logs/IslandBar/debug.log`) in this order:

1. `session bundle=… isPlaying=true` — is there a session at all?
2. `tap created source=… targets=[…]` — did a tap get created, and against which processes?
3. `tap IO alive: … samplesRead=N` — is audio reaching the analyzer? `N == 0` means the tap
   is connected but silent: suspect the UID bug or the TCC grant, in that order.
4. `bandLevels=[…] rms=-33.4 fromTap=true` — the analyzer is publishing real audio. If this
   is healthy but the pill is flat, the problem is in the view layer, not capture.
5. `procedural driver active reason=…` — the tap was abandoned on purpose; the reason string
   says why (`permission-denied`, `forced-procedural`, `io-timeout`, `no-targets`).

## Diagnosing "the icon vanished and came back"

That is a crash plus the relaunch watchdog, not a drawing bug. The watchdog polls every 2 s
and sleeps 1 s before reopening, so a crash reads as a 3–5 s gap in the menu bar. Confirm it
from the crash reports rather than the debug log — the process is gone before it can log:

```bash
ls -lat ~/Library/Logs/DiagnosticReports/ | grep IslandBar
cat ~/Library/Application\ Support/IslandBar/relaunches.log   # epoch stamps, pruned to 10 min
```

If the icon stays gone, the watchdog hit its crash-loop cap (5 relaunches in 10 minutes) and
stopped re-arming; `open dist/IslandBar.app` brings it back.

`.ips` files are two JSON documents — a header line, then the body. Symbolicated frames are
already in them, so no `atos` run is needed:

```bash
python3 -c 'import json,sys
f=open(sys.argv[1]); f.readline(); d=json.load(f); imgs=d["usedImages"]
for fr in d["threads"][d["faultingThread"]]["frames"]:
    i=fr.get("imageIndex")
    print(imgs[i]["name"] if i is not None else "?", fr.get("symbol"))' <report>.ips
```

### A main-queue callback invoked from the tap queue

`EXC_BREAKPOINT` in `dispatch_assert_queue_fail` under `MainActor.assumeIsolated` means a
closure that is documented as main-queue ran somewhere else. The delegate's `onLevels`
handler skips the actor hop with `assumeIsolated` because the pump's 60 Hz timer is a
`.main` dispatch source — correct for that path, and a trap for any other.

`BarLevelPump.rest()` broke it: `TapController.applyLocked` calls it from
`dev.burbuja-lab.islandbar.tap` on every pause and every session end, and it published one
final frame inline. Every playing session therefore crashed on its first pause — which on a
video with ads or a seek is constantly, and the watchdog kept relaunching into it. Shipped
in 0.2.0, fixed in the release after 0.3.0.

The general shape: `@unchecked Sendable` puts the queue contract in a comment, and a
`@Sendable` closure compiles the same whichever queue it runs on, so nothing catches this
until it traps at runtime. When a class is touched from two queues, say in its doc comment
which fields and callbacks belong to which — `BarLevelPump` now does — and keep the
cross-queue methods to a `stop()`-style flag flip plus a `DispatchQueue.main.async` block.
`assumeIsolated` checks the dispatch queue, so hop with `DispatchQueue.main.async`, not
`Task { @MainActor }`: the async block also keeps FIFO order with the timer a following
`start()` resumes, which is what stops a pause→play from easing in from stale heights.

## Churn bookkeeping

Every tap creation is a **recording session** as far as macOS is concerned: it writes a
`PlayAndRecord` route change into the `audiomxd` log, re-queries TCC, and lights the system
recording indicator. Counting tap creations is therefore the right way to audit "IslandBar
asks to record too much":

```bash
grep -c "tap created" ~/Library/Logs/IslandBar/debug.log
log show --last 1h --style compact --info --debug --predicate 'process == "audiomxd"' \
  | grep -c "IslandBar(<pid>).*starting recording"
```

`tearDownAudio` only logs when `tap.isRunning`, so a teardown can be invisible in the log
while the counter still shows the rebuild. Sessions that genuinely change app (Chrome →
Music) or end are legitimate rebuilds; a rebuild roughly every couple of minutes during
continuous playback is not — the controller has `minTapResidency`, per-session backoff and
target-liveness checks to prevent exactly that (`ProcessAudioTap.swift`, "Tap stability").

### The indicator outlives the audio if the tap does

macOS's purple recording indicator follows the tap's recording session, not the audio: a tap
held through a pause (or through a browser's paused Now Playing session, which can stay
alive for hours) keeps the indicator lit with nothing playing — the old "hold the tap until
the session ends" rule showed it around the clock. Playback stopping therefore halts the
aggregate device's engine at once and destroys the tap after `pauseTeardownGrace` (30 s);
the next resume rebuilds it. Watch the sequencing in the log:

```
capture engine stopped reason=pause
tap torn down reason=paused-grace                       # pause outlasted the grace
capture engine restarted reason=playing                 # ...or this, if it did not
```

The grace is what keeps churn down: pause/resume inside it costs no recording session, and
a resume after it is a legitimate new one. Do not keep a silent tap alive to save TCC
queries — that is what lit the indicator in the first place.

## The pill's appearance

### It follows the menu bar, which follows the wallpaper — not the system setting

On macOS 26 the menu-bar material is glass: it takes its lightness from the desktop
picture. Select Light mode over a dark wallpaper and the menu bar is still dark, its
status items included. Reading the appearance from `NSApp.effectiveAppearance` therefore
gets it wrong in exactly the case the pill cares about — it would drop the capsule and
darken the bars on a menu bar that is still black.

`CompactIslandView` reads `@Environment(\.colorScheme)` instead. The hosting view is a
subview of the status item's button, so that value *is* the menu bar's own appearance, and
it updates live when the wallpaper (or the system setting) changes it.

**Check it:** the log records the decision, and every change to it:

```
bars: menu bar background=light
```

**Compare the two variants without touching the desktop:**

```bash
ISLANDBAR_DEBUG=1 ISLANDBAR_PILL_APPEARANCE=light open dist/IslandBar.app   # or =dark
```

`ISLANDBAR_PILL_APPEARANCE` forces `onLightMenuBar`, which is the only practical way to
see the light rendering on a machine whose wallpaper is dark.

### The compact pill is the only view that adapts

`ArtworkPalette` maps every colour into a pastel band sized for the black pill. On a light
menu bar the capsule is dropped and `ArtworkPalette.onLightBackground` re-maps those same
colours into a darker band (hue kept, chroma nudged up) so they still read against white.
The mapping is applied in `IslandBarsView.updateNSView`, not in the store: the expanded
popover sits on a dark HUD and must keep the pastel palette.

### The idle mark contracts, then the slot contracts around it

While nothing plays, `CompactIslandView` shrinks the pill into a miniature capsule holding
three static bars (`CompactIslandMetrics.idleMarkSize`) and smoothly grows back when
playback resumes; the full-size flat line is popover-only now. The status item's slot
follows: `StatusItemController.applyPresence` narrows the hosting view's width constraint
to `idleSlotWidth` 0.75 s after the pause (once the shrink has landed) and restores it
immediately on play.

What makes the handoff invisible:

- The slot is sized by the hosting view's **width constraint**, not `NSStatusItem.length`.
  Setting `length` reads back correctly (the log even showed `length=37 button=37`) but
  does not resize the item — the button was still being measured from its subview
  constraints, and the visible footprint never changed. The property is a red herring;
  constrain the subview and let the variable-length item follow it.
- The width change is a **snap, never an animation** (AppKit reflows the menu bar
  instantly), which is why it is sequenced after the pill's own animation. Neighbouring
  status items visibly shift once; nothing can smooth that.
- `CompactIslandView`'s root is a `GeometryReader`, so it takes the slot's size rather
  than the content's. Without it, the full-width bar row would widen the root while the
  slot is narrow and drag the trailing-aligned mark left. Inside, the mark sits at
  `idleInset` from the trailing edge — the one edge status-item layout pins — so the snap
  moves nothing on screen.
- The bars themselves `scaleEffect` towards that same trailing edge as they fade, because
  the black capsule is invisible on a dark menu bar: without it the pill only crossfades
  and there is no visible shrink to speak of.

The idle mark keeps the neutral `BarsLayerView.idleColor`/`lightIdleColor`, not the last
palette. Reduce Motion swaps the two states without the animation and collapses the slot
at once.

### Pause → idle takes as long as the output flag takes

Chromium (Arc, Chrome) leaves `kAudioProcessPropertyIsRunningOutput` set for many seconds
after a pause, and the override path trusted that flag alone: pause a YouTube video and
the pill could keep dancing for ~10 s. `pollOutput` now has a second, faster signal: the
analyzer's own `rmsDb`. A paused stream that the process keeps open feeds digital silence,
so while MediaRemote says paused, the tap reporting `fromTap && rmsDb <= tapSilenceDb`
for `tapSilenceGrace` (1.2 s) ends the override without waiting for the flag. The gate on
`fromTap` matters — procedural motion publishes invented levels and would make a real
playing session go idle. The flag + `outputQuietGrace` path is still there as the
fallback when no tap exists (procedural mode, denied capture).

## Full screen

### Animating a status item holds the menu bar open

The menu bar auto-hides in a full-screen space. It does not while a status item is redrawing
sixty times a second: the bar comes down and stays down, and the window's title bar comes
with it — the app is squeezed from `0,0 1728x1117` to `0,33 1728x1084` for as long as
something plays. It looks like the app being covered. It is the pill holding the bar open.

Measured with a full-screen window and the pointer parked at the middle of the screen,
polling `CGWindowListCopyWindowInfo` for the WindowServer's `Menubar` window every 500 ms:

| IslandBar | audio | menu bar over 12 s |
| --- | --- | --- |
| quit | playing | hidden from the first sample |
| running, idle | none | hidden after 10 s |
| running | playing | **never hidden** |

The gate is `MenuBarAutoHide`. Where the bar hides itself — a full-screen space, or a desktop
whose owner set auto-hide in Settings — the bars animate only while the pointer is in the menu
bar, which is the only time anyone can see them. Everywhere else nothing changes.

**Recognize it:** a full-screen window whose height is the screen's less the menu bar, with
its title bar showing, while music plays.
**Check it** with the poll above, or in the log:

```
menu bar auto-hide=on
pill animation allowed=false        # ...and the bar goes back up
```

### There is no public API for "is this space full screen"

`NSScreen.visibleFrame` does not change in a full-screen space (measured: 1084 pt of a
1117 pt screen, in and out), `NSMenu.menuBarVisible()` stays `true`, and the WindowServer's
`Menubar` window only reports what the bug is already breaking. So `MenuBarAutoHide` reads the
space instead: every ordinary layer-0 window on it belongs to one application, and that
application has a window as wide as a display whose height is the display's or the display's
less the menu bar. Both heights are needed — the short one *is* the held-open state.

The inset comes from `screen.frame.maxY - screen.visibleFrame.maxY`, never from
`NSStatusBar.system.thickness`: on a notched Mac the bar is 33 pt and that property still
answers 24, and the nine points made every full-screen window miss its match.

## Self-update

### A release key must ship before it signs anything

`UpdateSignature.swift` compiles in the keys a copy will accept, which makes rotating one a
**two-release** operation. v0.2.0 got that wrong: commit `3f6add0` rotated
`publicKeyBase64` and the same release was signed with the new key, so no copy in
existence trusted it. The old key's private half was overwritten in the same sitting,
which left every copy built before the rotation permanently unable to update itself:

```
The downloaded update failed signature verification and was discarded.
```

`legacyPublicKeysBase64` only helps *forwards* — a new build accepts an archive signed by
an old key, never the reverse. A copy already in the wild can only be recovered by hand.

**Recognize it:** that message on a copy that predates the most recent key change.
**Check it:** the keys a running copy trusts are plain base64 in its binary, and the
release's signature only verifies under the newest one:

```bash
strings dist/IslandBar.app/Contents/MacOS/IslandBar | grep -E '^[A-Za-z0-9+/]{43}=$'
swift Tools/update-signing.swift verify <key in the tree> dist/IslandBar-<v>.zip dist/IslandBar-<v>.zip.sig
```

**How the script prevents a repeat** (`Scripts/release.sh`): a release whose tree embeds a
key the previous release did not embed must be signed with the *previous* key. That release
then ships the new key, and the one after it can sign with it. If the old key is missing the
script refuses, which is the correct outcome — the rotation cannot be completed without it.
**Never delete the previous private key** until a release carrying the new one is published.

### A fork that keeps upstream's feed updates itself *off* the fork

`UpdateFeed.repository` names the repository whose releases a build installs, and it is
compiled in. A fork that leaves it pointing at the repository it was forked from has an
updater that does exactly what it was told: twenty seconds after launch it reads
upstream's latest release, sees a version newer than the fork's own `Info.plist`, verifies
the archive against a key both trees share — and swaps upstream's bundle over the fork's
app. Nothing fails, so nothing is reported. A fork hit this on 2026-09-20: v0.3.6 landed
on top of its build and took a whole feature with it.

It is quiet in the worst way: the app is *in the same place*, launches, and works. Only its
features are someone else's. A build sitting in `dist/` is no safer than an installed one,
because the installer replaces the bundle the running process was launched from.

**Recognize it:** the bundle's `CFBundleShortVersionString` is a version the fork never cut,
and a feature you wrote is gone from a bundle newer than your last build.

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/IslandBar.app/Contents/Info.plist
git tag --list --points-at HEAD     # no tag here means this tree released nothing
```

Nothing is lost when it happens — the source is in git, and a rebuild restores the fork.
**Point `repository` at the fork's own repository** and take upstream's work through `git
merge upstream/main` instead, which is the only path that keeps the code and the binary the
same thing.
