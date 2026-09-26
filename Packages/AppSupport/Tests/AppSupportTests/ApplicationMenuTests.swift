import AppKit
import XCTest
@testable import AppSupport

final class ApplicationMenuTests: XCTestCase {
    @MainActor
    func testLocalCommandsRouteToApplicationAndCurrentWindow() async throws {
        let application = NSApplication.shared
        let oldMenu = application.mainMenu
        let oldWindowMenu = application.windowsMenu
        let oldServices = application.servicesMenu
        defer {
            application.mainMenu = oldMenu
            application.windowsMenu = oldWindowMenu
            application.servicesMenu = oldServices
        }
        var settingsCalls = 0
        var showCalls = 0
        let menu = ApplicationMenu(
            applicationName: "MacRemoteApp Viewer",
            metadata: ApplicationMetadata(version: "0.2", build: "1003"),
            onSettings: { settingsCalls += 1 },
            onShowWindow: { showCalls += 1 }
        )
        menu.install()
        let app = try XCTUnwrap(application.mainMenu?.items.first?.submenu)
        let settings = try XCTUnwrap(app.items.first { $0.keyEquivalent == "," })
        XCTAssertEqual(settings.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(application.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertEqual(settingsCalls, 1)
        let quit = try XCTUnwrap(app.items.first { $0.keyEquivalent == "q" })
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(quit.target === application)
        let minimize = try XCTUnwrap(application.windowsMenu?.items.first { $0.keyEquivalent == "m" })
        XCTAssertEqual(minimize.action, #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertNil(minimize.target, "Window actions must use the responder chain, including Settings windows")
        let show = try XCTUnwrap(application.windowsMenu?.items.first { $0.keyEquivalent == "0" })
        XCTAssertTrue(application.sendAction(try XCTUnwrap(show.action), to: show.target, from: show))
        XCTAssertEqual(showCalls, 1)
    }

    @MainActor
    func testSettingsCloseRetainsWindowAndLiveStatus() async throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(
            title: "Viewer Settings", subtitle: "Test status",
            metadata: ApplicationMetadata(version: "0.2", build: "1003"),
            sections: [.init("Connection", fields: [.init("state", "Status", "Connected")])]
        )
        var closed = false
        controller.onClose = { closed = true }
        let window = try XCTUnwrap(controller.window)
        controller.setValue("Disconnected", for: "state")
        func labels(in view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        XCTAssertTrue(labels(in: try XCTUnwrap(window.contentView)).contains("Disconnected"))
        window.close()
        XCTAssertTrue(closed)
        XCTAssertTrue(controller.window === window, "Closing Settings must retain a reusable window")
        XCTAssertFalse(window.isReleasedWhenClosed)
    }
}
