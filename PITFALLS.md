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
