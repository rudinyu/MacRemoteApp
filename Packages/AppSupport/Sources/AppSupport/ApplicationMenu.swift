import AppKit

/// Shared native menu commands. Session shutdown remains owned by the app delegate.
@MainActor
public final class ApplicationMenu: NSObject {
    private let applicationName: String
    private let metadata: ApplicationMetadata
    private let onSettings: () -> Void
    private let onShowWindow: () -> Void
    private let onActivate: () -> Void
    private let onAboutClose: () -> Void
    private var aboutWindow: SettingsWindowController?

    public var isAboutVisible: Bool {
        aboutWindow?.window?.isVisible == true || aboutWindow?.window?.isMiniaturized == true
    }

    public init(
        applicationName: String,
        metadata: ApplicationMetadata,
        onSettings: @escaping () -> Void,
        onShowWindow: @escaping () -> Void,
        onActivate: @escaping () -> Void = {},
        onAboutClose: @escaping () -> Void = {}
    ) {
        self.applicationName = applicationName
        self.metadata = metadata
        self.onSettings = onSettings
        self.onShowWindow = onShowWindow
        self.onActivate = onActivate
        self.onAboutClose = onAboutClose
    }

    public func install() {
        let application = NSApplication.shared
        let main = NSMenu()
        let appMenu = submenu(applicationName, in: main)
        add("About \(applicationName)", #selector(showAbout), to: appMenu, target: self)
        appMenu.addItem(.separator())
        add("Settings…", #selector(showSettings), key: ",", to: appMenu, target: self)
        appMenu.addItem(.separator())
        let services = submenu("Services", in: appMenu)
        application.servicesMenu = services
        appMenu.addItem(.separator())
        add("Hide \(applicationName)", #selector(NSApplication.hide(_:)), key: "h", to: appMenu, target: application)
        let hideOthers = add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", to: appMenu, target: application)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: appMenu, target: application)
        appMenu.addItem(.separator())
        add("Quit \(applicationName)", #selector(NSApplication.terminate(_:)), key: "q", to: appMenu, target: application)

        let file = submenu("File", in: main)
        add("Close Window", #selector(NSWindow.performClose(_:)), key: "w", to: file)
        let window = submenu("Window", in: main)
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window)
        add("Zoom", #selector(NSWindow.performZoom(_:)), to: window)
        window.addItem(.separator())
        add("Show \(applicationName)", #selector(showMainWindow), key: "0", to: window, target: self)
        add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), to: window, target: application)
        application.windowsMenu = window
        application.mainMenu = main
    }

    @objc public func showAbout() {
        onActivate()
        if aboutWindow == nil {
            let controller = SettingsWindowController(
                title: "About \(applicationName)",
                subtitle: "View and control a selected Mac app over your trusted LAN.",
                metadata: metadata,
                sections: [],
                size: NSSize(width: 520, height: 220)
            )
            controller.onClose = onAboutClose
            aboutWindow = controller
        }
        aboutWindow?.present()
    }

    @objc public func showSettings() { onSettings() }
    @objc public func showMainWindow() { onShowWindow() }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private func add(
        _ title: String, _ action: Selector, key: String = "",
        to menu: NSMenu, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
        return item
    }
}
