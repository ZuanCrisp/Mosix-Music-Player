import Foundation

struct ExtensionCallbackRoute: Equatable {
    let code: String
    let state: String
    let isSessionGrant: Bool
}

enum ExtensionCallbackParser {
    static func parse(_ url: URL) -> ExtensionCallbackRoute? {
        guard url.scheme?.lowercased() == "spotiflac" else {
            return nil
        }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let isSessionGrant = host == "session-grant"
        let isSupportedCallback =
            isSessionGrant ||
            host == "callback" ||
            host == "spotify-callback" ||
            path.contains("callback")
        guard isSupportedCallback,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let primaryCodeKey = isSessionGrant ? "grant" : "code"
        let code =
            queryItems.first { $0.name == primaryCodeKey }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? queryItems.first { $0.name == "code" }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let state =
            queryItems.first { $0.name == "state" }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        guard !code.isEmpty, !state.isEmpty else {
            return nil
        }
        return ExtensionCallbackRoute(
            code: code,
            state: state,
            isSessionGrant: isSessionGrant
        )
    }
}
