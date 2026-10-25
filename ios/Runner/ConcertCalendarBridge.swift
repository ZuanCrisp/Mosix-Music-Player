import EventKit
import EventKitUI
import Flutter
import UIKit

final class ConcertCalendarBridge: NSObject, EKEventEditViewDelegate {
    private let channel: FlutterMethodChannel
    private let presenter: () -> UIViewController?
    private let store = EKEventStore()

    init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
        channel = FlutterMethodChannel(name: "com.zarz.mornye/concert_calendar", binaryMessenger: messenger)
        self.presenter = presenter
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "add" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let self, let data = call.arguments as? [String: Any],
                  let start = data["start"] as? NSNumber else {
                result(false)
                return
            }
            if #available(iOS 17.0, *) {
                // The system editor saves only after the user confirms; it
                // needs no permission to read the person's existing events.
                self.present(data, start: start, result: result)
            } else {
                self.store.requestAccess(to: .event) { [weak self] allowed, _ in
                    DispatchQueue.main.async {
                        guard let self, allowed else { result(false); return }
                        self.present(data, start: start, result: result)
                    }
                }
            }
        }
    }

    private func present(_ data: [String: Any], start: NSNumber, result: @escaping FlutterResult) {
        guard let controller = presenter(), controller.viewIfLoaded?.window != nil,
              controller.presentedViewController == nil else {
            result(false)
            return
        }
        let event = EKEvent(eventStore: store)
        event.title = data["title"] as? String
        event.location = data["location"] as? String
        event.startDate = Date(timeIntervalSince1970: start.doubleValue / 1000)
        let end = (data["end"] as? NSNumber)?.doubleValue ?? 0
        event.endDate = end > start.doubleValue
            ? Date(timeIntervalSince1970: end / 1000)
            : event.startDate.addingTimeInterval(3600)
        if let url = data["url"] as? String { event.url = URL(string: url) }
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.event = event
        editor.editViewDelegate = self
        controller.present(editor, animated: true) { result(true) }
    }

    func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
        controller.dismiss(animated: true)
    }
}
