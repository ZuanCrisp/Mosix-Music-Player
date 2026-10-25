import Foundation
import Flutter
import MediaPlayer
import XCTest
import audio_service
@testable import Runner

class RunnerTests: XCTestCase {
    @MainActor
    func testNowPlayingRecoveryPreservesTrackArtworkAndControlsWithoutSkipping() throws {
        let plugin = AudioServicePlugin()
        func call(_ method: String, _ arguments: [String: Any] = [:]) {
            var replied = false
            plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { result in
                XCTAssertFalse(result is FlutterError)
                replied = true
            }
            XCTAssertTrue(replied)
        }
        call("stopService")
        defer { call("stopService") }

        let artworkURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try XCTUnwrap(image.pngData()).write(to: artworkURL)
        defer { try? FileManager.default.removeItem(at: artworkURL) }
        call("setMediaItem", ["mediaItem": [
            "id": "fixture", "title": "Same track", "artist": "Test artist", "album": "Test album",
            "duration": 180_000, "isLive": false, "artUri": artworkURL.absoluteString,
            "extras": ["artCacheFile": artworkURL.path],
        ]])
        func state(playing: Bool, position: Int, updateAge: Double) -> [String: Any] {
            ["state": [
                "processingState": 3, "playing": playing,
                "updatePosition": position, "bufferedPosition": 180_000,
                "updateTime": (Date().timeIntervalSince1970 - updateAge) * 1000,
                "speed": 1.5, "repeatMode": 0, "shuffleMode": 0,
                "controls": [["action": playing ? 1 : 2], ["action": 4], ["action": 5]],
                "systemActions": [8],
            ]]
        }
        call("setState", state(playing: true, position: 17_000, updateAge: 10))
        let center = MPNowPlayingInfoCenter.default()
        let artwork = try XCTUnwrap(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)

        // Simulate repeated loss of the OS card while the plugin retains the
        // same item. Recovery must not depend on a new title or artwork event.
        for _ in 0..<3 {
            center.nowPlayingInfo = nil
            call("refreshNowPlayingInfo")
            let info = try XCTUnwrap(center.nowPlayingInfo)
            XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Same track")
            XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Test artist")
            XCTAssertTrue(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === artwork)
            let elapsed = try XCTUnwrap(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double)
            XCTAssertEqual(elapsed, 32, accuracy: 1)
            XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
            XCTAssertTrue(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
            XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
            XCTAssertTrue(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        }

        call("setState", state(playing: false, position: 42_000, updateAge: 60))
        center.nowPlayingInfo = nil
        call("refreshNowPlayingInfo")
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertTrue(MPRemoteCommandCenter.shared().playCommand.isEnabled)
        call("stopService")
        call("refreshNowPlayingInfo")
        XCTAssertNil(center.nowPlayingInfo)
    }

    @MainActor
    func testPlayerWidgetSharesSceneEngineAndCompletesCommands() async throws {
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let controller = try XCTUnwrap(delegate.activeWindow?.rootViewController as? FlutterViewController)
        XCTAssertTrue(controller.engine === delegate.playerEngine)

        // Exercise the real native -> Dart -> audio handler -> native path.
        // With an empty queue, opening the widget leaves the app on its home
        // or onboarding screen and still publishes a valid empty snapshot.
        let completed = await PlayerWidgetBridge.shared.perform("open")
        XCTAssertTrue(completed)
        let container = try XCTUnwrap(PlayerWidgetState.container)
        let data = try Data(contentsOf: container.appendingPathComponent("player.json"))
        let state = try JSONDecoder().decode(PlayerWidgetState.self, from: data)
        XCTAssertFalse(state.canPlay)
        XCTAssertFalse(state.playing)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }

    func testFFmpegPublishesOnlySuccessfulUncancelledOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("output.flac")
        for outcome in ["cancel", "failure", "success"] {
            try Data("original".utf8).write(to: target)
            var cancelled = false
            var staged: URL?
            let command = CoreFFmpegCommand(command_id: outcome, arguments: ["-i", "input.wav", "-y", target.path], output_path: target.path)
            let result = executeCoreFFmpegCommand(command: command, cancelled: { cancelled }, execute: { arguments, _ in
                XCTAssertEqual(arguments[1], "input.wav")
                staged = URL(fileURLWithPath: arguments.last!)
                XCTAssertNotEqual(staged, target)
                XCTAssertEqual(staged?.pathExtension, "flac")
                do { try Data("converted".utf8).write(to: staged!) }
                catch { XCTFail("staging write failed: \(error)"); return (false, "write failed") }
                cancelled = outcome == "cancel"
                return (outcome != "failure", "result")
            })
            XCTAssertEqual(result.0, outcome == "success")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), outcome == "success" ? "converted" : "original")
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged!.path))
        }
    }

    func testFFmpegCallerReturnKeepsOtherClaimedCommandAlive() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closed = expectation(description: "command handle released")
        let lock = NSLock()
        var isClosed = false
        let execution = CoreFFmpegExecution(wait: { _ in
            [CoreFFmpegCommand(command_id: "other", arguments: ["convert"])]
        }, active: { _ in true }, complete: { id, success, _, _ in
            XCTAssertEqual(id, "other")
            XCTAssertTrue(success)
        }, close: {
            lock.lock()
            isClosed = true
            lock.unlock()
            closed.fulfill()
        })
        let result = execution.run(execute: { _, cancelled in
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            XCTAssertFalse(cancelled())
            return (true, "finished")
        }) {
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            return "caller finished"
        }
        XCTAssertEqual(result, "caller finished")
        lock.lock()
        XCTAssertFalse(isClosed)
        lock.unlock()
        release.signal()
        wait(for: [closed], timeout: 2)
    }

    func testFFmpegFirstExecutionSweepsOnlyOwnOrphanFilesAndPreservesOtherEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = ".mornye-ffmpeg-\(Bundle.main.bundleIdentifier ?? "mornye")-"
        let ownOrphan = root.appendingPathComponent("\(prefix)\(UUID().uuidString).flac")
        try Data("orphan".utf8).write(to: ownOrphan)
        let foreignFile = root.appendingPathComponent(".mornye-ffmpeg-foreign-\(UUID().uuidString).flac")
        try Data("foreign".utf8).write(to: foreignFile)
        let malformedFile = root.appendingPathComponent("\(prefix)not-a-uuid.flac")
        try Data("malformed".utf8).write(to: malformedFile)
        let preservedDirectory = root.appendingPathComponent("\(prefix)\(UUID().uuidString).flac")
        try FileManager.default.createDirectory(at: preservedDirectory, withIntermediateDirectories: false)
        let directoryContent = preservedDirectory.appendingPathComponent("content.txt")
        try Data("directory content".utf8).write(to: directoryContent)
        let symlinkTarget = root.appendingPathComponent("symlink-target.txt")
        try Data("symlink content".utf8).write(to: symlinkTarget)
        let symlink = root.appendingPathComponent("\(prefix)\(UUID().uuidString).flac")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)

        let target = root.appendingPathComponent("output.flac")
        let command = CoreFFmpegCommand(
            command_id: "sweep",
            arguments: ["convert", target.path],
            output_path: target.path
        )
        var staged: URL?
        let result = executeCoreFFmpegCommand(command: command, cancelled: { false }) { arguments, _ in
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownOrphan.path))
            XCTAssertEqual(try? String(contentsOf: foreignFile, encoding: .utf8), "foreign")
            XCTAssertEqual(try? String(contentsOf: malformedFile, encoding: .utf8), "malformed")
            XCTAssertTrue(FileManager.default.fileExists(atPath: preservedDirectory.path))
            XCTAssertEqual(try? String(contentsOf: directoryContent, encoding: .utf8), "directory content")
            XCTAssertTrue(isSymbolicLink(symlink))
            XCTAssertEqual(try? String(contentsOf: symlink, encoding: .utf8), "symlink content")

            staged = URL(fileURLWithPath: arguments.last!)
            do {
                try Data("published".utf8).write(to: staged!)
            } catch {
                XCTFail("staging write failed: \(error)")
                return (false, "write failed")
            }
            return (true, "converted")
        }

        XCTAssertTrue(result.0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "published")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownOrphan.path))
        XCTAssertEqual(try String(contentsOf: foreignFile, encoding: .utf8), "foreign")
        XCTAssertEqual(try String(contentsOf: malformedFile, encoding: .utf8), "malformed")
        XCTAssertEqual(try String(contentsOf: directoryContent, encoding: .utf8), "directory content")
        XCTAssertTrue(isSymbolicLink(symlink))
        XCTAssertEqual(try String(contentsOf: symlink, encoding: .utf8), "symlink content")
    }

    func testFFmpegOverlappingExecutionsPreserveLiveStagingAndPublishBothOutputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstTarget = root.appendingPathComponent("first.flac")
        let secondTarget = root.appendingPathComponent("second.flac")
        let firstCommand = CoreFFmpegCommand(
            command_id: "first",
            arguments: ["convert-first", firstTarget.path],
            output_path: firstTarget.path
        )
        let secondCommand = CoreFFmpegCommand(
            command_id: "second",
            arguments: ["convert-second", secondTarget.path],
            output_path: secondTarget.path
        )
        var firstStage: URL?
        var secondStage: URL?

        let result = executeCoreFFmpegCommand(command: firstCommand, cancelled: { false }) { arguments, _ in
            firstStage = URL(fileURLWithPath: arguments.last!)
            do {
                try Data("first staged".utf8).write(to: firstStage!)
            } catch {
                XCTFail("first staging write failed: \(error)")
                return (false, "write failed")
            }

            let nestedResult = executeCoreFFmpegCommand(command: secondCommand, cancelled: { false }) { nestedArguments, _ in
                secondStage = URL(fileURLWithPath: nestedArguments.last!)
                XCTAssertTrue(FileManager.default.fileExists(atPath: firstStage!.path))
                XCTAssertEqual(try? String(contentsOf: firstStage!, encoding: .utf8), "first staged")
                do {
                    try Data("second published".utf8).write(to: secondStage!)
                } catch {
                    XCTFail("second staging write failed: \(error)")
                    return (false, "write failed")
                }
                return (true, "second complete")
            }

            XCTAssertTrue(nestedResult.0)
            XCTAssertEqual(try? String(contentsOf: secondTarget, encoding: .utf8), "second published")
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstStage!.path))
            XCTAssertEqual(try? String(contentsOf: firstStage!, encoding: .utf8), "first staged")
            return (true, "first complete")
        }

        XCTAssertTrue(result.0)
        XCTAssertEqual(try String(contentsOf: firstTarget, encoding: .utf8), "first staged")
        XCTAssertEqual(try String(contentsOf: secondTarget, encoding: .utf8), "second published")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstStage!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStage!.path))
    }

    func testFFmpegCancellationAndInvalidArgumentsDoNotStopOtherCommands() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let closed = expectation(description: "pump closed")
        let lock = NSLock()
        var active = Set(["empty", "a", "b"])
        var claimed = false
        let execution = CoreFFmpegExecution(wait: { _ in
            lock.lock()
            defer { lock.unlock() }
            if claimed { return [] }
            claimed = true
            return [CoreFFmpegCommand(command_id: "empty", arguments: []),
                    CoreFFmpegCommand(command_id: "a", arguments: ["a"]),
                    CoreFFmpegCommand(command_id: "b", arguments: ["b"])]
        }, active: { id in
            lock.lock()
            defer { lock.unlock() }
            return active.contains(id)
        }, complete: { id, success, _, error in
            if id == "empty" { XCTAssertEqual(error, "FFmpeg arguments are empty") }
            if id == "a" { XCTAssertFalse(success) }
            if id == "b" {
                XCTAssertTrue(success)
                completed.signal()
            }
        }, close: { closed.fulfill() })
        _ = execution.run(execute: { arguments, cancelled in
            if arguments == ["a"] {
                started.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
                XCTAssertTrue(cancelled())
                return (false, "cancelled")
            }
            XCTAssertEqual(arguments, ["b"])
            XCTAssertFalse(cancelled())
            return (true, "finished")
        }) {
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            lock.lock()
            active.remove("a")
            lock.unlock()
            release.signal()
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
            return "finished"
        }
        wait(for: [closed], timeout: 2)
    }

    func testFFmpegClosedRegistryReleasesHandle() {
        let closed = DispatchSemaphore(value: 0)
        let execution = CoreFFmpegExecution(wait: { _ in
            throw NSError(domain: "closed owner", code: 1)
        }, active: { _ in false }, complete: { _, _, _, _ in
            XCTFail("Closed registry produced a command")
        }, close: { closed.signal() })
        _ = execution.run {
            XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
            return "finished"
        }
    }

    func testProgressReconnectResetsCursorAfterOwnerShutdown() {
        let first = expectation(description: "first owner delivered")
        let replacement = expectation(description: "replacement owner delivered")
        let lock = NSLock()
        var connections = 0
        var closes = 0
        var cursors = [Int64]()
        let stream = DownloadProgressSubscription(interval: 0.01, connect: {
            lock.lock()
            connections += 1
            let owner = connections
            lock.unlock()
            return CoreDownloadProgress(wait: { sequence, _ in
                lock.lock()
                cursors.append(sequence)
                lock.unlock()
                if owner == 1 && sequence == 0 { return "{\"seq\":99,\"reset\":true,\"items\":{}}" }
                if owner == 1 { throw NSError(domain: "closed owner", code: 1) }
                return "{\"seq\":1,\"reset\":true,\"items\":{}}"
            }, close: {
                lock.lock()
                closes += 1
                lock.unlock()
            })
        })
        stream.start { event in
            let sequence = (event as? [String: Any])?["seq"] as? Int
            if sequence == 99 { first.fulfill() }
            if sequence == 1 { replacement.fulfill() }
        }
        wait(for: [first, replacement], timeout: 2)
        stream.stop()
        lock.lock()
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(closes, 2)
        XCTAssertEqual(Array(cursors.prefix(3)), [0, 99, 0])
        lock.unlock()
    }

    func testProgressStopClosesBlockedOwnerSubscription() {
        let started = expectation(description: "wait started")
        let stopped = expectation(description: "wait stopped")
        let released = DispatchSemaphore(value: 0)
        let stream = DownloadProgressSubscription(connect: {
            CoreDownloadProgress(wait: { _, _ in
                started.fulfill()
                XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
                stopped.fulfill()
                return "{\"seq\":1,\"items\":{}}"
            }, close: { released.signal() })
        })
        stream.start { _ in XCTFail("Stopped listener received an event") }
        wait(for: [started], timeout: 2)
        stream.stop()
        wait(for: [stopped], timeout: 2)
    }

    func testProgressRestartDoesNotAcceptCancelledWaiterState() {
        let oldStarted = expectation(description: "old waiter started")
        let replacementDelivered = expectation(description: "replacement snapshot")
        let replacementAdvanced = expectation(description: "replacement owns cursor")
        let oldReleased = expectation(description: "old waiter returned")
        let releaseOld = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        var invalidCursors = [Int64]()
        let stream = DownloadProgressSubscription(interval: 0.01) { sequence, _ in
            lock.lock()
            calls += 1
            let call = calls
            if (call <= 2 && sequence != 0) || (call > 2 && sequence != 2) {
                invalidCursors.append(sequence)
            }
            lock.unlock()
            if call == 1 {
                oldStarted.fulfill()
                _ = releaseOld.wait(timeout: .now() + 3)
                oldReleased.fulfill()
                return "{\"seq\":99,\"items\":{}}"
            }
            if call == 2 { return "{\"seq\":2,\"reset\":true,\"items\":{}}" }
            if call == 3 { replacementAdvanced.fulfill() }
            return ""
        }
        stream.start { _ in XCTFail("Cancelled listener received an event") }
        wait(for: [oldStarted], timeout: 2)
        stream.stop()
        stream.start { event in
            XCTAssertEqual((event as? [String: Any])?["seq"] as? Int, 2)
            replacementDelivered.fulfill()
            releaseOld.signal()
        }
        wait(for: [replacementDelivered, oldReleased, replacementAdvanced], timeout: 2)
        stream.stop()
        lock.lock()
        XCTAssertTrue(invalidCursors.isEmpty, "Unexpected cursors: \(invalidCursors)")
        lock.unlock()
    }

    func testParsesOAuthCallback() {
        let route = ExtensionCallbackParser.parse(
            URL(string: "mornye://callback?code=auth-code&state=metadata-provider")!
        )

        XCTAssertEqual(
            route,
            ExtensionCallbackRoute(
                code: "auth-code",
                state: "metadata-provider",
                isSessionGrant: false
            )
        )
    }

    func testParsesSignedSessionGrant() {
        let route = ExtensionCallbackParser.parse(
            URL(
                string:
                    "mornye://session-grant?grant=session-token&state=provider"
            )!
        )

        XCTAssertEqual(
            route,
            ExtensionCallbackRoute(
                code: "session-token",
                state: "provider",
                isSessionGrant: true
            )
        )
    }

    func testRejectsUntrustedOrIncompleteCallbacks() {
        XCTAssertNil(
            ExtensionCallbackParser.parse(
                URL(string: "https://callback?code=auth&state=provider")!
            )
        )
        XCTAssertNil(
            ExtensionCallbackParser.parse(
                URL(string: "mornye://unknown?code=auth&state=provider")!
            )
        )
        XCTAssertNil(
            ExtensionCallbackParser.parse(
                URL(string: "mornye://callback?code=auth")!
            )
        )
        XCTAssertNil(
            ExtensionCallbackParser.parse(
                URL(string: "mornye://callback?state=provider")!
            )
        )
    }
}
