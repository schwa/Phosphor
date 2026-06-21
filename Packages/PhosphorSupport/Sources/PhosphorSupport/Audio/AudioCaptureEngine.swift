import AVFoundation
import Foundation
import Observation
import os

/// Owns a single AVAudioEngine input tap and a small ring buffer of the most
/// recent mono Float32 audio samples. Exposes the latest `N` samples on
/// demand so the runtime can copy them into the GPU waveform buffer each
/// frame.
///
/// One instance per app — provided via the SwiftUI configuration so the
/// document UI can drive the toggle from a toolbar item.
@preconcurrency
@MainActor
@Observable
public final class AudioCaptureEngine {
    /// User-facing on/off. Setting to `true` starts the engine (after
    /// requesting permission); setting to `false` stops it and zeros the
    /// ring buffer.
    public var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled else { return }
            Self.logger.info("isEnabled \(oldValue, privacy: .public) -> \(self.isEnabled, privacy: .public)")
            if isEnabled {
                Task { await startIfPermitted() }
            } else {
                stop()
            }
        }
    }

    /// `true` once we've asked the system for permission and been denied.
    /// The toolbar should disable its toggle with explanatory help text.
    public private(set) var isPermissionDenied: Bool = false

    /// Reflects whether the underlying AVAudioEngine is currently running.
    public private(set) var isRunning: Bool = false

    /// Number of mono Float32 samples held by the ring buffer. Matches the
    /// runtime's `waveformBuffer` length so a single memcpy fills it each
    /// frame.
    public let sampleCount: Int

    private let engine = AVAudioEngine()
    /// Holds the ring buffer + lock + running flag. Lives in its own non-
    /// actor-isolated type so the AVAudioEngine tap block (which runs on a
    /// real-time audio thread, not the main actor) can write into it
    /// without tripping Swift Concurrency's isolation assertions.
    @ObservationIgnored
    private let storage: AudioRingStorage
    /// Sample-rate the input tap is using. We retain it so the FFT step
    /// (#35) can convert bin indices to Hz.
    public private(set) var sampleRate: Double = 0

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "audio")

    public init(sampleCount: Int = 1_024) {
        self.sampleCount = sampleCount
        self.storage = AudioRingStorage(sampleCount: sampleCount)
    }

    /// Snapshot of `isRunning` safe to read from any thread (including the
    /// Metal render loop).
    nonisolated public var isRunningNonisolated: Bool { storage.isRunning }

    // MARK: - Snapshot

    /// Copies the most-recent `sampleCount` samples into `destination` in
    /// the order they were captured (oldest → newest).
    nonisolated public func copyLatestSamples(into destination: UnsafeMutablePointer<Float>) {
        storage.copyLatestSamples(into: destination)
    }

    // MARK: - Engine lifecycle

    private func startIfPermitted() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.logger.info("startIfPermitted: status=\(String(describing: status), privacy: .public)")
        switch status {
        case .notDetermined:
            Self.logger.info("requesting microphone access…")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Self.logger.info("microphone access \(granted ? "granted" : "denied", privacy: .public)")
            if granted {
                start()
            } else {
                isPermissionDenied = true
                isEnabled = false
            }

        case .authorized:
            Self.logger.info("microphone already authorized")
            start()

        case .denied, .restricted:
            Self.logger.error("microphone permission denied or restricted at system level")
            isPermissionDenied = true
            isEnabled = false

        @unknown default:
            Self.logger.error("microphone permission unknown status")
            isPermissionDenied = true
            isEnabled = false
        }
    }

    private func start() {
        guard !engine.isRunning else { return }
        Self.logger.info("start()")
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        Self.logger.info("input format: sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")

        storage.reset()

        inputNode.removeTap(onBus: 0)
        installNonisolatedTap(on: inputNode, format: format, storage: storage)

        do {
            try engine.start()
            isRunning = true
            storage.isRunning = true
            Self.logger.info("audio engine started, sampleRate=\(format.sampleRate, privacy: .public)")
        } catch {
            Self.logger.error("audio engine start failed: \(error, privacy: .public)")
            isRunning = false
            storage.isRunning = false
            isEnabled = false
        }
    }

    private func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        storage.isRunning = false
        storage.reset()
    }
}

/// Installs the AVAudioEngine tap block as a free, fully-nonisolated function
/// so the closure created here does NOT inherit `@MainActor` isolation from
/// ``AudioCaptureEngine``. The audio engine invokes the tap block on a
/// real-time audio thread; if the closure were main-actor-isolated, Swift
/// Concurrency's executor-check would fire and crash the process.
// TODO: switch to the macOS 27 variant once it's exposed in Swift.
private func installNonisolatedTap(on inputNode: AVAudioInputNode, format: AVAudioFormat, storage: AudioRingStorage) {
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        storage.append(buffer: buffer)
    }
}

/// Non-actor-isolated ring buffer + lock + flag, holding the bits the
/// AVAudioEngine tap block needs to touch without going through any actor.
private final class AudioRingStorage: @unchecked Sendable {
    let sampleCount: Int
    private let lock = NSLock()
    private let ring: UnsafeMutableBufferPointer<Float>
    private var head: Int = 0
    /// Treat as atomic-ish: only written from main, read from anywhere.
    /// NSLock-guarded inside `copyLatestSamples` but raw elsewhere; small
    /// races on this flag are benign.
    var isRunning: Bool = false

    init(sampleCount: Int) {
        self.sampleCount = sampleCount
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: sampleCount)
        buffer.initialize(repeating: 0)
        self.ring = buffer
    }

    deinit {
        ring.deinitialize()
        ring.deallocate()
    }

    func reset() {
        lock.lock()
        ring.update(repeating: 0)
        head = 0
        lock.unlock()
    }

    func copyLatestSamples(into destination: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let base = ring.baseAddress!
        let tail = sampleCount - head
        destination.update(from: base.advanced(by: head), count: tail)
        if head > 0 {
            destination.advanced(by: tail).update(from: base, count: head)
        }
    }

    func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = channelData[0]
        let base = ring.baseAddress!

        lock.lock()
        defer { lock.unlock() }
        var src = 0
        while src < frameCount {
            let remaining = frameCount - src
            let writable = min(remaining, sampleCount - head)
            base.advanced(by: head).update(from: samples + src, count: writable)
            head = (head + writable) % sampleCount
            src += writable
        }
    }
}
