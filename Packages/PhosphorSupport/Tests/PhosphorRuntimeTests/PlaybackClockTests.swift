@testable import PhosphorRuntime
import Testing

@Suite("PlaybackClock")
struct PlaybackClockTests {
    private func wall(_ time: Float, _ frame: UInt32, delta: Float = 1) -> PlaybackClock.WallClock {
        PlaybackClock.WallClock(time: time, frame: frame, delta: delta)
    }

    @Test("Fresh clock passes the wall clock straight through")
    func passthrough() {
        let clock = PlaybackClock()
        let sample = clock.kernelSample(wallClock: wall(3, 5, delta: 0.5))
        #expect(sample.time == 3)
        #expect(sample.frame == 5)
        #expect(sample.delta == 0.5)
        #expect(!clock.isPaused)
    }

    @Test("kernelSample does not mutate the clock")
    func sampleIsPure() {
        let clock = PlaybackClock()
        _ = clock.kernelSample(wallClock: wall(10, 10))
        _ = clock.kernelSample(wallClock: wall(20, 20))
        let sample = clock.kernelSample(wallClock: wall(30, 30))
        #expect(sample.time == 30)
        #expect(sample.frame == 30)
    }

    @Test("Pause freezes time at the committed frame")
    func pauseFreezes() {
        var clock = PlaybackClock()
        clock.pause()
        clock.commit(wallClock: wall(5, 5))
        #expect(clock.isPaused)

        // Later wall-clock frames keep returning the snapshot.
        let a = clock.kernelSample(wallClock: wall(9, 9))
        let b = clock.kernelSample(wallClock: wall(99, 99))
        #expect(a == b)
        #expect(a.time == 5)
        #expect(a.frame == 5)
        #expect(a.delta == 0)
    }

    @Test("Pause snapshots kernel time, not wall time, after a rebase")
    func pauseRespectsRebase() {
        var clock = PlaybackClock()
        clock.reset()
        clock.commit(wallClock: wall(100, 100)) // timeBase = 100, frameBase = 100

        clock.pause()
        clock.commit(wallClock: wall(105, 105))
        let sample = clock.kernelSample(wallClock: wall(200, 200))
        #expect(sample.time == 5)
        #expect(sample.frame == 5)
    }

    @Test("Resume rebases the kernel clock to zero")
    func resumeRebasesToZero() {
        var clock = PlaybackClock()
        clock.pause()
        clock.commit(wallClock: wall(50, 50))
        clock.resume()
        clock.commit(wallClock: wall(60, 60))
        #expect(!clock.isPaused)
        let sample = clock.kernelSample(wallClock: wall(60, 60))
        #expect(sample.time == 0)
        #expect(sample.frame == 0)
    }

    @Test("Reset zeros the kernel clock and clears pause")
    func resetZerosAndClearsPause() {
        var clock = PlaybackClock()
        clock.pause()
        clock.commit(wallClock: wall(40, 40))
        #expect(clock.isPaused)

        clock.reset()
        clock.commit(wallClock: wall(70, 70))
        #expect(!clock.isPaused)
        let sample = clock.kernelSample(wallClock: wall(70, 70))
        #expect(sample.time == 0)
        #expect(sample.frame == 0)
    }

    @Test("Frame counter wraps using unsigned subtraction")
    func frameWrap() {
        var clock = PlaybackClock()
        clock.reset()
        clock.commit(wallClock: wall(0, .max)) // frameBase = UInt32.max
        let sample = clock.kernelSample(wallClock: wall(0, 1))
        // 1 &- UInt32.max == 2
        #expect(sample.frame == 2)
    }
}
