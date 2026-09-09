import Foundation
import Testing
@testable import GlitchSoundFX

private final class ManualAudioSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [CheckedContinuation<Void, Never>] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return waits.count
    }

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            waits.append(continuation)
            lock.unlock()
        }
    }

    func releaseAll() {
        lock.lock()
        let pending = waits
        waits.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

@Suite("Idle sound engine lifecycle", .serialized)
@MainActor
struct SoundscapeIdleControllerTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }

    @Test func pausesOnlyAfterTheIdleWait() async throws {
        let clock = ManualAudioSleep()
        var pauses = 0
        let controller = SoundscapeIdleController(isRunning: { true }, pause: { pauses += 1 }, sleep: { await clock.sleep($0) })
        controller.configure(delay: 30, soundEnabled: true)
        try await settle()
        #expect(clock.count == 1)
        #expect(pauses == 0)
        clock.releaseAll()
        try await settle()
        #expect(pauses == 1)
    }

    @Test func activeSurfaceCancelsAnExpiredQueuedWait() async throws {
        let clock = ManualAudioSleep()
        var pauses = 0
        let controller = SoundscapeIdleController(isRunning: { true }, pause: { pauses += 1 }, sleep: { await clock.sleep($0) })
        controller.configure(delay: 30, soundEnabled: true)
        try await settle()
        clock.releaseAll()
        controller.setInteractionActive(true)
        try await settle()
        #expect(pauses == 0)
        #expect(clock.count == 0)
        controller.setInteractionActive(false)
        try await settle()
        #expect(clock.count == 1)
        clock.releaseAll()
        try await settle()
        #expect(pauses == 1)
    }

    @Test func waitsForEveryPlayingVoice() async throws {
        let clock = ManualAudioSleep()
        var pauses = 0
        let controller = SoundscapeIdleController(isRunning: { true }, pause: { pauses += 1 }, sleep: { await clock.sleep($0) })
        controller.playbackStarted(voice: 0, token: 1)
        controller.playbackStarted(voice: 1, token: 2)
        controller.configure(delay: 0.01, soundEnabled: true)
        controller.playbackFinished(voice: 0, token: 1)
        try await settle()
        #expect(clock.count == 0)
        #expect(pauses == 0)
        controller.playbackFinished(voice: 1, token: 2)
        try await settle()
        #expect(clock.count == 1)
        clock.releaseAll()
        try await settle()
        #expect(pauses == 1)
    }

    @Test func staleVoiceCompletionCannotFinishANewerCue() async throws {
        let clock = ManualAudioSleep()
        let controller = SoundscapeIdleController(isRunning: { true }, pause: {}, sleep: { await clock.sleep($0) })
        controller.playbackStarted(voice: 0, token: 1)
        controller.playbackStarted(voice: 0, token: 2)
        controller.configure(delay: 30, soundEnabled: true)
        controller.playbackFinished(voice: 0, token: 1)
        try await settle()
        #expect(controller.isPlaying(voice: 0))
        #expect(clock.count == 0)
        controller.playbackFinished(voice: 0, token: 2)
        try await settle()
        #expect(clock.count == 1)
        clock.releaseAll()
    }

    @Test func mutedForegroundAudioStillFinishesItsCue() async throws {
        let clock = ManualAudioSleep()
        var pauses = 0
        let controller = SoundscapeIdleController(isRunning: { true }, pause: { pauses += 1 }, sleep: { await clock.sleep($0) })
        controller.setInteractionActive(true)
        controller.playbackStarted(voice: 0, token: 1)
        controller.configure(delay: 30, soundEnabled: false)
        try await settle()
        #expect(clock.count == 0)
        controller.playbackFinished(voice: 0, token: 1)
        try await settle()
        clock.releaseAll()
        try await settle()
        #expect(pauses == 1)
    }

    @Test func disablingPolicyCancelsPendingPause() async throws {
        let clock = ManualAudioSleep()
        var pauses = 0
        let controller = SoundscapeIdleController(isRunning: { true }, pause: { pauses += 1 }, sleep: { await clock.sleep($0) })
        controller.configure(delay: 30, soundEnabled: true)
        try await settle()
        controller.configure(delay: nil, soundEnabled: true)
        clock.releaseAll()
        try await settle()
        #expect(pauses == 0)
    }

    @Test func rejectsInvalidDelaysAndNeverStartsAnIdleTimerForAStoppedEngine() async throws {
        for value in [0.0, -1, .nan, .infinity, 86_401] {
            #expect(SoundscapeIdleController.validatedDelay(value) == nil)
        }
        #expect(SoundscapeIdleController.validatedDelay(30) == 30)
        let clock = ManualAudioSleep()
        let controller = SoundscapeIdleController(isRunning: { false }, pause: {}, sleep: { await clock.sleep($0) })
        controller.configure(delay: 30, soundEnabled: true)
        try await settle()
        #expect(clock.count == 0)
    }

    @Test func pendingWaitDoesNotRetainItsOwner() async throws {
        let clock = ManualAudioSleep()
        var pauses = 0
        var controller: SoundscapeIdleController? = SoundscapeIdleController(isRunning: { true }, pause: { pauses += 1 }, sleep: { await clock.sleep($0) })
        weak var weakController = controller
        controller?.configure(delay: 30, soundEnabled: true)
        try await settle()
        controller = nil
        #expect(weakController == nil)
        clock.releaseAll()
        try await settle()
        #expect(pauses == 0)
    }

    @Test func engineResetInvalidatesOldCompletions() async throws {
        let clock = ManualAudioSleep()
        var running = true
        let controller = SoundscapeIdleController(isRunning: { running }, pause: {}, sleep: { await clock.sleep($0) })
        controller.playbackStarted(voice: 0, token: 1)
        controller.configure(delay: 30, soundEnabled: true)
        running = false
        controller.resetPlaybacks()
        running = true
        controller.playbackStarted(voice: 0, token: 2)
        controller.playbackFinished(voice: 0, token: 1)
        try await settle()
        #expect(controller.isPlaying(voice: 0))
        #expect(clock.count == 0)
    }
}
