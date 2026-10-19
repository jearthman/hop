import AppKit

/// The "Software Update" window: offer → download progress → verify/install → restart, or an error.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    enum Action { case install, skip, later, cancel, openReleasePage, closed }
    var onAction: ((Action) -> Void)?

    private let icon = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let notesLabel = NSTextField(labelWithString: "Release Notes:")
    private let notesScroll = NSScrollView()
    private let notesView = NSTextView()
    private let progress = NSProgressIndicator()
    private let progressDetail = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let bytes = ByteCountFormatter()
    private var busy = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        bytes.countStyle = .file
        layout(in: window.contentView!)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layout(in content: NSView) {
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        headline.font = .boldSystemFont(ofSize: 14)
        message.font = .systemFont(ofSize: 12)
        message.preferredMaxLayoutWidth = 440
        notesLabel.font = .boldSystemFont(ofSize: 11)

        notesView.isEditable = false
        notesView.drawsBackground = true
        notesView.backgroundColor = .textBackgroundColor
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesView.isVerticallyResizable = true
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .lineBorder

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progressDetail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressDetail.textColor = .secondaryLabelColor

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let column = NSStackView(views: [headline, message, notesLabel, notesScroll, progress, progressDetail, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(14, after: message)
        column.setCustomSpacing(16, after: notesScroll)
        column.setCustomSpacing(16, after: progressDetail)

        for view in [icon, column] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            column.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            notesScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            notesScroll.heightAnchor.constraint(equalToConstant: 170),
            progress.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    // MARK: - States

    func showOffer(_ release: Release, currentVersion: String) {
        busy = false
        headline.stringValue = "A new version of Hop is available!"
        message.stringValue = "Hop \(release.version) is now available—you have \(currentVersion). Would you like to update now?"
        notesView.textStorage?.setAttributedString(Self.render(markdown: release.notes.isEmpty ? "No release notes." : release.notes))
        setVisible(notes: true, progress: false)
        setButtons(leading: [button("Skip This Version", .skip)],
                   trailing: [button("Remind Me Later", .later), button("Install Update", .install, isDefault: true)])
    }

    func showDownloading(received: Int64, total: Int64) {
        busy = true
        headline.stringValue = "Downloading update…"
        message.stringValue = "Hop will restart when the update is installed."
        setVisible(notes: false, progress: true)
        progress.isIndeterminate = total <= 0
        if total > 0 {
            progress.doubleValue = Double(received) / Double(total)
            progressDetail.stringValue = "\(bytes.string(fromByteCount: received)) of \(bytes.string(fromByteCount: total))"
        } else {
            progress.startAnimation(nil)
            progressDetail.stringValue = bytes.string(fromByteCount: received)
        }
        if buttonRow.arrangedSubviews.count != 2 || (buttonRow.arrangedSubviews.last as? NSButton)?.title != "Cancel" {
            setButtons(leading: [], trailing: [button("Cancel", .cancel)])
        }
    }

    func showWorking(_ text: String) {
        busy = true
        headline.stringValue = text
        setVisible(notes: false, progress: true)
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        progressDetail.stringValue = ""
        setButtons(leading: [], trailing: [])
    }

    func showError(_ text: String) {
        busy = false
        progress.stopAnimation(nil)
        headline.stringValue = "Update failed"
        message.stringValue = text
        setVisible(notes: false, progress: false)
        setButtons(leading: [button("Download Manually…", .openReleasePage)],
                   trailing: [button("OK", .later, isDefault: true)])
    }

    // MARK: - Helpers

    private func setVisible(notes: Bool, progress showProgress: Bool) {
        notesLabel.isHidden = !notes
        notesScroll.isHidden = !notes
        progress.isHidden = !showProgress
        progressDetail.isHidden = !showProgress
        window?.layoutIfNeeded()
        if let window, let content = window.contentView {
            let height = max(content.fittingSize.height, 124)
            var frame = window.frame
            let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height))
            frame.origin.y += frame.height - newFrame.height
            frame.size = newFrame.size
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
    }

    private func setButtons(leading: [NSButton], trailing: [NSButton]) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttonRow.setViews(leading + [spacer] + trailing, in: .leading)
    }

    private func button(_ title: String, _ action: Action, isDefault: Bool = false) -> NSButton {
        let button = ActionButton(title: title, target: nil, action: nil)
        button.onClick = { [weak self] in self?.onAction?(action) }
        if isDefault { button.keyEquivalent = "\r" }
        if action == .cancel { button.keyEquivalent = "\u{1b}" }
        return button
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy {
            onAction?(.cancel)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if !busy { onAction?(.closed) }
    }

    /// Minimal Markdown for GitHub release notes: headings, bullets, bold, code, links.
    static func render(markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 12)
        let output = NSMutableAttributedString()
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            var font = base
            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                font = .boldSystemFont(ofSize: 13)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }

            let parsed = (try? AttributedString(markdown: line)) ?? AttributedString(line)
            for run in parsed.runs {
                var runFont = font
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                    if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: runFont.pointSize - 1, weight: .regular) }
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: NSColor.labelColor]
                if let link = run.link { attributes[.link] = link }
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            output.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        }
        return output
    }
}

private final class ActionButton: NSButton {
    var onClick: (() -> Void)?

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        self.target = self
        self.action = #selector(clicked)
    }

    @objc private func clicked() { onClick?() }
}
