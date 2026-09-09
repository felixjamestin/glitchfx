import AVFAudio
import Combine
import Foundation

#if os(iOS)
import UIKit
#endif

/// A shared, lazy interaction-sound engine. Safe to call repeatedly from SwiftUI actions.
@MainActor
public final class Soundscape: ObservableObject {
    public static let shared = Soundscape()

    public struct Configuration: Sendable, Equatable {
        public enum AudioPolicy: Sendable, Equatable {
            /// Recommended for interaction sounds. Obeys the silent switch and mixes with other audio.
            case respectSilentMode
            /// Appropriate only when audio is central to the experience.
            case playInSilentMode
        }

        public var isSoundEnabled: Bool
        public var isHapticsEnabled: Bool
        public var volume: Float
        public var variation: Double
        public var defaultTheme: SoundTheme
        public var audioPolicy: AudioPolicy
        /// Pauses an inactive engine after this many seconds without a playing cue.
        /// Use nil to disable; valid delays are greater than zero and at most one day.
        public var idlePauseDelay: TimeInterval?

        public init(
            isSoundEnabled: Bool = true,
            isHapticsEnabled: Bool = true,
            volume: Float = 0.8,
            variation: Double = 0.72,
            defaultTheme: SoundTheme = .tactile,
            audioPolicy: AudioPolicy = .respectSilentMode,
            idlePauseDelay: TimeInterval? = nil
        ) {
            self.isSoundEnabled = isSoundEnabled
            self.isHapticsEnabled = isHapticsEnabled
            self.volume = min(max(volume, 0), 1)
            self.variation = min(max(variation, 0), 1)
            self.defaultTheme = defaultTheme
            self.audioPolicy = audioPolicy
            self.idlePauseDelay = idlePauseDelay
        }
    }

    @Published public private(set) var configuration: Configuration

    private struct CacheKey: Hashable {
        var id: String
        var variation: Int
        var amountBucket: Int
    }

    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var voiceAvailableAt: [TimeInterval] = []
    private var cache: [CacheKey: AVAudioPCMBuffer] = [:]
    private var lastVariation: [String: Int] = [:]
    private var lastPlayTime: [String: TimeInterval] = [:]
    private var isAudioSessionConfigured = false
    private var playbackToken: UInt64 = 0
    private var configurationObservation: SoundscapeConfigurationObservation?
    private var handledConfigurationGeneration: UInt64 = 0
    private lazy var idleController = SoundscapeIdleController(
        isRunning: { [weak self] in self?.engine.isRunning == true },
        pause: { [weak self] in self?.engine.pause() }
    )

    public init(configuration: Configuration = .init(), voiceCount: Int = 16) {
        self.configuration = configuration
        let format = AVAudioFormat(
            standardFormatWithSampleRate: SoundRenderer.sampleRate,
            channels: 1
        )
        for _ in 0..<max(voiceCount, 2) {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
            voiceAvailableAt.append(0)
        }
        engine.mainMixerNode.outputVolume = configuration.volume
        idleController.configure(delay: configuration.idlePauseDelay, soundEnabled: configuration.isSoundEnabled)
        configurationObservation = SoundscapeConfigurationObservation(engine: engine) { [weak self] in
            Task { @MainActor [weak self] in self?.engineConfigurationChanged() }
        }
    }

    public func configure(_ configuration: Configuration) {
        let needsNewVariants = self.configuration.variation != configuration.variation
        let policyChanged = self.configuration.audioPolicy != configuration.audioPolicy
        self.configuration = configuration
        engine.mainMixerNode.outputVolume = configuration.volume
        if needsNewVariants { cache.removeAll(keepingCapacity: true) }
        if policyChanged { isAudioSessionConfigured = false }
        idleController.configure(delay: configuration.idlePauseDelay, soundEnabled: configuration.isSoundEnabled)
        if configuration.isSoundEnabled, idleController.isInteractionActive { prewarm() }
    }

    /// Keeps audio ready while an interaction surface is active.
    /// Release this state when the last interaction surface becomes inactive.
    public func setInteractionActive(_ active: Bool) {
        idleController.setInteractionActive(active)
        if active { prewarm() }
    }

    /// Starts audio processing before the next cue and retains the existing sample cache.
    @discardableResult
    public func prewarm() -> Bool {
        guard configuration.isSoundEnabled else { return false }
        configureAudioSessionIfNeeded()
        let ready = startEngineIfNeeded()
        idleController.refresh()
        return ready
    }

    /// Plays one of the built-in cues. The renderer picks a different one of 12 subtle variants.
    public func play(
        _ cue: SoundCue,
        theme: SoundTheme? = nil,
        intensity: Double = 1,
        horizontalLocation: Double? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        let selectedTheme = theme ?? configuration.defaultTheme
        let themedID = "\(selectedTheme.rawValue).\(cue.rawValue)"
        play(
            recipe: selectedTheme.recipe(for: cue),
            id: themedID,
            haptic: cue.haptic,
            intensity: intensity,
            horizontalLocation: horizontalLocation,
            minimumInterval: minimumInterval
        )
    }

    /// Plays an app-specific recipe while retaining the framework's variation and haptic behavior.
    public func play(
        recipe: SoundRecipe,
        id: String,
        haptic: SoundHaptic = .light,
        intensity: Double = 1,
        horizontalLocation: Double? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPlayTime[id], now - last < minimumInterval { return }
        lastPlayTime[id] = now

        if configuration.isHapticsEnabled {
            playHaptic(haptic, intensity: intensity)
        }
        guard configuration.isSoundEnabled else { return }

        configureAudioSessionIfNeeded()
        guard startEngineIfNeeded() else { return }
        defer { idleController.refresh() }

        let variationIndex = nextVariation(for: id)
        let amountBucket = Int((configuration.variation * 20).rounded())
        let key = CacheKey(id: id, variation: variationIndex, amountBucket: amountBucket)
        let buffer: AVAudioPCMBuffer
        if let cached = cache[key] {
            buffer = cached
        } else if let rendered = SoundRenderer.render(
            recipe: recipe,
            id: id,
            variationIndex: variationIndex,
            variationAmount: configuration.variation
        ) {
            cache[key] = rendered
            buffer = rendered
        } else {
            return
        }

        let variation = VariationGenerator.make(
            id: id,
            index: variationIndex,
            amount: configuration.variation,
            horizontalLocation: horizontalLocation
        )
        let bufferDuration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard let voiceIndex = availableVoiceIndex(at: ProcessInfo.processInfo.systemUptime) else {
            // Dropping extreme overlap is cleaner than truncating a waveform mid-cycle.
            return
        }
        let voice = voices[voiceIndex]
        playbackToken &+= 1
        let token = playbackToken
        idleController.playbackStarted(voice: voiceIndex, token: token)
        voice.stop()
        voice.volume = Float(min(max(intensity, 0), 1)) * variation.gainMultiplier
        voice.pan = variation.pan
        voice.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.idleController.playbackFinished(voice: voiceIndex, token: token)
            }
        }
        voice.play()
        voiceAvailableAt[voiceIndex] = ProcessInfo.processInfo.systemUptime + bufferDuration + 0.01
    }

    /// Warms the cache for a palette. This is optional; normal playback is already lazy.
    public func prepare(
        _ cues: [SoundCue] = SoundCue.allCases,
        themes: [SoundTheme]? = nil
    ) {
        for theme in themes ?? [configuration.defaultTheme] {
            for cue in cues {
                let themedID = "\(theme.rawValue).\(cue.rawValue)"
                for variationIndex in 0..<VariationGenerator.count {
                    let amountBucket = Int((configuration.variation * 20).rounded())
                    let key = CacheKey(
                        id: themedID,
                        variation: variationIndex,
                        amountBucket: amountBucket
                    )
                    if cache[key] == nil {
                        cache[key] = SoundRenderer.render(
                            recipe: theme.recipe(for: cue),
                            id: themedID,
                            variationIndex: variationIndex,
                            variationAmount: configuration.variation
                        )
                    }
                }
            }
        }
    }

    private func availableVoiceIndex(at time: TimeInterval) -> Int? {
        voiceAvailableAt.indices.first { voiceAvailableAt[$0] <= time && !idleController.isPlaying(voice: $0) }
    }

    private func engineConfigurationChanged() {
        guard recoverPendingConfigurationChange() else { return }
        if configuration.isSoundEnabled, idleController.isInteractionActive { prewarm() }
    }

    @discardableResult
    private func recoverPendingConfigurationChange() -> Bool {
        guard let generation = configurationObservation?.generation,
              generation != handledConfigurationGeneration else { return false }
        handledConfigurationGeneration = generation
        for voice in voices { voice.stop() }
        voiceAvailableAt = Array(repeating: 0, count: voices.count)
        idleController.resetPlaybacks()
        return true
    }

    private func nextVariation(for id: String) -> Int {
        let previous = lastVariation[id]
        var candidate = Int.random(in: 0..<VariationGenerator.count)
        if candidate == previous {
            candidate = (candidate + Int.random(in: 1..<VariationGenerator.count))
                % VariationGenerator.count
        }
        lastVariation[id] = candidate
        return candidate
    }

    private func startEngineIfNeeded() -> Bool {
        recoverPendingConfigurationChange()
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func configureAudioSessionIfNeeded() {
        #if os(iOS)
        guard !isAudioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            switch configuration.audioPolicy {
            case .respectSilentMode:
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            case .playInSilentMode:
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            isAudioSessionConfigured = true
        } catch {
            // Interaction audio should fail quietly and never block the primary action.
        }
        #endif
    }

    private func playHaptic(_ haptic: SoundHaptic, intensity: Double) {
        #if os(iOS)
        let clampedIntensity = CGFloat(min(max(intensity, 0), 1))
        switch haptic {
        case .none:
            break
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: clampedIntensity)
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: clampedIntensity)
        case .rigid:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: clampedIntensity)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}

public enum SoundHaptic: Sendable, Equatable {
    case none
    case selection
    case light
    case medium
    case rigid
    case success
    case warning
    case error
}

private extension SoundCue {
    var haptic: SoundHaptic {
        switch self {
        case .tick, .release, .select: .selection
        case .press, .open, .close, .forward, .backward, .bloom: .light
        case .toggleOn, .toggleOff, .confirm, .notify, .sparkle: .medium
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .delete: .rigid
        }
    }
}
