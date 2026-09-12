# Pitfalls

Hard-won, non-obvious traps in this codebase. Each one cost real debugging time; each
entry says how to recognize it and how to check it. If you hit something new, add it here
instead of leaving it in a chat log.

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
