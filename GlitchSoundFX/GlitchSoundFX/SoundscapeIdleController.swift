import AVFAudio
import Foundation

@MainActor
final class SoundscapeIdleController {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let isRunning: () -> Bool
    private let pause: () -> Void
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var playbacks: [Int: UInt64] = [:]
    private var delay: TimeInterval?
    private var soundEnabled = true
    private(set) var isInteractionActive = false

    init(isRunning: @escaping () -> Bool, pause: @escaping () -> Void,
         sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }) {
        self.isRunning = isRunning
        self.pause = pause
        self.sleep = sleep
    }

    static func validatedDelay(_ delay: TimeInterval?) -> TimeInterval? {
        guard let delay, delay.isFinite, delay > 0, delay <= 86_400 else { return nil }
        return delay
    }

    func configure(delay: TimeInterval?, soundEnabled: Bool) {
        self.delay = Self.validatedDelay(delay)
        self.soundEnabled = soundEnabled
        refresh()
    }

    func setInteractionActive(_ active: Bool) {
        guard isInteractionActive != active else { return }
        isInteractionActive = active
        refresh()
    }

    func playbackStarted(voice: Int, token: UInt64) {
        playbacks[voice] = token
        refresh()
    }

    func playbackFinished(voice: Int, token: UInt64) {
        guard playbacks[voice] == token else { return }
        playbacks[voice] = nil
        refresh()
    }

    func isPlaying(voice: Int) -> Bool { playbacks[voice] != nil }

    func resetPlaybacks() {
        playbacks.removeAll(keepingCapacity: true)
        refresh()
    }

    private var canPause: Bool {
        delay != nil && isRunning() && playbacks.isEmpty && (!isInteractionActive || !soundEnabled)
    }

    func refresh() {
        task?.cancel()
        task = nil
        generation &+= 1
        guard canPause, let delay else { return }
        let scheduledGeneration = generation
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.generation == scheduledGeneration, self.canPause else { return }
            self.task = nil
            self.pause()
        }
    }

    deinit { task?.cancel() }
}

final class SoundscapeConfigurationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var changeGeneration: UInt64 = 0
    private var token: NSObjectProtocol?

    var generation: UInt64 { lock.withLock { changeGeneration } }

    init(engine: AVAudioEngine, changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                       object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.changeGeneration &+= 1 }
            changed()
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
