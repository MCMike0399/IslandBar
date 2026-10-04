// A stand-in media app for Scripts/harness: it plays a generated tone, publishes a Now
// Playing session the way a real player does, and takes orders from the harness, so an
// agent can drive IslandBar through playback without touching the user's own apps.
//
// Built by `Scripts/harness` into .build/harness/IslandBarTestPlayer.app and launched
// through LaunchServices (a bare binary has no bundle id, so the session would arrive
// nameless). Commands arrive as a distributed notification named
// `dev.burbuja-lab.islandbar.testplayer` whose object is one of:
//
//   play | pause | fullscreen | windowed | quit
//
// Every event is printed to stdout with a timestamp; the harness keeps it in
// .build/harness/player.log.
//
// Options: --title <text>  --level <0…1, default 0.05>
//
// The tone is quiet on purpose: this runs on someone's working Mac. IslandBar measures
// each band against its own running mean, so loudness does not change what it shows.
import AppKit
import AVFoundation
import MediaPlayer

let commandName = Notification.Name("dev.burbuja-lab.islandbar.testplayer")

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let title = option("--title") ?? "Harness test tone"
let level = Float(option("--level") ?? "") ?? 0.05

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withInternetDateTime])
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

/// A slowly moving chord with a pulse on top, so the analyzer sees both steady tones and
/// transients. Rendered on the audio thread; touches nothing but its own phase.
final class Tone: @unchecked Sendable {
    private var t: Double = 0
    private let sampleRate: Double
    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func next() -> Float {
        t += 1 / sampleRate
        let swell = 0.5 + 0.5 * sin(2 * .pi * 0.4 * t)
        let pulse = sin(2 * .pi * 2 * t) > 0.6 ? 1.0 : 0.0
        let v = 0.45 * sin(2 * .pi * 110 * t) * swell
            + 0.30 * sin(2 * .pi * 440 * t) * (1 - swell)
            + 0.25 * sin(2 * .pi * 2_500 * t) * pulse
        return Float(v)
    }
}

@MainActor
final class Player: NSObject, NSApplicationDelegate {
    private let engine = AVAudioEngine()
    private var window: NSWindow?
    private var elapsed: Double = 0
    private var startedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let tone = Tone(sampleRate: format.sampleRate)
        let gain = level
        let source = AVAudioSourceNode { _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<Int(frameCount) {
                let sample = tone.next() * gain
                for buffer in list {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.engine.isRunning { self.pause() } else { self.play() }
            return .success
        }

        DistributedNotificationCenter.default().addObserver(
            forName: commandName, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(command) }
        }
        log("launched pid=\(ProcessInfo.processInfo.processIdentifier) title=\(title) level=\(level)")
        play()
    }

    private func handle(_ command: String) {
        log("command \(command)")
        switch command {
        case "play": play()
        case "pause": pause()
        case "fullscreen": setFullScreen(true)
        case "windowed": setFullScreen(false)
        case "quit":
            pause()
            NSApp.terminate(nil)
        default: log("unknown command \(command)")
        }
    }

    private func play() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            log("engine start failed: \(error)")
            return
        }
        startedAt = Date()
        publish(rate: 1)
        MPNowPlayingInfoCenter.default().playbackState = .playing
        log("playing")
    }

    private func pause() {
        guard engine.isRunning else { return }
        engine.pause()
        if let startedAt { elapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        publish(rate: 0)
        MPNowPlayingInfoCenter.default().playbackState = .paused
        log("paused")
    }

    private func publish(rate: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "IslandBar harness",
            MPMediaItemPropertyPlaybackDuration: 3_600.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
    }

    /// Real full screen, for checking `MenuBarAutoHide`'s own detection. macOS only lets
    /// the active app enter it, and will not activate a process that was started in the
    /// background while the user works elsewhere — so this logs whether it worked, and a
    /// person may have to click the window first.
    private func setFullScreen(_ on: Bool) {
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                log("fullscreen=\(window.styleMask.contains(.fullScreen)) wanted=\(on) active=\(NSApp.isActive)")
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "IslandBar harness — \(title)"
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let player = Player()
    app.delegate = player
    app.run()
}
