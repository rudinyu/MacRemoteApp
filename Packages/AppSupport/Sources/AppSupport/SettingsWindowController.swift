import AppKit

/// Shared settings content. Viewer embeds it in its main window; Host presents
/// it in a retained window. The scroll view also supports compact Viewer sizes.
@MainActor
public final class SettingsView: NSView {
    public struct Field {
        public let id: String
        public let title: String
        public let value: String

        public init(_ id: String, _ title: String, _ value: String = "—") {
            self.id = id
            self.title = title
            self.value = value
        }
    }

    public struct Section {
        public let title: String
        public let fields: [Field]

        public init(_ title: String, fields: [Field]) {
            self.title = title
            self.fields = fields
        }
    }

    private var values: [String: NSTextField] = [:]
    private var buttons: [String: NSButton] = [:]
    private var actions: [String: () -> Void] = [:]
    private let stack = NSStackView()

    public init(
        title: String, subtitle: String, metadata: ApplicationMetadata,
        sections: [Section]
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        autoresizingMask = [.width, .height]
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        let content = SettingsDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            preferredWidth,
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(heading)
        let release = NSTextField(labelWithString: "Version \(metadata.displayVersionDetails)")
        release.textColor = .secondaryLabelColor
        release.isSelectable = true
        stack.addArrangedSubview(release)
        addNote(subtitle)

        for section in sections {
            let label = NSTextField(labelWithString: section.title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(label)
            let rows: [[NSView]] = section.fields.map { field in
                let key = NSTextField(labelWithString: field.title)
                key.textColor = .secondaryLabelColor
                let value = NSTextField(labelWithString: field.value)
                value.isSelectable = true
                value.lineBreakMode = .byTruncatingTail
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                values[field.id] = value
                return [key, value]
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 8
            grid.columnSpacing = 16
            grid.column(at: 0).width = 130
            grid.xPlacement = .fill
            stack.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func addNote(_ text: String) {
        let note = NSTextField(wrappingLabelWithString: text)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    public func addAction(_ id: String, title: String, checkbox: Bool = false, atTop: Bool = false, action: @escaping () -> Void) {
        let button = NSButton(title: title, target: self, action: #selector(invokeAction(_:)))
        if checkbox { button.setButtonType(.switch) }
        button.identifier = NSUserInterfaceItemIdentifier(id)
        buttons[id] = button
        actions[id] = action
        if atTop {
            stack.insertArrangedSubview(button, at: 0)
        } else {
            stack.addArrangedSubview(button)
        }
    }

    public func setValue(_ value: String, for id: String) {
        values[id]?.stringValue = value
        values[id]?.toolTip = value
    }

    public func setAction(_ id: String, enabled: Bool, checked: Bool = false) {
        buttons[id]?.isEnabled = enabled
        buttons[id]?.state = checked ? .on : .off
    }

    @objc private func invokeAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        actions[id]?()
    }
}

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let settingsView: SettingsView
    public var onClose: (() -> Void)?

    public init(
        title: String, subtitle: String, metadata: ApplicationMetadata,
        sections: [SettingsView.Section], size: NSSize = NSSize(width: 600, height: 700)
    ) {
        settingsView = SettingsView(title: title, subtitle: subtitle, metadata: metadata, sections: sections)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = settingsView
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func addNote(_ text: String) { settingsView.addNote(text) }
    public func addAction(_ id: String, title: String, checkbox: Bool = false, action: @escaping () -> Void) {
        settingsView.addAction(id, title: title, checkbox: checkbox, action: action)
    }
    public func setValue(_ value: String, for id: String) { settingsView.setValue(value, for: id) }
    public func setAction(_ id: String, enabled: Bool, checked: Bool = false) {
        settingsView.setAction(id, enabled: enabled, checked: checked)
    }
    public func present() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    public func windowWillClose(_ notification: Notification) { onClose?() }
}
