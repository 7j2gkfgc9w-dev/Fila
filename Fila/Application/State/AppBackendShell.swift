import AlertController
import FilaBackendKit
import FilaBackendUI
import FilaClient
import FilaProtocol
import UIKit
import UniformTypeIdentifiers
import WebKit

/// What module screens borrow from the app: a browser for a location, the
/// destination pickers, staging and jobs through the one operation centre,
/// and the feedback chrome. Assigned once at launch; there is no second
/// implementation and no module builds these for itself.
@MainActor
final class AppBackendShell: BackendShell {
    private var session: FileSession {
        .shared
    }

    func browser(for location: BackendLocation) -> UIViewController? {
        guard let backend = BackendComposition.backends.first(where: { $0.id == location.backend }) as? LocalFileBackend,
              let path = try? ServicePath(location.item)
        else { return nil }
        return FileBrowserViewController(directory: backend.absolutePath(path))
    }

    func filePicker(fileTypes: Set<String>?, chosen: @escaping (URL) -> Void) -> UIViewController {
        let picker = SaveDestinationViewController(picksFiles: true, fileTypes: fileTypes, link: session.link, confirm: chosen)
        return UINavigationController(rootViewController: picker)
    }

    func saveDestinationPicker(fileName: String, chosen: @escaping (URL) -> Void) -> UIViewController {
        let picker = SaveDestinationViewController(fileName: fileName, link: session.link, confirm: chosen)
        return UINavigationController(rootViewController: picker)
    }

    func presentSheet(_ controller: UIViewController, from presenter: UIViewController) {
        presenter.presentAsSheet(controller)
    }

    func stage(_ path: String) async throws -> URL {
        try await session.stage(path)
    }

    func copy(_ source: URL, into directory: String, subtitle: String) async throws {
        let result = try await session.operations.awaitJob(
            JobRequest(kind: .copy, sources: [source.path], destination: directory),
            kind: .copy,
            subtitle: subtitle,
            feedback: .silent,
        )
        guard result.code == .success else { throw result }
    }

    func delete(_ path: String, subtitle: String) async throws {
        let result = try await session.operations.awaitJob(
            JobRequest(kind: .delete, sources: [path]),
            kind: .delete,
            subtitle: subtitle,
            feedback: .silent,
        )
        guard result.code == .success || result.systemError == ENOENT else { throw result }
    }

    func toast(_ text: String) {
        Toast.show(text)
    }

    func alert(title: String, message: String) {
        FeedbackAlert.show(title, message: message)
    }

    func promptRemoteNewFolder(
        from presenter: UIViewController,
        onConfirm: @escaping @MainActor (String) -> Void,
    ) {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("New Folder"),
            message: String.LocalizationValue("Enter a name for the new item in this folder."),
            placeholder: String.LocalizationValue("Folder name"),
            text: "",
            doneButtonText: String.LocalizationValue("Create"),
            onConfirm: onConfirm,
        ).typingLiterally()
        presenter.present(alert, animated: true)
    }

    func promptRemoteRename(
        from presenter: UIViewController,
        currentName: String,
        onConfirm: @escaping @MainActor (String) -> Void,
    ) {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Rename"),
            message: String.LocalizationValue("Enter a new name. The item stays in the same folder."),
            placeholder: String.LocalizationValue("New name"),
            text: currentName,
            doneButtonText: String.LocalizationValue("Rename"),
            onConfirm: onConfirm,
        ).typingLiterally()
        presenter.present(alert, animated: true)
    }

    func showRemoteInformation(from presenter: UIViewController, title: String, message: String) {
        presenter.presentMessage(title, message: message)
    }

    /// Show network-aware actions without staging the full remote file.
    func offerRemoteOpen(
        from presenter: UIViewController,
        fileName: String,
        url: URL,
        media: Bool,
        fileExtension: String,
        preview: (@MainActor () -> Void)?,
        text: (@MainActor () -> Void)?,
        table: (@MainActor () -> Void)?,
        openInApps: (@MainActor () -> Void)?
    ) {
        let alert = AlertViewController(
            title: .init(fileName),
            message: String.LocalizationValue(
                "Choose a viewer. System apps need a temporary local copy; streaming players read from the server."
            )
        ) { context in
            context.allowSimpleDispose()
            if media {
                context.addAction(title: String.LocalizationValue("Stream in VLC")) {
                    context.dispose { self.launchRemotePlayer("vlc-x-callback", url: url, name: fileName) }
                }
                context.addAction(title: String.LocalizationValue("Stream in Infuse")) {
                    context.dispose { self.launchRemotePlayer("infuse", url: url, name: fileName) }
                }
            }
            if let table {
                context.addAction(title: String.LocalizationValue("View as Table")) {
                    context.dispose { table() }
                }
            }
            if let text {
                context.addAction(title: String.LocalizationValue("View as Text / Code")) {
                    context.dispose { text() }
                }
            }
            if let preview {
                context.addAction(title: String.LocalizationValue("Preview in Fila (download)")) {
                    context.dispose { preview() }
                }
            }
            if let openInApps {
                context.addAction(title: String.LocalizationValue("Open in Another App (download)")) {
                    context.dispose { openInApps() }
                }
            }
            context.addAction(title: String.LocalizationValue("Copy Network Link")) {
                context.dispose {
                    UIPasteboard.general.url = url
                    self.toast(String(localized: "Copied"))
                }
            }
            context.addAction(title: String.LocalizationValue("Share Network Link")) {
                context.dispose {
                    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let popover = sheet.popoverPresentationController {
                        popover.sourceView = presenter.view
                        popover.sourceRect = CGRect(
                            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                            width: 1, height: 1
                        )
                    }
                    presenter.present(sheet, animated: true)
                }
            }
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
        }
        presenter.present(alert, animated: true)
    }

    /// VLC and Infuse both accept an x-callback play/stream network URL.
    /// URLComponents encodes nested URLs, including non-ASCII path segments.
    private func launchRemotePlayer(_ scheme: String, url: URL, name: String) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "x-callback-url"
        components.path = scheme == "infuse" ? "/play" : "/stream"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if scheme == "infuse" {
            components.queryItems?.append(URLQueryItem(name: "filename", value: name))
        }
        guard let target = components.url else { return }
        UIApplication.shared.open(target, options: [:]) { success in
            guard !success else { return }
            Task { @MainActor in
                self.alert(
                    title: String(localized: "Player Not Installed"),
                    message: String(localized: "Install VLC or Infuse and sign in to this server there.")
                )
            }
        }
    }

    /// Preview a small UTF-8 text/code file without installing a text editor.
    func previewText(_ file: URL, title: String, from presenter: UIViewController, released: @escaping () -> Void) {
        guard let content = Self.readSmallText(file) else {
            released()
            alert(title: String(localized: "Could Not Read Text"),
                  message: String(localized: "This file cannot be displayed as text."))
            return
        }
        let viewer = UIViewController()
        viewer.title = title
        let area = UITextView()
        area.text = content
        area.isEditable = false
        area.isSelectable = true
        area.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        area.backgroundColor = .systemBackground
        area.textColor = .label
        viewer.view = area
        ReleaseOnDeinit.attach(to: viewer, released)
        if let navigation = presenter.navigationController {
            navigation.pushViewController(viewer, animated: true)
        } else {
            presenter.present(UINavigationController(rootViewController: viewer), animated: true)
        }
    }

    /// iPadOS discovers actual installed handlers for a real local file URL.
    /// The staged file exists only while the system sheet is alive.
    func openInSystemApps(_ file: URL, from presenter: UIViewController, released: @escaping () -> Void) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        ReleaseOnDeinit.attach(to: sheet, released)
        presenter.anchor(sheet, to: presenter.view)
        presenter.present(sheet, animated: true)
    }

    private static func readSmallText(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.count <= 8 * 1024 * 1024 else { return nil }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// A read-only CSV/TSV table; escaped HTML, no remote scripts or assets.
    func previewCSVTable(_ file: URL, title: String, from presenter: UIViewController, released: @escaping () -> Void) {
        guard let content = Self.readSmallText(file) else {
            released()
            alert(title: String(localized: "Could Not Read Text"),
                  message: String(localized: "This file cannot be displayed as text."))
            return
        }
        let separator: Character = file.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let parsed = Self.parseDelimited(content, separator: separator, limit: 1000)
        let viewer = UIViewController()
        viewer.title = title
        let web = WKWebView()
        viewer.view = web
        let head = (parsed.rows.first ?? []).map { "<th>" + Self.escapeHTML($0) + "</th>" }.joined()
        let body = parsed.rows.dropFirst().map { row in
            "<tr>" + row.map { "<td>" + Self.escapeHTML($0) + "</td>" }.joined() + "</tr>"
        }.joined()
        let notice = parsed.truncated
            ? "<p>" + Self.escapeHTML(String(localized: "Showing the first 1,000 rows.")) + "</p>" : ""
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        body{font:14px -apple-system,system-ui;margin:12px;color:#111;background:#fff}
        table{border-collapse:collapse;font-variant-numeric:tabular-nums}
        td,th{border:1px solid #aaa;padding:6px 9px;text-align:left;overflow-wrap:anywhere}
        tr:nth-child(even){background:#f3f5f8}th{position:sticky;top:0;background:#dce8fa}
        @media(prefers-color-scheme:dark){body{background:#111;color:#eee}
        th{background:#33475e}tr:nth-child(even){background:#222}}
        </style></head><body>\(notice)<div style="overflow:auto"><table><thead><tr>\(head)</tr></thead>
        <tbody>\(body)</tbody></table></div></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
        ReleaseOnDeinit.attach(to: viewer, released)
        if let navigation = presenter.navigationController {
            navigation.pushViewController(viewer, animated: true)
        } else {
            presenter.present(UINavigationController(rootViewController: viewer), animated: true)
        }
    }

    private static func parseDelimited(_ text: String, separator: Character, limit: Int)
        -> (rows: [[String]], truncated: Bool)
    {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count && rows.count < limit {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" {
                    if field.count < 2000 { field.append("\"") }
                    i += 1
                } else {
                    quoted.toggle()
                }
            } else if !quoted && c == separator {
                row.append(field)
                field = ""
            } else if !quoted && (c == "\r" || c == "\n") {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else if field.count < 2000 {
                field.append(c)
            }
            i += 1
        }
        if rows.count < limit && (!row.isEmpty || !field.isEmpty) {
            row.append(field)
            rows.append(row)
        }
        return (rows, i < chars.count)
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func confirmPermanentDeletion(
        from presenter: UIViewController,
        title: String,
        message: String,
        confirmTitle: String,
        confirmed: @escaping () -> Void,
    ) {
        PermanentDeleteConfirmation.present(
            from: presenter, title: title, message: message, confirmTitle: confirmTitle, confirm: confirmed,
        )
    }

    func failureText(for error: Error) -> String {
        FailureMessage.text(for: error)
    }

    func makeWorkspace() async throws -> URL {
        try await session.makeTemporaryDirectory()
    }

    func fileIcon(named name: String, isDirectory: Bool) -> UIImage? {
        FilePresentation.image(kind: isDirectory ? .directory : .regular, name: name)
    }

    func rootArtwork(for root: BackendRoot) -> UIImage? {
        SidebarLocation.image(for: root)
    }

    func withProgress<T: Sendable>(
        title: String,
        message: String,
        cancellable: Bool,
        from presenter: UIViewController,
        operation: @escaping @MainActor (_ update: @escaping @MainActor (String) -> Void) async throws -> T,
    ) async throws -> T {
        try await ProgressCard.run(title: title, message: message, cancellable: cancellable, from: presenter, operation: operation)
    }

    /// The app's own viewer over the snapshot, chosen by format like any
    /// local file. Whatever screen the open put on top — pushed or
    /// presented — carries the release with it; an open that showed
    /// nothing releases at once.
    func preview(_ file: URL, title: String, from presenter: UIViewController, released: @escaping () -> Void) {
        Task { @MainActor in
            await presenter.openFile(at: file.path, session: session)
            let shown: UIViewController? = if let top = presenter.navigationController?.topViewController, top !== presenter {
                top
            } else if let presented = presenter.presentedViewController {
                presented
            } else {
                nil
            }
            guard let shown else {
                released()
                return
            }
            ReleaseOnDeinit.attach(to: shown, released)
            // The snapshot sits in a workspace nobody should see: the viewer
            // continues the share's crumbs with the file, and a crumb on the
            // share's folders does what it does on the share's screen.
            if let content = shown as? TabContentViewController, let source = presenter as? TabContentViewController {
                content.decorationSource = DetailDecoration(
                    parent: source, title: title, target: file.path, icon: fileIcon(named: title, isDirectory: false),
                )
            }
        }
    }

    func open(_ location: BackendLocation) {
        guard let screen = SidebarLocation.screen(for: location) else { return }
        front?.replace(screen)
    }

    /// The favourites as one menu: what a catalogue root's crumb offers on a
    /// tap, the way a folder's crumb does. A catalogue has no folder of its own
    /// to save and nothing above it in the trail, so the saved folders are the
    /// whole of the menu — and with none saved it would open empty, which is
    /// why the places stand in for it then.
    var favoritesMenu: UIMenu {
        guard !FileSession.shared.favoritePaths.isEmpty else { return placesMenu }
        return UIMenu(children: [
            FilaMenu.favoriteItems { [weak self] path in self?.front?.open(path) },
        ])
    }

    /// The sidebar's destinations as one menu: a catalogue root's crumb on a
    /// long press. A folder opens in the tab it is picked in; a catalogue or a
    /// server goes through the same jump its row in the sidebar does.
    var placesMenu: UIMenu {
        UIMenu(title: String(localized: "Places"), children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                done(FilaMenu.placeActions(
                    open: { [weak self] path in self?.front?.open(path) },
                    openLocation: { [weak self] location in self?.open(location) },
                ))
            },
        ])
    }

    /// The split view of the front window. A module screen lives inside it, but
    /// on a phone the sidebar is a sheet it presented, and a presented screen
    /// has no split view above it to ask.
    private var front: RootSplitViewController? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?
            .windows.first { $0.isKeyWindow }?.rootViewController as? RootSplitViewController
    }

    /// Over whatever is on top of the page's window: a page's More can be on
    /// a sheet (Properties), and an iPad can have two windows.
    func presentSettings(from presenter: UIViewController) {
        TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
            guard !Self.shows(SettingsViewController.self, top) else { return }
            top.presentSettings()
        }
    }

    /// Whether `top` is already the sheet of that screen: a second tap while
    /// it was on its way must not stack another.
    private static func shows(_ screen: UIViewController.Type, _ top: UIViewController) -> Bool {
        (top as? UINavigationController)?.viewControllers.first.map { type(of: $0) == screen } == true
    }

    var clipboard: BackendClipboardSummary? {
        let clipboard = FileClipboard.shared
        guard !clipboard.isEmpty else { return nil }
        return BackendClipboardSummary(count: clipboard.items.count, isCut: clipboard.isCut, isPasting: clipboard.isPasting)
    }

    func takeToClipboard(_ items: [FileLocation], cut: Bool) {
        FileClipboard.shared.take(items, cut: cut)
    }

    func paste(into destination: FileLocation, mode: TransferMode, from presenter: UIViewController) {
        ClipboardPaste.paste(into: FileReference(destination), mode: mode, from: presenter)
    }

    func presentClipboard(from presenter: UIViewController) {
        let session = session
        TopPresenter.whenReady(from: presenter.view.window?.rootViewController) { top in
            guard !Self.shows(ClipboardViewController.self, top) else { return }
            let controller = ClipboardViewController(clipboard: .shared)
            controller.onReveal = { [weak top] item in
                if item.backend == session.local.id {
                    top?.shell?.follow(.reveal(session.local.absolutePath(item.path)))
                } else if let parent = item.path.parent,
                          let screen = SidebarLocation.screen(for: BackendLocation(backend: item.backend, item: parent.description))
                {
                    // A share's browser has no selection to land on; its
                    // folder is the nearest thing to revealing the entry.
                    top?.shell?.replace(screen)
                }
            }
            top.presentAsSheet(UINavigationController(rootViewController: controller))
        }
    }

    func clearClipboard() {
        FileClipboard.shared.clear()
    }

    func drop(_ items: [UIDragItem], into destination: FileLocation, from presenter: UIViewController) {
        FileDrop.receive(items, into: FileReference(destination), from: presenter)
    }

    func receiveFiles(
        _ items: [UIDragItem],
        conformingTo types: [UTType],
        from presenter: UIViewController,
        _ receive: @escaping @MainActor ([String]) async -> Void,
    ) {
        FileDrop.receiveFiles(items, conformingTo: types, from: presenter, receive)
    }
}

/// A snapshot's workspace lives as long as the screen showing it; this
/// rides on that screen and runs the release when it is gone.
private final class ReleaseOnDeinit {
    private static var key = 0
    private let release: () -> Void

    private init(_ release: @escaping () -> Void) {
        self.release = release
    }

    static func attach(to owner: AnyObject, _ release: @escaping () -> Void) {
        objc_setAssociatedObject(owner, &key, ReleaseOnDeinit(release), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    deinit {
        release()
    }
}
