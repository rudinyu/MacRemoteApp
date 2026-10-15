import Darwin
import CodecCore
import Foundation
import InputCore
import os
import RemoteProtocol
import SecurityCore
import TransportCore

let macRemoteAppStartupLogger = Logger(
    subsystem: "com.rudinyu.MacRemoteApp",
    category: "startup"
)

@MainActor
@main
struct ViewerApp {
    static func startSession(
        _ session: SessionCoordinator,
        onMessage: @escaping @MainActor (MessagePayload) async -> Void = { _ in }
    ) -> ViewerSessionMessageLoop {
        let runtime = ViewerSessionMessageLoop(session: session, onMessage: onMessage)
        runtime.start()
        return runtime
    }

    static func main() async {
        if CommandLine.arguments.contains("--remove-all-data") {
            do {
                try await removeAllLocalData()
            } catch {
                fputs("MacRemoteApp Viewer data cleanup failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

#if DEBUG
        M10MainActorStallMonitor.shared.start(role: .viewer)
#endif

#if DEBUG
        if CommandLine.arguments.contains("--m5-input-surface") {
            let demo = ViewerInputDemo()
            demo.run()
            return
        }

        if CommandLine.arguments.contains("--m2-physical-viewer") {
            do {
                try await M2PhysicalViewerSmoke.run()
            } catch {
                fputs("M2 physical viewer smoke failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        if CommandLine.arguments.contains("--m7-physical-viewer") {
            do {
                try await M2PhysicalViewerSmoke.run(clipboardOptIn: true)
            } catch {
                fputs("M7 physical viewer clipboard smoke failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
#endif

        do {
            let runtime = try ViewerRuntime(configuration: .load())
            runtime.run()
        } catch {
            macRemoteAppStartupLogger.error(
                "MacRemoteApp Viewer startup failed (code: \(viewerStartupErrorCode(error), privacy: .public))"
            )
            fputs("MacRemoteApp Viewer failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private func removeAllLocalData() async throws {
    try await KeychainTrustStore(
        service: ViewerRuntime.Configuration.defaultTrustStoreService
    ).removeAll()
    try await KeychainIdentityProvider(
        label: ViewerRuntime.Configuration.defaultIdentityLabel
    ).removeGeneratedIdentity()
    UserDefaults.standard.removePersistentDomain(forName: "com.rudinyu.MacRemoteApp.Viewer")
    UserDefaults.standard.synchronize()
}

func viewerStartupErrorCode(_ error: Error) -> String {
    if error is ViewerRuntimeError {
        return "configuration"
    }
    if error is SecurityCoreError {
        return "security"
    }
    return "unknown"
}
