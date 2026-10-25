import AVKit
import Flutter
import MediaPlayer
import UIKit

/// iOS owns the lock-screen layout, transport glyphs and AirPlay button.
/// Supply its favorite command with the same state/action as the Mornye player.
final class PlaybackNotificationBridge {
    private let channel: FlutterMethodChannel
    private var target: Any?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/playback_notification", binaryMessenger: messenger)
        let command = MPRemoteCommandCenter.shared().likeCommand
        target = command.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.channel.invokeMethod("favorite", arguments: nil)
            return .success
        }
        command.isEnabled = false
        channel.setMethodCallHandler { call, result in
            guard call.method == "update", let values = call.arguments as? [String: Any] else {
                result(FlutterMethodNotImplemented)
                return
            }
            command.isEnabled = values["enabled"] as? Bool ?? false
            command.isActive = values["loved"] as? Bool ?? false
            command.localizedTitle = values["label"] as? String ?? "Favorite"
            result(nil)
        }
    }

    deinit {
        if let target { MPRemoteCommandCenter.shared().likeCommand.removeTarget(target) }
        channel.setMethodCallHandler(nil)
    }
}

/// Read-only route and stream facts for the player's audio information sheet.
final class AudioRouteInfoBridge {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/audio_route", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "read" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let path = (call.arguments as? [String: Any])?["path"] as? String
            Task {
                var info = Self.route()
                if let path { info["stream"] = await Self.stream(path) }
                let payload = info
                await MainActor.run { result(payload) }
            }
        }
    }

    private static func route() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        var info: [String: Any] = [
            "platform": "ios",
            "mixerSampleRate": Int(session.sampleRate.rounded()),
            "ioBufferMs": session.ioBufferDuration * 1000,
            "outputLatencyMs": session.outputLatency * 1000,
            "outputChannels": session.outputNumberOfChannels,
            "maxOutputChannels": session.maximumOutputNumberOfChannels,
            "volume": Double(session.outputVolume),
        ]
        if let output = session.currentRoute.outputs.first {
            info["device"] = [
                "type": portType(output.portType),
                "name": output.portName,
                "channelCounts": [output.channels?.count ?? 0].filter { $0 > 0 },
                "spatial": output.isSpatialAudioEnabled,
            ] as [String: Any]
        }
        return info
    }

    private static func portType(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "earpiece"
        case .headphones: return "wired_headphones"
        case .bluetoothA2DP, .bluetoothHFP: return "bluetooth"
        case .bluetoothLE: return "bluetooth_le"
        case .airPlay: return "airplay"
        case .usbAudio: return "usb"
        case .HDMI: return "hdmi"
        case .lineOut: return "line"
        case .carAudio: return "car"
        default: return "other"
        }
    }

    private static func stream(_ path: String) async -> [String: Any]? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path)
        guard let url, url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let formats = try? await track.load(.formatDescriptions),
              let description = formats.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        let id = basic.mFormatID
        let fourCC = String(
            bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xff) },
            encoding: .ascii
        )?.trimmingCharacters(in: .whitespaces) ?? ""
        return [
            "mime": fourCC,
            "sampleRate": Int(basic.mSampleRate.rounded()),
            "channels": Int(basic.mChannelsPerFrame),
            "pcmBits": Int(basic.mBitsPerChannel),
            "bitrate": Int(rate.rounded()),
        ].filter { ($0.value as? Int).map { $0 > 0 } ?? !(($0.value as? String)?.isEmpty ?? true) }
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}

final class AudioOutputViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        AudioOutputView(frame: frame, id: viewId, messenger: messenger, arguments: args)
    }
}

private final class AudioOutputView: NSObject, FlutterPlatformView, AVRoutePickerViewDelegate {
    private let picker: AVRoutePickerView
    private let channel: FlutterMethodChannel

    init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger, arguments: Any?) {
        picker = AVRoutePickerView(frame: frame)
        channel = FlutterMethodChannel(name: "com.zarz.mornye/audio_output/\(id)", binaryMessenger: messenger)
        super.init()
        picker.backgroundColor = .clear
        picker.prioritizesVideoDevices = false
        picker.delegate = self
        update(arguments)
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == "update" {
                self?.update(call.arguments)
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func update(_ arguments: Any?) {
        guard let values = arguments as? [String: Any] else { return }
        if let value = values["color"] as? NSNumber {
            let argb = value.uint32Value
            picker.tintColor = UIColor(
                red: CGFloat((argb >> 16) & 0xff) / 255,
                green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255,
                alpha: CGFloat((argb >> 24) & 0xff) / 255
            )
            picker.activeTintColor = picker.tintColor
        }
        picker.accessibilityLabel = values["label"] as? String
    }

    func view() -> UIView { picker }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        channel.invokeMethod("pickerChanged", arguments: true)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        channel.invokeMethod("pickerChanged", arguments: false)
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}
