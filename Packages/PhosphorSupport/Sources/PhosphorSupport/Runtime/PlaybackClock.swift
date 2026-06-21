import Foundation

/// Translates a free-running wall clock (the renderer's monotonic time/frame)
/// into the *kernel* time/frame a shader sees, applying pause and reset.
///
/// ## Two-phase use
///
/// MetalSprockets' `@ElementBuilder` closures must not mutate state, so reading
/// the clock and advancing it are separate steps:
///
/// 1. ``kernelSample(wallClock:)`` — pure read, safe inside an element builder.
///    Returns the time/frame/delta the kernel should use this frame.
/// 2. ``commit(wallClock:)`` — mutating, called from a side-effect hook
///    (e.g. `.onWorkloadEnter`). Applies any pending pause snapshot or rebase.
///
/// ## Events
///
/// ``pause()``, ``resume()``, and ``reset()`` record an intent that takes
/// effect on the next ``commit(wallClock:)``. This deferral is what lets the
/// snapshot/rebase be computed from a live wall-clock sample.
public struct PlaybackClock: Equatable, Sendable {
    /// A reading of the renderer's free-running clock.
    public struct WallClock: Equatable, Sendable {
        public var time: Float
        public var frame: UInt32
        public var delta: Float

        public init(time: Float, frame: UInt32, delta: Float) {
            self.time = time
            self.frame = frame
            self.delta = delta
        }
    }

    /// The kernel-facing time/frame/delta for a single frame.
    public struct Sample: Equatable, Sendable {
        public var time: Float
        public var frame: Float
        public var delta: Float

        public init(time: Float, frame: Float, delta: Float) {
            self.time = time
            self.frame = frame
            self.delta = delta
        }
    }

    /// Subtracted from the wall clock to produce kernel values.
    private var timeBase: Float = 0
    private var frameBase: UInt32 = 0

    /// When set, playback is frozen at this kernel time/frame.
    private var pausedSnapshot: Sample?

    /// Pending intents, applied on the next ``commit(wallClock:)``.
    private var captureSnapshotPending = false
    private var rebasePending = false

    public init() {}

    /// Whether playback is currently frozen.
    public var isPaused: Bool { pausedSnapshot != nil }

    /// The kernel sample for this frame, without mutating the clock.
    ///
    /// Safe to call from inside an element-builder closure.
    public func kernelSample(wallClock: WallClock) -> Sample {
        if let paused = pausedSnapshot {
            return Sample(time: paused.time, frame: paused.frame, delta: 0)
        }
        return Sample(
            time: wallClock.time - timeBase,
            frame: Float(wallClock.frame &- frameBase),
            delta: wallClock.delta
        )
    }

    /// Applies any pending pause snapshot or rebase. Call once per frame from a
    /// side-effect hook, after ``kernelSample(wallClock:)`` has been read.
    public mutating func commit(wallClock: WallClock) {
        if captureSnapshotPending {
            pausedSnapshot = Sample(
                time: wallClock.time - timeBase,
                frame: Float(wallClock.frame &- frameBase),
                delta: 0
            )
            captureSnapshotPending = false
        }
        if rebasePending {
            timeBase = wallClock.time
            frameBase = wallClock.frame
            rebasePending = false
        }
    }

    /// Freezes playback at the next committed frame.
    public mutating func pause() {
        captureSnapshotPending = true
    }

    /// Resumes playback. Rebases the kernel clock to zero on the next commit
    /// (matching the pre-extraction behavior).
    public mutating func resume() {
        pausedSnapshot = nil
        rebasePending = true
    }

    /// Restarts the kernel clock from zero. Clears any pause.
    public mutating func reset() {
        pausedSnapshot = nil
        captureSnapshotPending = false
        rebasePending = true
    }
}
