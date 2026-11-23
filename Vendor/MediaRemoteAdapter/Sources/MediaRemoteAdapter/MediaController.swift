import CIMediaRemote
import Darwin
import Foundation

public class MediaController {

    // PATCH (IslandBar): look in the host app's Contents/Resources first, where build.sh
    // puts the resource bundle. SwiftPM's generated `Bundle.module` only checks the app's
    // *root* folder and then the absolute `.build` path of the machine that compiled it,
    // and traps when neither exists. That path happened to exist on the Macs that built
    // the early releases, so they ran; v0.5.0, the first built on a GitHub runner, looked
    // for /Users/runner/work/… and crashed at launch on every other Mac.
    private static let resourceBundle: Bundle? = {
        let name = "MediaRemoteAdapter_MediaRemoteAdapter.bundle"
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent(name)) {
            return bundle
        }
        // `swift run` and tests: no app bundle, but the build directory is right there.
        let buildDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return Bundle(url: buildDir.appendingPathComponent(name))
    }()

    private var perlScriptPath: String? {
        guard let path = Self.resourceBundle?.path(forResource: "run", ofType: "pl") else {
            assertionFailure("run.pl script not found in bundle resources.")
            return nil
        }
        return path
    }

    // PATCH (IslandBar): listener lifecycle and callbacks are confined to the main
    // queue. Keep ownership during shutdown, so health checks can't spawn a second helper.
    private var listeningProcess: Process?
    private var listeningRequested = false
    private var listenerStopping = false
    private var lastTrackInfo: TrackInfo?
    private var eventCount = 0
    private let restartThreshold = 100
    private let commandQueue = DispatchQueue(label: "mediaremote-adapter.commands")
    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    // PATCH (IslandBar): lets the host health-check the listener and restart it when the
    // helper died before producing any event (onListenerTerminated only fires after events).
    public var isListening: Bool {
        listeningProcess?.isRunning == true && !listenerStopping
    }

    public var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    public var onListenerTerminated: (() -> Void)?
    public var onListenerDiagnostic: ((String) -> Void)?
    public var onDecodingError: ((Error, Data) -> Void)?

    public init() {
        _ = MediaController.sigpipeIgnored
    }

    // PATCH (IslandBar): Bundle(for: MediaController.self).executablePath returns the
    // host app executable when this dylib sits in Contents/Frameworks, so perl would
    // be handed the wrong path (and Apple's perl refuses relative dylibs). Resolve the
    // actual dylib via dladdr on CIMediaRemote's exported `bootstrap` symbol.
    private var libraryPath: String? {
        let symbol: @convention(c) () -> Void = bootstrap
        var info = Dl_info()
        guard dladdr(unsafeBitCast(symbol, to: UnsafeRawPointer.self), &info) != 0,
              let fname = info.dli_fname else {
            assertionFailure("dladdr failed for bootstrap; cannot locate libMediaRemoteAdapter.dylib.")
            return nil
        }
        return String(cString: fname)
    }

    @discardableResult
    private func runPerlCommand(arguments: [String]) -> (output: String?, error: String?, terminationStatus: Int32) {
        guard let scriptPath = perlScriptPath else {
            return (nil, "Perl script not found.", -1)
        }
        guard let libraryPath = libraryPath else {
            return (nil, "Dynamic library path not found.", -1)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, libraryPath] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        var outputBuffer = Data()
        var errorBuffer = Data()
        let lock = NSLock()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            outputBuffer.append(data)
            lock.unlock()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            errorBuffer.append(data)
            lock.unlock()
        }

        do {
            try process.run()
            process.waitUntilExit()

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            lock.lock()
            outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            lock.unlock()

            let output = String(data: outputBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = String(data: errorBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return (output, errorOutput, process.terminationStatus)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return (nil, error.localizedDescription, -1)
        }
    }

    public func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void) {
        guard let scriptPath = perlScriptPath else {
            onReceive(nil)
            return
        }
        guard let libraryPath = libraryPath else {
            onReceive(nil)
            return
        }

        let getProcess = Process()
        getProcess.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        var getDataBuffer = Data()
        var getDataBufferSearchStart = 0
        var callbackExecuted = false

        getProcess.arguments = [scriptPath, libraryPath, "get"]

        let outputPipe = Pipe()
        getProcess.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let incomingData = fileHandle.availableData
            if incomingData.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }

            getDataBuffer.append(incomingData)

            guard let newlineData = "\n".data(using: .utf8),
                  let range = getDataBuffer.firstRange(of: newlineData, in: getDataBufferSearchStart..<getDataBuffer.count),
                  range.lowerBound <= getDataBuffer.count else {
                getDataBufferSearchStart = getDataBuffer.count
                return
            }

            let lineData = getDataBuffer.subdata(in: 0..<range.lowerBound)
            getDataBuffer.removeSubrange(0..<range.upperBound)
            getDataBufferSearchStart = 0

            if !lineData.isEmpty && !callbackExecuted {
                callbackExecuted = true
                if lineData == "NIL".data(using: .utf8) {
                    DispatchQueue.main.async { onReceive(nil) }
                    return
                }
                do {
                    let trackInfo = try JSONDecoder().decode(TrackInfo.self, from: lineData)
                    DispatchQueue.main.async { onReceive(trackInfo) }
                } catch {
                    DispatchQueue.main.async { onReceive(nil) }
                }
            }
        }

        getProcess.terminationHandler = { _ in
            if !callbackExecuted {
                DispatchQueue.main.async { onReceive(nil) }
            }
        }

        do {
            try getProcess.run()
        } catch {
            onReceive(nil)
        }
    }

    public func startListening() {
        listeningRequested = true
        guard listeningProcess == nil,
              let scriptPath = perlScriptPath,
              let libraryPath = libraryPath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, libraryPath, "loop"]
        process.standardInput = Pipe()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        // The buffer belongs to this process alone. A callback already reading the
        // retiring pipe can't append bytes to the replacement's stream.
        let outputLock = NSLock()
        var buffer = Data()
        var searchStart = 0
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            outputLock.lock()
            defer { outputLock.unlock() }

            buffer.append(incoming)
            while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                searchStart = 0
                guard !line.isEmpty else { continue }

                if line == Data("NIL".utf8) {
                    DispatchQueue.main.async {
                        guard let self, let process, self.acceptsOutput(from: process) else { return }
                        self.onTrackInfoReceived?(nil)
                    }
                    continue
                }

                let decoded = Result { try JSONDecoder().decode(TrackInfo.self, from: line) }
                DispatchQueue.main.async {
                    guard let self, let process, self.acceptsOutput(from: process) else { return }
                    self.eventCount += 1
                    switch decoded {
                    case .success(let track):
                        let emitted = self.preservingArtworkIfDowngrade(track)
                        self.lastTrackInfo = emitted
                        self.onTrackInfoReceived?(emitted)
                    case .failure(let error):
                        self.onDecodingError?(error, line)
                    }

                    if self.eventCount == self.restartThreshold {
                        // Let already queued metadata through, then request one recycle.
                        DispatchQueue.main.async {
                            guard self.acceptsOutput(from: process) else { return }
                            self.retireListener(reason: "event-limit")
                        }
                    }
                }
            }
            searchStart = buffer.count
        }

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.listeningProcess === process else { return }
                let restart = self.listenerStopping && self.listeningRequested
                let notify = !self.listenerStopping && self.eventCount > 0
                self.listeningProcess = nil
                self.listenerStopping = false
                self.onListenerDiagnostic?("exited pid=\(process.processIdentifier) reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus)")
                if restart {
                    self.startListening()
                } else if notify {
                    self.onListenerTerminated?()
                }
            }
        }

        do {
            eventCount = 0
            try process.run()
            listeningProcess = process
            onListenerDiagnostic?("started pid=\(process.processIdentifier)")
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            onListenerDiagnostic?("start failed: \(error.localizedDescription)")
        }
    }

    public func stopListening() {
        listeningRequested = false
        retireListener(reason: "stop")
    }

    private func acceptsOutput(from process: Process) -> Bool {
        listeningProcess === process && !listenerStopping
    }

    private func retireListener(reason: String) {
        guard let process = listeningProcess, !listenerStopping else { return }
        listenerStopping = true
        onListenerDiagnostic?("stopping pid=\(process.processIdentifier) reason=\(reason) events=\(eventCount)")
        if process.isRunning {
            process.terminate()
        }
    }

    private func sendCommand(_ arguments: [String]) {
        guard !arguments.isEmpty else { return }
        let line = arguments.joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pipe = self.isListening ? self.listeningProcess?.standardInput as? Pipe : nil
            self.commandQueue.async {
                if let handle = pipe?.fileHandleForWriting {
                    do {
                        if #available(macOS 10.15.4, *) {
                            try handle.write(contentsOf: data)
                        } else {
                            handle.write(data)
                        }
                        return
                    } catch {
                        // Pipe closed under us; fall through to spawn.
                    }
                }
                _ = self.runPerlCommand(arguments: arguments)
            }
        }
    }

    public func play() { sendCommand(["play"]) }

    public func pause() { sendCommand(["pause"]) }

    public func togglePlayPause() { sendCommand(["toggle_play_pause"]) }

    public func nextTrack() { sendCommand(["next_track"]) }

    public func previousTrack() { sendCommand(["previous_track"]) }

    public func stop() { sendCommand(["stop"]) }

    public func setTime(seconds: Double) { sendCommand(["set_time", String(seconds)]) }

    public func toggleShuffle() { sendCommand(["toggle_shuffle"]) }

    public func toggleRepeat() { sendCommand(["toggle_repeat"]) }

    public func startForwardSeek() { sendCommand(["start_forward_seek"]) }

    public func endForwardSeek() { sendCommand(["end_forward_seek"]) }

    public func startBackwardSeek() { sendCommand(["start_backward_seek"]) }

    public func endBackwardSeek() { sendCommand(["end_backward_seek"]) }

    public func goBackFifteenSeconds() { sendCommand(["go_back_fifteen_seconds"]) }

    public func skipFifteenSeconds() { sendCommand(["skip_fifteen_seconds"]) }

    public func likeTrack() { sendCommand(["like_track"]) }

    public func banTrack() { sendCommand(["ban_track"]) }

    public func addToWishList() { sendCommand(["add_to_wish_list"]) }

    public func removeFromWishList() { sendCommand(["remove_from_wish_list"]) }

    public func setShuffleMode(_ mode: TrackInfo.ShuffleMode) {
        sendCommand(["set_shuffle_mode", String(mode.rawValue)])
    }

    public func setRepeatMode(_ mode: TrackInfo.RepeatMode) {
        sendCommand(["set_repeat_mode", String(mode.rawValue)])
    }

    private func isSameTrack(_ a: TrackInfo.Payload, _ b: TrackInfo.Payload) -> Bool {
        guard a.title == b.title, a.artist == b.artist else { return false }
        let aAlbum = a.album ?? ""
        let bAlbum = b.album ?? ""
        return aAlbum == bAlbum || aAlbum.isEmpty || bAlbum.isEmpty
    }

    private func preservingArtworkIfDowngrade(_ incoming: TrackInfo) -> TrackInfo {
        guard let previous = lastTrackInfo,
              isSameTrack(previous.payload, incoming.payload) else {
            return incoming
        }

        let previousLen = previous.payload.artworkDataBase64?.count ?? 0
        let incomingLen = incoming.payload.artworkDataBase64?.count ?? 0
        guard incomingLen < previousLen else {
            return incoming
        }

        let p = incoming.payload
        let merged = TrackInfo.Payload(
            title: p.title,
            artist: p.artist,
            album: p.album,
            isPlaying: p.isPlaying,
            durationMicros: p.durationMicros,
            elapsedTimeMicros: p.elapsedTimeMicros,
            applicationName: p.applicationName,
            bundleIdentifier: p.bundleIdentifier,
            artworkDataBase64: previous.payload.artworkDataBase64,
            artworkMimeType: previous.payload.artworkMimeType,
            timestampEpochMicros: p.timestampEpochMicros,
            PID: p.PID,
            shuffleMode: p.shuffleMode,
            repeatMode: p.repeatMode,
            playbackRate: p.playbackRate,
            artwork: previous.payload.artwork
        )
        return TrackInfo(payload: merged)
    }
}
