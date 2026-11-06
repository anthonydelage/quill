import AVFoundation
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
///
/// AVAudioEngine stops for good when the input goes away: sleep, a lid
/// close, a device unplugged or a default-input switch. A config-change
/// observer and a no-audio watchdog rebuild the engine on the current default
/// input and keep appending to the same file, so a meeting that spans a sleep
/// keeps its mic track. The sleep itself is not in the track (nor in the
/// system track, which pauses too).
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// The file's processing format (mono Float32 at the rate the file was
    /// created with). Restarts convert whatever the new input delivers to it.
    private var fileFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var watchdog: Timer?
    /// Wall-clock time of the newest buffer, written from the tap callback.
    private let bufferClock = NSLock()
    private var lastBufferAt = Date.distantPast
    /// Logs only the first failure of a restart streak, not every retry.
    private var restartFailing = false

    /// Seconds without a buffer before the watchdog rebuilds the engine. A
    /// running input delivers buffers even in silence, so a gap means capture
    /// stopped.
    private static let stallSeconds: TimeInterval = 5

    /// Start capturing the mic, encoding AAC into `url` (.caf). The packet
    /// table is written by stop(); until then the file isn't readable.
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        try attach(voiceProcessing: Config.micVoiceProcessing())
        isRecording = true
        startWatchdog()
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        watchdog?.invalidate()
        watchdog = nil
        stopObservingConfiguration()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        fileFormat = monoFormat
        do {
            file = try AVAudioFile(
                forWriting: url!,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        markBuffer()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }
        observeConfiguration()

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.markBuffer()

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and convert to the file's
    /// mono format. At start the rates match and a one-shot convert applies;
    /// after a restart the new device may run at another rate (a headset at
    /// 24 kHz into a 48 kHz file), which needs the streaming resampler.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        let ratio = monoFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.markBuffer()
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else {
                return
            }
            do {
                if ratio == 1 {
                    try converter.convert(to: mono, from: buffer)
                } else {
                    // The input block runs synchronously inside convert(),
                    // on this thread, so these captures never race.
                    nonisolated(unsafe) var fed = false
                    nonisolated(unsafe) let source = buffer
                    var convertError: NSError?
                    let status = converter.convert(to: mono, error: &convertError) { _, inputStatus in
                        if fed {
                            inputStatus.pointee = .noDataNow
                            return nil
                        }
                        fed = true
                        inputStatus.pointee = .haveData
                        return source
                    }
                    if status == .error, let convertError { throw convertError }
                }
                if mono.frameLength > 0 {
                    try file.write(from: mono)
                }
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    // MARK: - Recovery

    private func markBuffer() {
        bufferClock.lock()
        lastBufferAt = Date()
        bufferClock.unlock()
    }

    private func secondsSinceLastBuffer() -> TimeInterval {
        bufferClock.lock()
        defer { bufferClock.unlock() }
        return Date().timeIntervalSince(lastBufferAt)
    }

    /// The engine posts this and stops itself when its input or output
    /// hardware changes underneath it.
    private func observeConfiguration() {
        stopObservingConfiguration()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restart(reason: "audio configuration changed")
        }
    }

    private func stopObservingConfiguration() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
    }

    /// Catches what the notification misses: sleep stops the engine without
    /// one. Timers don't fire while asleep, so the first check after wake
    /// sees the stall.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            let quiet = self.secondsSinceLastBuffer()
            if quiet >= Self.stallSeconds {
                self.restart(reason: "no mic audio for \(Int(quiet))s")
            }
        }
    }

    /// Rebuild the engine on the current default input and keep appending to
    /// the same file. Always raw: the voice-processing liveness fallback
    /// replaces the file, which mid-session would destroy what's recorded.
    /// A failed restart (no input device yet) is retried by the watchdog.
    private func restart(reason: String) {
        guard isRecording, file != nil, let fileFormat else { return }
        stopObservingConfiguration()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Restart the stall clock, so a failure retries after stallSeconds
        // rather than on every watchdog tick.
        markBuffer()

        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        do {
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecorderError.formatUnsupported(inputFormat)
            }
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: fileFormat)
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw RecorderError.engineStartFailed(error)
            }
        } catch {
            if !restartFailing {
                FileHandle.standardError.write(Data(
                    "mic restart failed (\(reason)): \(error) — retrying\n".utf8
                ))
            }
            restartFailing = true
            return
        }
        restartFailing = false
        observeConfiguration()
        FileHandle.standardError.write(Data(
            "mic restarted (\(reason)) · input=\(inputFormat)\n".utf8
        ))
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        firstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
