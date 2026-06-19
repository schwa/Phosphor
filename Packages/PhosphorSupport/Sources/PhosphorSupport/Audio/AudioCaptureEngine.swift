import AVFoundation
import Foundation
import Observation
import os

/// Owns a single AVAudioEngine input tap and a small ring buffer of the most
/// recent mono Float32 audio samples. Exposes the latest `N` samples on
/// demand so the runtime can copy them into the GPU waveform buffer each
/// frame.
///
/// One instance per app — provided via the SwiftUI environment so the
/// document UI can drive the toggle from a toolbar item.
@MainActor
@Observable
public final class AudioCaptureEngine {
    /// User-facing on/off. Setting to `true` starts the engine (after
    /// requesting permission); setting to `false` stops it and zeros the
    /// ring buffer.
    public var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled else { return }
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
    private let lock = NSLock()
    /// Allocated as raw memory so we can read it without main-actor isolation.
    nonisolated(unsafe) private let ring: UnsafeMutableBufferPointer<Float>
    /// Write head — index of the next sample slot in `ring`.
    @ObservationIgnored
    nonisolated(unsafe) private var head: Int = 0
    /// `isRunning` mirrored as a nonisolated flag so the render loop can
    /// check without bouncing through the main actor.
    @ObservationIgnored
    nonisolated(unsafe) private var _isRunningNonisolated: Bool = false
    /// Sample-rate the input tap is using. We retain it so the FFT step
    /// (#35) can convert bin indices to Hz.
    public private(set) var sampleRate: Double = 0

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "audio")

    public init(sampleCount: Int = 1024) {
        self.sampleCount = sampleCount
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: sampleCount)
        buffer.initialize(repeating: 0)
        self.ring = buffer
    }

    deinit {
        ring.deinitialize()
        ring.deallocate()
    }

    /// Snapshot of `isRunning` safe to read from any thread (including the
    /// Metal render loop).
    nonisolated public var isRunningNonisolated: Bool { _isRunningNonisolated }

    // MARK: - Snapshot

    /// Copies the most-recent `sampleCount` samples into `destination` in
    /// the order they were captured (oldest → newest).
    ///
    /// Thread-safe and nonisolated; intended for the render loop. Returns
    /// the same data as a no-op if the engine isn't running (zeros after stop).
    nonisolated public func copyLatestSamples(into destination: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let base = ring.baseAddress!
        let tail = sampleCount - head
        destination.update(from: base.advanced(by: head), count: tail)
        if head > 0 {
            destination.advanced(by: tail).update(from: base, count: head)
        }
    }

    // MARK: - Engine lifecycle

    private func startIfPermitted() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                start()
            } else {
                isPermissionDenied = true
                isEnabled = false
            }
        case .authorized:
            start()
        case .denied, .restricted:
            isPermissionDenied = true
            isEnabled = false
        @unknown default:
            isPermissionDenied = true
            isEnabled = false
        }
    }

    private func start() {
        guard !engine.isRunning else { return }
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate

        // Reset the ring on every start so we never serve stale samples
        // captured before the user turned the toggle off.
        lock.lock()
        ring.update(repeating: 0)
        head = 0
        lock.unlock()

        inputNode.removeTap(onBus: 0)
        // TODO: switch to the macOS 27 variant once it's exposed in Swift.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
        }

        do {
            try engine.start()
            isRunning = true
            _isRunningNonisolated = true
            Self.logger.info("audio engine started, sampleRate=\(format.sampleRate, privacy: .public)")
        } catch {
            Self.logger.error("audio engine start failed: \(error, privacy: .public)")
            isRunning = false
            _isRunningNonisolated = false
            isEnabled = false
        }
    }

    private func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        _isRunningNonisolated = false
        lock.lock()
        ring.update(repeating: 0)
        head = 0
        lock.unlock()
    }

    nonisolated private func append(buffer: AVAudioPCMBuffer) {
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
