import CoreHaptics
import Flutter

/// Renders one music pulse at a time; Dart owns timing against playback.
final class MusicHapticsBridge {
    private let channel: FlutterMethodChannel
    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/haptics", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "pulse" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let arguments = call.arguments as? [String: Any]
            let intensity = (arguments?["intensity"] as? Double) ?? 0
            let sharpness = (arguments?["sharpness"] as? Double) ?? 0
            self?.pulse(intensity: Float(min(max(intensity, 0), 1)), sharpness: Float(min(max(sharpness, 0), 1)))
            result(nil)
        }
    }

    private func pulse(intensity: Float, sharpness: Float) {
        guard supported, intensity > 0 else { return }
        do {
            let engine = try self.engine ?? start()
            // Auto-shutdown leaves the engine reusable but stopped. Restart
            // before the first beat, rather than losing that beat to an error.
            try engine.start()
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0
            )
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A stopped or interrupted engine is recreated on the next beat.
            engine = nil
        }
    }

    private func start() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        // Music already owns the audio session; never route audio here.
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { [weak self, weak engine] reason in
            guard reason != .idleTimeout else { return }
            DispatchQueue.main.async {
                guard let self, self.engine === engine else { return }
                self.engine = nil
            }
        }
        engine.resetHandler = { [weak self, weak engine] in
            DispatchQueue.main.async {
                guard let self, self.engine === engine else { return }
                self.engine = nil
            }
        }
        try engine.start()
        self.engine = engine
        return engine
    }
}
