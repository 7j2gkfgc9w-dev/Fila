#if canImport(UIKit)
    import Darwin
    import FilaBackendKit
    import Then
    import UIKit
    import SnapKit

    /// A directory on a remote file backend, over the neutral file contract.
    ///
    /// What the local browser is to `LocalFileAccess`, this is to
    /// `FileService`: one listing owner on the shared list base, pulled one
    /// batch at a time, refreshed on the backend's invalidation hints, with the
    /// backend's bookmarks and history. A file opens as a snapshot — a bounded
    /// download into an app-owned workspace, shown by the app's own viewer and
    /// removed when the viewer lets go — and can be saved into the local
    /// filesystem through the app's operation centre. The server is written only
    /// through the shell: Paste and a drop go to the app's operation centre.
    ///
    /// Not protocol-specific: the backend is `any FileBackend` and every request
    /// is one the contract names. An SMB share and an FTP root would share this
    /// screen unchanged.
    public final class FileServiceBrowserViewController: BackendListViewController<FileEntry>, TabContentDecorationSource {
        /// A snapshot larger than this is not downloaded for a look: the
        /// workspace is on the device's own storage and a preview is not a
        /// transfer the user asked to keep.
        public static let previewSizeLimit: Int64 = 512 * 1024 * 1024

        public let backend: any FileBackend
        public let path: ServicePath
        private var visitRecorded = false
        private var truncationReported = false
        private var snapshotTask: Task<Void, Never>?
        /// Used by saved file shortcuts and search results. The file is opened
        /// only after its actual parent has loaded, never guessed from its name.
        public var opensSavedFileNamed: String?
        private let cell = UICollectionView.CellRegistration<BackendRowCell, FileEntry> { cell, _, entry in
            // No fallback: a file is never drawn as a glyph, and the shell that
            // owns the artwork always exists in the app.
            let icon = BackendScreens.shell?.fileIcon(named: entry.name, isDirectory: entry.entersDirectory)
            cell.configure(name: entry.name, detail: FileServiceBrowserViewController.detail(for: entry), image: icon)
            cell.accessories = entry.entersDirectory ? [.disclosureIndicator()] : []
            cell.contentView.alpha = entry.isHidden ? 0.55 : 1
        }

        /// The package's own catalogue: this target is compiled into
        /// FilaCore, whose bundle has no strings of its own.
        private var bundle: Bundle {
            .module
        }

        public init(backend: any FileBackend, path: ServicePath) {
            self.backend = backend
            self.path = path
            super.init()
            title = path.name ?? backend.root.displayName
            trailingNavigationItems = barItems
            wantsSearchButton = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipboardChanged), name: .filaClipboardChanged, object: nil)
        }

        /// The ellipsis, and the clipboard beside it while something is held.
        private var barItems: [UIBarButtonItem] {
            [actionsItem] +
                (UIDevice.current.userInterfaceIdiom == .pad ? [twoPanesItem] : []) +
                (BackendScreens.shell?.clipboard == nil ? [] : [clipboardItem])
        }

        private lazy var twoPanesItem = UIBarButtonItem(
            image: UIImage(systemName: "rectangle.split.2x1"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                BackendScreens.shell?.presentTwoPanes(
                    left: FileLocation(backend: backend.id, path: path), from: self
                ).then {
            $0.accessibilityLabel = "Two Panes"
            $0.title = "Two Panes"
        }
            }
        )

        @objc private func clipboardChanged() {
            trailingNavigationItems = barItems
        }

        /// Paste lands here through the app's operation centre: the items may be
        /// local files or another share's, and the transfer decides how they travel.
        private lazy var clipboardItem = makeClipboardItem { [weak self] mode in
            guard let self else { return }
            BackendScreens.shell?.paste(into: FileLocation(backend: backend.id, path: path), mode: mode, from: self)
        }

        // MARK: - Decoration

        /// The share, then every folder down to this one. The share wears the
        /// picture its sidebar row has; the folders wear the folder icon.
        public func decorationCrumbs(for _: TabContentViewController) -> [PathBarView.Crumb] {
            let shell = BackendScreens.shell
            var crumbs = [PathBarView.Crumb(
                title: backend.root.displayName,
                target: ServicePath.root.description,
                icon: shell?.rootArtwork(for: backend.root),
            )]
            var prefix = ServicePath.root
            for component in path.components {
                guard let next = try? prefix.appending(component) else { break }
                prefix = next
                crumbs.append(PathBarView.Crumb(
                    title: component,
                    target: prefix.description,
                    icon: shell?.fileIcon(named: component, isDirectory: true),
                ))
            }
            return crumbs
        }

        /// A tapped crumb: back to that folder's screen when it is on this
        /// stack, which it is after a descent; otherwise, after a jump into a
        /// deep folder from the sidebar, forward into a screen for it.
        public func tabContent(_: TabContentViewController, didSelectDecorationCrumb crumb: PathBarView.Crumb) {
            guard let ancestor = try? ServicePath(crumb.target), let navigation = navigationController else { return }
            let existing = navigation.viewControllers.last { controller in
                guard let browser = controller as? FileServiceBrowserViewController else { return false }
                return browser.backend.id == backend.id && browser.path == ancestor
            }
            if let existing {
                navigation.popToViewController(existing, animated: true)
            } else {
                navigation.pushViewController(FileServiceBrowserViewController(backend: backend, path: ancestor), animated: true)
            }
        }

        deinit {
            snapshotTask?.cancel()
        }

        private lazy var actionsItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.actionElements() ?? []) }]),
        ).then {
            $0.accessibilityLabel = String(localized: "Actions", bundle: bundle)
        }

        private func actionElements() -> [UIMenuElement] {
            let favorite = isFavorite
            let toggle = UIAction(
                title: favorite
                    ? String(localized: "Remove from Favorites", bundle: bundle)
                    : String(localized: "Add to Favorites", bundle: bundle),
                image: UIImage(systemName: favorite ? "star.slash" : "star"),
            ) { [weak self] _ in
                guard let self else { return }
                do {
                    try backend.setFavorite(path, included: !favorite)
                } catch {
                    BackendScreens.shell?.alert(
                        title: String(localized: "Could Not Save Favorite", bundle: bundle),
                        message: BackendScreens.shell?.failureText(for: error) ?? String(describing: error),
                    )
                }
            }
            let search = UIAction(
                title: String(localized: "Search in Folder", bundle: bundle),
                image: UIImage(systemName: "magnifyingglass"),
            ) { [weak self] _ in self?.search() }
            let history = RemoteFolderHistory.shared
            let previous = UIAction(
                title: String(localized: "Previous Folder", bundle: bundle),
                image: UIImage(systemName: "chevron.backward"),
                attributes: history.canGoBack ? [] : .disabled
            ) { _ in
                if let destination = history.step(-1) {
                    BackendScreens.shell?.open(destination)
                }
            }
            let forward = UIAction(
                title: String(localized: "Next Folder", bundle: bundle),
                image: UIImage(systemName: "chevron.forward"),
                attributes: history.canGoForward ? [] : .disabled
            ) { _ in
                if let destination = history.step(1) {
                    BackendScreens.shell?.open(destination)
                }
            }
            let recent: [UIMenuElement] = history.recent.map { location in
                UIAction(
                    title: (location.path.name ?? String(localized: "Root", bundle: bundle))
                        + " · " + location.backend.rawValue,
                    image: UIImage(systemName: "clock"),
                ) { _ in
                    history.jump(to: location)
                    BackendScreens.shell?.open(
                        BackendLocation(backend: location.backend, item: location.path.description)
                    )
                }
            }
            let historyMenu = UIMenu(
                title: String(localized: "Folder History", bundle: bundle),
                image: UIImage(systemName: "clock.arrow.circlepath"),
                children: [previous, forward] + recent
            )
            let refresh = UIAction(
                title: String(localized: "Refresh", bundle: bundle),
                image: UIImage(systemName: "arrow.clockwise"),
            ) { [weak self] _ in
                self?.reload()
            }
            let newFolder = UIAction(
                title: String(localized: "New Folder", bundle: bundle),
                image: UIImage(systemName: "folder.badge.plus"),
            ) { [weak self] _ in
                self?.promptNewFolder()
            }
            return [
                UIMenu(options: .displayInline, children: [toggle]),
                UIMenu(options: .displayInline, children: [newFolder, search, refresh]),
                historyMenu,
                settingsMenuElement,
            ]
        }

        /// The backend's sidebar contribution is its authority on favourites;
        /// this is its latest snapshot, not a second store.
        private var favoritesSnapshot: Set<ServicePath> = []
        private var sidebarTask: Task<Void, Never>?

        private var isFavorite: Bool {
            favoritesSnapshot.contains(path)
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            collectionView.delegate = self
            collectionView.dragDelegate = self
            collectionView.dropDelegate = self
            collectionView.dragInteractionEnabled = true
            sidebarTask = Task { [weak self] in
                guard let self else { return }
                for await snapshot in backend.sidebarUpdates() {
                    guard !Task.isCancelled else { return }
                    favoritesSnapshot = Set(snapshot.favorites.compactMap(\.path))
                }
            }
        }

        /// Bounded recursive filename search, independent of the current
        /// listing's 50,000-row visual limit.
        override public func search() {
            navigationController?.pushViewController(
                RemoteFileSearchViewController(backend: backend, root: path),
                animated: true
            )
        }

        // MARK: - List hooks

        override public func makeCell(_ collectionView: UICollectionView, at indexPath: IndexPath, for item: FileEntry) -> UICollectionViewCell {
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }

        override public func load() -> AsyncThrowingStream<[FileEntry], Error> {
            let backend = backend
            let path = path
            // Nothing of the screen is captured: a listing in flight after a
            // pop must not keep it alive while its cursor is torn down.
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let service = try await backend.fileService()
                        for try await batch in try await service.list(path) {
                            try Task.checkCancellation()
                            continuation.yield(batch)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        override public func changes() async throws -> AsyncThrowingStream<Void, Error>? {
            let service = try await backend.fileService()
            return try await service.changes(in: path)
        }

        override public func arrange(_ items: [FileEntry]) -> [FileEntry] {
            // Deduplicated by name, the first arrival kept: a server pages a
            // directory that is live — or answers however it likes — and one
            // entry arriving twice would put two rows with the same identity
            // into the snapshot, which is a crash rather than a glitch.
            var seen = Set<String>()
            return items.filter { seen.insert($0.name).inserted }.sorted { a, b in
                if a.entersDirectory != b.entersDirectory {
                    return a.entersDirectory
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        override public var statusContent: StatusView.Content? {
            guard visible.isEmpty else { return nil }
            if isLoading, items.isEmpty {
                return .loading(String(localized: "Connecting…", bundle: bundle))
            }
            if let loadFailure {
                return .message(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "Unable to List Folder", bundle: bundle),
                    detail: BackendScreens.shell?.failureText(for: loadFailure) ?? loadFailure.localizedDescription,
                    button: String(localized: "Try Again", bundle: bundle),
                )
            }
            return .message(
                symbol: "folder",
                title: String(localized: "Empty Folder", bundle: bundle),
                detail: String(localized: "This folder is empty. Open another folder, or go back.", bundle: bundle),
            )
        }

        override public func statusAction() {
            reload()
        }

        override public func loadDidFail(_ error: Error, hadRows: Bool) {
            guard hadRows else { return }
            BackendScreens.shell?.alert(
                title: String(localized: "Could Not Refresh", bundle: bundle),
                message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription,
            )
        }

        override public func loadDidComplete(received _: Int, elapsed _: TimeInterval, failed: Bool) async {
            guard !failed else { return }
            if !visitRecorded {
                visitRecorded = true
                try? backend.recordVisit(path)
                RemoteFolderHistory.shared.record(FileLocation(backend: backend.id, path: path))
            }
            if let name = opensSavedFileNamed,
               let saved = visible.first(where: { $0.name == name && $0.kind == .file }) {
                opensSavedFileNamed = nil
                open(saved)
            }
            if isTruncated, !truncationReported {
                truncationReported = true
                BackendScreens.shell?.toast(String(localized: "Showing the first \(maximumItemCount) items", bundle: bundle))
            }
        }

        // MARK: - Opening

        /// A remote URL is handed to an external player without downloading.
        /// A local viewer still uses the explicit, bounded snapshot action.
        private func open(_ entry: FileEntry) {
            guard let child = try? path.appending(entry.name) else { return }
            if entry.entersDirectory {
                navigationController?.pushViewController(
                    FileServiceBrowserViewController(backend: backend, path: child), animated: true
                )
                return
            }
            let preview: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.snapshot(entry, at: child, forPreview: true) { [weak self] file, release in
                    guard let self else { release(); return }
                    BackendScreens.shell?.preview(file, title: entry.name, from: self, released: release)
                }
            }
            if let network = backend as? any RemoteOpenURLProviding,
               let url = network.remoteOpenURL(for: child) {
                let smallEnough = entry.size.map { $0 <= Self.previewSizeLimit } == true
                // Preview text and CSV through separate bounded local viewers.
                // Arbitrary-size/unknown-size items are never staged by default.
                let textEnough = entry.size.map { $0 <= 8 * 1024 * 1024 } == true
                let mediaTypes: Set<String> = [
                    "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm",
                    "ts", "m2ts", "mpeg", "mpg", "vob", "iso",
                    "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "wma",
                ]
                let textTypes: Set<String> = [
                    "csv", "tsv", "txt", "log", "md", "markdown", "json", "xml",
                    "yaml", "yml", "ini", "conf", "cfg", "swift", "py", "js",
                    "ts", "html", "css", "sh", "sql", "toml", "bat", "c", "h",
                    "cpp", "hpp", "java", "kt", "go", "rs", "rb", "php",
                ]
                let ext = (entry.name as NSString).pathExtension.lowercased()
                let textPreview: @MainActor () -> Void = { [weak self] in
                    guard let self else { return }
                    self.snapshot(entry, at: child, forPreview: true) { [weak self] file, release in
                        guard let self else { release(); return }
                        BackendScreens.shell?.previewText(file, title: entry.name, from: self, released: release)
                    }
                }
                let codePreview: @MainActor () -> Void = { [weak self] in
                    guard let self else { return }
                    self.snapshot(entry, at: child, forPreview: true) { [weak self] file, release in
                        guard let self else { release(); return }
                        BackendScreens.shell?.previewCode(file, title: entry.name, from: self, released: release)
                    }
                }
                let tablePreview: @MainActor () -> Void = { [weak self] in
                    guard let self else { return }
                    self.snapshot(entry, at: child, forPreview: true) { [weak self] file, release in
                        guard let self else { release(); return }
                        BackendScreens.shell?.previewCSVTable(file, title: entry.name, from: self, released: release)
                    }
                }
                let editor: (@MainActor () -> Void)? =
                    textEnough && textTypes.contains(ext) && entry.kind == .file
                    && entry.size.map { $0 <= RemoteTextEditorViewController.maximumBytes } == true
                    ? { [weak self] in self?.editRemoteText(entry) } : nil
                let openInApps: @MainActor () -> Void = { [weak self] in
                    guard let self else { return }
                    self.snapshot(entry, at: child, forPreview: true) { [weak self] file, release in
                        guard let self else { release(); return }
                        BackendScreens.shell?.openInSystemApps(file, from: self, released: release)
                    }
                }
                BackendScreens.shell?.offerRemoteOpen(
                    from: self, fileName: entry.name, url: url,
                    media: mediaTypes.contains(ext), fileExtension: ext,
                    preview: smallEnough ? preview : nil,
                    text: textEnough && textTypes.contains(ext) ? textPreview : nil,
                    code: textEnough && textTypes.contains(ext) ? codePreview : nil,
                    editText: editor,
                    table: textEnough && (ext == "csv" || ext == "tsv") ? tablePreview : nil,
                    openInApps: smallEnough ? openInApps : nil
                )
            } else {
                preview()
            }
        }

        /// Downloads `entry` into a fresh workspace, behind the delayed progress
        /// card, and hands the file over with the closure that removes the
        /// workspace. A failed or cancelled download removes it itself and
        /// says why, except a cancellation, which is silent.
        ///
        /// The file is written as `name`, the entry's own unless a save chose
        /// another. Only a preview is held to `previewSizeLimit`: a save is a
        /// transfer the user asked to keep, and the limit's card sends them to
        /// it.
        private func snapshot(
            _ entry: FileEntry,
            at child: ServicePath,
            named name: String? = nil,
            forPreview: Bool,
            then use: @escaping @MainActor (URL, @escaping () -> Void) -> Void,
        ) {
            guard let shell = BackendScreens.shell else { return }
            if forPreview, let size = entry.size, size > Self.previewSizeLimit {
                shell.alert(
                    title: String(localized: "File Too Large to Preview", bundle: bundle),
                    message: String(
                        localized: "“\(entry.name)” is \(Self.format(size)), over the \(Self.format(Self.previewSizeLimit)) preview limit. Save it to Fila instead.",
                        bundle: bundle,
                    ),
                )
                return
            }
            snapshotTask?.cancel()
            let backend = backend
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                var workspace: URL?
                do {
                    let directory = try await shell.makeWorkspace()
                    workspace = directory
                    let target = directory.appendingPathComponent(name ?? entry.name)
                    try await shell.withProgress(
                        title: String(localized: "Downloading…", bundle: bundle),
                        message: String(localized: "Downloading “\(entry.name)” from the server.", bundle: bundle),
                        cancellable: true,
                        from: self,
                    ) { update in
                        let service = try await backend.fileService()
                        let descriptor = try Self.openStaging(target)
                        defer { close(descriptor) }
                        try await service.copyContents(of: child, to: descriptor) { progress in
                            Task { @MainActor in
                                guard let expected = progress.expected, expected > 0 else { return }
                                update(String(
                                    localized: "\(Self.format(progress.completed)) of \(Self.format(expected))", bundle: self.bundle,
                                ))
                            }
                        }
                    }
                    try Task.checkCancellation()
                    use(target) { try? FileManager.default.removeItem(at: directory) }
                } catch {
                    if let workspace {
                        try? FileManager.default.removeItem(at: workspace)
                    }
                    guard !(error is CancellationError), !Task.isCancelled else { return }
                    shell.alert(
                        title: String(localized: "Could Not Download", bundle: bundle),
                        message: shell.failureText(for: error),
                    )
                }
            }
            snapshotTask = task
        }

        /// Saves `entry` into the local filesystem: a snapshot under the name
        /// the picker chose, then the app's own copy job into the chosen
        /// folder, then the workspace goes.
        private func save(_ entry: FileEntry) {
            guard let child = try? path.appending(entry.name), let shell = BackendScreens.shell else { return }
            let picker = shell.saveDestinationPicker(fileName: entry.name) { [weak self] destination in
                guard let self else { return }
                // The picker's name field and a tapped file both name the
                // target; the copy job keeps the name the snapshot has.
                let chosen = destination.lastPathComponent
                let name = chosen.isEmpty || chosen == "." || chosen == ".." ? entry.name : chosen
                snapshot(entry, at: child, named: name, forPreview: false) { file, release in
                    Task { @MainActor in
                        defer { release() }
                        do {
                            try await shell.copy(file, into: destination.deletingLastPathComponent().path, subtitle: name)
                            shell.toast(String(localized: "Saved “\(name)”", bundle: self.bundle))
                        } catch {
                            shell.alert(
                                title: String(localized: "Could Not Save", bundle: self.bundle),
                                message: shell.failureText(for: error),
                            )
                        }
                    }
                }
            }
            shell.presentSheet(picker, from: self)
        }

        private static func openStaging(_ url: URL) throws -> Int32 {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw StagingError(code: errno, path: url.path) }
            return descriptor
        }

        struct StagingError: Error, LocalizedError {
            let code: Int32
            let path: String
            var errorDescription: String? {
                String(localized: "The file could not be saved on this device. Try again.", bundle: .module)
            }
        }

        // MARK: - Remote filesystem operations

        private func writableService() async throws -> any WritableFileService {
            let service = try await backend.fileService()
            guard let writable = service as? any WritableFileService else {
                throw NSError(
                    domain: "Fila.RemoteFileActions",
                    code: 405,
                    userInfo: [NSLocalizedDescriptionKey: String(
                        localized: "This server does not support changes.",
                        bundle: bundle,
                    )],
                )
            }
            return writable
        }

        private func reportRemoteError(_ error: Error, title: String) {
            BackendScreens.shell?.alert(
                title: title,
                message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription,
            )
        }

        private func promptNewFolder() {
            guard let shell = BackendScreens.shell else { return }
            shell.promptRemoteNewFolder(from: self) { [weak self] name in
                guard let self else { return }
                Task { @MainActor [self] in
                    do {
                        let destination = try self.path.appending(name)
                        try await self.writableService().createDirectory(destination)
                        self.backend.invalidate([self.path])
                        self.reload()
                        shell.toast(String(localized: "Folder created", bundle: self.bundle))
                    } catch {
                        self.reportRemoteError(error, title: String(localized: "Could Not Create Folder", bundle: self.bundle))
                    }
                }
            }
        }

        private func promptRename(_ entry: FileEntry) {
            guard let shell = BackendScreens.shell else { return }
            shell.promptRemoteRename(from: self, currentName: entry.name) { [weak self] name in
                guard let self, name != entry.name else { return }
                Task { @MainActor [self] in
                    do {
                        let source = try self.path.appending(entry.name)
                        let destination = try self.path.appending(name)
                        try await self.writableService().move(source, to: destination, policy: .failIfExists)
                        self.backend.invalidate([self.path])
                        self.reload()
                        shell.toast(String(localized: "Renamed", bundle: self.bundle))
                    } catch {
                        self.reportRemoteError(error, title: String(localized: "Could Not Rename", bundle: self.bundle))
                    }
                }
            }
        }

        private func copyRemotePath(_ entry: FileEntry) {
            guard let child = try? path.appending(entry.name) else { return }
            UIPasteboard.general.string = backend.root.displayName + "/" + child.description
            BackendScreens.shell?.toast(String(localized: "Copied", bundle: bundle))
        }

        /// A text edit is explicit. No large file is silently downloaded,
        /// no binary or non-UTF-8 file is interpreted as text, and a successful
        /// save keeps a separate server-side copy of the original.
        private func editRemoteText(_ entry: FileEntry) {
            guard entry.kind == .file, let size = entry.size,
                  size <= RemoteTextEditorViewController.maximumBytes,
                  let child = try? path.appending(entry.name),
                  let shell = BackendScreens.shell else { return }
            snapshot(entry, at: child, forPreview: true) { [weak self] file, release in
                guard let self else { release(); return }
                guard let editor = RemoteTextEditorViewController(
                    backend: self.backend, path: child, metadata: entry,
                    snapshot: file, released: release
                ) else {
                    release()
                    shell.alert(
                        title: String(localized: "Cannot Edit File", bundle: self.bundle),
                        message: String(localized: "Only small UTF-8 text files can be edited.", bundle: self.bundle)
                    )
                    return
                }
                let navigation = UINavigationController(rootViewController: editor)
                navigation.isModalInPresentation = true
                self.present(navigation, animated: true)
            }
        }

        private func showRemoteInformation(_ entry: FileEntry) {
            guard let child = try? path.appending(entry.name) else { return }
            let kind: String
            switch entry.kind {
            case .directory: kind = String(localized: "Folder", bundle: bundle)
            case .file: kind = String(localized: "File", bundle: bundle)
            case .symbolicLink: kind = String(localized: "Link", bundle: bundle)
            case .other: kind = String(localized: "Other", bundle: bundle)
            }
            var lines = [
                String(localized: "Type", bundle: bundle) + ": " + kind,
                String(localized: "Path", bundle: bundle) + ": " + backend.root.displayName + "/" + child.description,
            ]
            if let size = entry.size {
                lines.append(String(localized: "Size", bundle: bundle) + ": " +
                    ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let modified = entry.modified {
                lines.append(String(localized: "Modified", bundle: bundle) + ": " +
                    modified.formatted(date: .abbreviated, time: .shortened))
            }
            BackendScreens.shell?.showRemoteInformation(
                from: self,
                title: entry.name,
                message: lines.joined(separator: "\n"),
            )
        }

        private func confirmDelete(_ entry: FileEntry) {
            guard let shell = BackendScreens.shell else { return }
            let isFolder = entry.kind == .directory
            shell.confirmPermanentDeletion(
                from: self,
                title: String(localized: "Delete Permanently?", bundle: bundle),
                message: isFolder
                    ? String(localized: "Delete this folder and all of its contents permanently? This cannot be undone.", bundle: bundle)
                    : String(localized: "Delete this file permanently? This cannot be undone.", bundle: bundle),
                confirmTitle: String(localized: "Delete", bundle: bundle),
            ) { [weak self] in
                self?.performRemoteDelete(entry)
            }
        }

        /// Build a complete leaf-first plan BEFORE deleting any item.
        /// Symbolic links are removed as links, never followed into directories.
        /// A 10,000-item limit refuses oversized operations before mutation.
        private func deletionPlan(
            service: any WritableFileService,
            target: ServicePath,
            isDirectory: Bool,
        ) async throws -> [(path: ServicePath, directory: Bool)] {
            var plan: [(path: ServicePath, directory: Bool)] = []
            var stack: [(path: ServicePath, directory: Bool, visited: Bool)] = [
                (target, isDirectory, false),
            ]
            while let item = stack.popLast() {
                try Task.checkCancellation()
                if !item.directory || item.visited {
                    plan.append((item.path, item.directory))
                    continue
                }
                stack.append((item.path, true, true))
                var seen = Set<String>()
                var children: [FileEntry] = []
                for try await batch in try await service.list(item.path) {
                    for child in batch {
                        guard seen.insert(child.name).inserted else {
                            throw NSError(
                                domain: "Fila.RemoteFileActions",
                                code: 409,
                                userInfo: [NSLocalizedDescriptionKey: "Duplicate remote entry; deletion cancelled."],
                            )
                        }
                        children.append(child)
                        guard children.count + plan.count + stack.count <= 10_000 else {
                            throw NSError(
                                domain: "Fila.RemoteFileActions",
                                code: 413,
                                userInfo: [NSLocalizedDescriptionKey: "More than 10,000 items. Delete smaller folders."],
                            )
                        }
                    }
                }
                for child in children.reversed() {
                    let childPath = try item.path.appending(child.name)
                    // A symbolic link resolving to a folder is still a link,
                    // NOT a directory to traverse or recursively delete.
                    stack.append((childPath, child.kind == .directory, false))
                }
            }
            return plan
        }

        private func performRemoteDelete(_ entry: FileEntry) {
            guard let shell = BackendScreens.shell else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let service = try await writableService()
                    let target = try path.appending(entry.name)
                    let plan = try await deletionPlan(
                        service: service,
                        target: target,
                        isDirectory: entry.kind == .directory,
                    )
                    _ = try await shell.withProgress(
                        title: String(localized: "Deleting…", bundle: bundle),
                        message: String(localized: "Deleting files from the server", bundle: bundle),
                        cancellable: false,
                        from: self,
                    ) { update in
                        for (index, item) in plan.enumerated() {
                            try Task.checkCancellation()
                            if item.directory {
                                try await service.removeEmptyDirectory(item.path)
                            } else {
                                try await service.removeFile(item.path)
                            }
                            update("\(index + 1) / \(plan.count)")
                        }
                        return plan.count
                    }
                    backend.invalidate([path])
                    reload()
                    shell.toast(String(localized: "Deleted", bundle: bundle))
                } catch {
                    // A server can fail after removing some children. Always
                    // re-list the folder and report the error, never retry
                    // silently or claim the operation was atomic.
                    backend.invalidate([path])
                    reload()
                    reportRemoteError(error, title: String(localized: "Could Not Delete", bundle: bundle))
                }
            }
        }

        // MARK: - Wording

        static func detail(for entry: FileEntry) -> String? {
            var pieces: [String] = []
            if let size = entry.size, !entry.entersDirectory {
                pieces.append(format(size))
            }
            if let modified = entry.modified {
                pieces.append(modified.formatted(date: .abbreviated, time: .shortened))
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
        }

        static func format(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    extension FileServiceBrowserViewController: UICollectionViewDelegate {
        public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: true)
            guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
            open(entry)
        }

        public func collectionView(
            _: UICollectionView,
            contextMenuConfigurationForItemAt indexPath: IndexPath,
            point _: CGPoint,
        ) -> UIContextMenuConfiguration? {
            guard let entry = dataSource.itemIdentifier(for: indexPath) else { return nil }
            holdsReloads = true
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                var children: [UIMenuElement] = []
                if entry.kind == .directory || entry.kind == .file {
                    let child = try? path.appending(entry.name)
                    let favorite = child.map { self.favoritesSnapshot.contains($0) } ?? false
                    children.append(UIAction(
                        title: favorite
                            ? String(localized: "Remove from Favorites", bundle: bundle)
                            : String(localized: "Add to Favorites", bundle: bundle),
                        image: UIImage(systemName: favorite ? "star.slash" : "star"),
                    ) { [weak self] _ in
                        guard let self, let child else { return }
                        try? backend.setFavorite(child, included: !favorite)
                    })
                }
                if entry.kind == .file {
                    let supported: Set<String> = [
                        "txt", "md", "csv", "tsv", "json", "xml", "yaml", "yml",
                        "ini", "conf", "cfg", "swift", "py", "js", "ts",
                        "html", "css", "sh", "sql", "toml", "log"
                    ]
                    if let size = entry.size, size <= RemoteTextEditorViewController.maximumBytes,
                       supported.contains((entry.name as NSString).pathExtension.lowercased()) {
                        children.append(UIAction(
                            title: String(localized: "Edit Text", bundle: bundle),
                            image: UIImage(systemName: "square.and.pencil")
                        ) { [weak self] _ in self?.editRemoteText(entry) })
                    }
                    children.append(UIAction(
                        title: String(localized: "Preview", bundle: bundle),
                        image: UIImage(systemName: "eye"),
                    ) { [weak self] _ in self?.open(entry) })
                    children.append(UIAction(
                        title: String(localized: "Save to Fila…", bundle: bundle),
                        image: UIImage(systemName: "square.and.arrow.down"),
                    ) { [weak self] _ in self?.save(entry) })
                }
                // Copy and Move put the entry's location on the app's clipboard,
                // to be pasted into any file backend; a link is not carried
                // across backends and is not offered.
                var transfer: [UIMenuElement] = []
                if let child = try? path.appending(entry.name), entry.kind == .file || entry.kind == .directory {
                    let location = FileLocation(backend: backend.id, path: child)
                    transfer.append(UIAction(
                        title: String(localized: "Copy", bundle: bundle),
                        image: UIImage(systemName: "doc.on.doc"),
                    ) { _ in BackendScreens.shell?.takeToClipboard([location], cut: false) })
                    transfer.append(UIAction(
                        title: String(localized: "Move", bundle: bundle),
                        image: UIImage(systemName: "scissors"),
                    ) { _ in BackendScreens.shell?.takeToClipboard([location], cut: true) })
                }
                // Codex remote file management additions: the underlying SMB/WebDAV
                // services already implement writes, but upstream 0.8.3 omitted
                // their controls from this context menu.
                let management: [UIMenuElement] = [
                    UIAction(
                        title: String(localized: "Rename…", bundle: bundle),
                        image: UIImage(systemName: "pencil"),
                    ) { [weak self] _ in self?.promptRename(entry) },
                    UIAction(
                        title: String(localized: "Copy Path", bundle: bundle),
                        image: UIImage(systemName: "doc.on.clipboard"),
                    ) { [weak self] _ in self?.copyRemotePath(entry) },
                    UIAction(
                        title: String(localized: "File Information", bundle: bundle),
                        image: UIImage(systemName: "info.circle"),
                    ) { [weak self] _ in self?.showRemoteInformation(entry) },
                    UIAction(
                        title: String(localized: "Delete Permanently", bundle: bundle),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive,
                    ) { [weak self] _ in self?.confirmDelete(entry) },
                ]
                return UIMenu(title: entry.name, children: [
                    UIMenu(options: .displayInline, children: children),
                    UIMenu(options: .displayInline, children: transfer),
                    UIMenu(options: .displayInline, children: management),
                ])
            }
        }

        public func collectionView(
            _: UICollectionView, willEndContextMenuInteraction _: UIContextMenuConfiguration, animator _: UIContextMenuInteractionAnimating?,
        ) {
            holdsReloads = false
        }
    }

    // MARK: - Drag and drop

    /// A share's files and folders drag to any of Fila's screens — a local
    /// folder downloads them, the music library imports them — and a drop here
    /// uploads, all through the shell's one drop handling. A link is not carried
    /// across backends, the same rule Copy and Move keep.
    extension FileServiceBrowserViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        public func collectionView(_: UICollectionView, itemsForBeginning _: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard let entry = dataSource.itemIdentifier(for: indexPath), entry.kind == .file || entry.kind == .directory,
                  let child = try? path.appending(entry.name) else { return [] }
            return [FileReference.remote(FileLocation(backend: backend.id, path: child)).dragItem()]
        }

        public func collectionView(
            _: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath indexPath: IndexPath?,
        ) -> UICollectionViewDropProposal {
            let operation = FileReference.proposal(for: session, into: .remote(dropTarget(at: indexPath)))
            return UICollectionViewDropProposal(operation: operation, intent: .insertIntoDestinationIndexPath)
        }

        public func collectionView(_: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            BackendScreens.shell?.drop(coordinator.items.map(\.dragItem), into: dropTarget(at: coordinator.destinationIndexPath), from: self)
        }

        /// The folder under the pointer, or this one.
        private func dropTarget(at indexPath: IndexPath?) -> FileLocation {
            if let indexPath, let entry = dataSource.itemIdentifier(for: indexPath), entry.entersDirectory,
               let child = try? path.appending(entry.name)
            {
                return FileLocation(backend: backend.id, path: child)
            }
            return FileLocation(backend: backend.id, path: path)
        }
    }

// MARK: - Persistent remote-folder navigation history

@MainActor
private final class RemoteFolderHistory {
    static let shared = RemoteFolderHistory()
    private struct Saved: Codable {
        var locations: [FileLocation]
        var position: Int
    }
    private let key = "fila.remote.folder.history.v1"
    private var locations: [FileLocation] = []
    private var position = -1

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            locations = Array(saved.locations.suffix(60))
            position = min(max(saved.position, -1), locations.count - 1)
        }
    }

    var canGoBack: Bool { position > 0 }
    var canGoForward: Bool { position >= 0 && position + 1 < locations.count }
    var recent: [FileLocation] { Array(locations.suffix(12).reversed()) }

    func record(_ location: FileLocation) {
        if position >= 0, position < locations.count, locations[position] == location { return }
        if position + 1 < locations.count {
            locations.removeSubrange((position + 1)..<locations.count)
        }
        locations.append(location)
        if locations.count > 60 { locations.removeFirst(locations.count - 60) }
        position = locations.count - 1
        save()
    }

    func step(_ amount: Int) -> BackendLocation? {
        let next = position + amount
        guard locations.indices.contains(next) else { return nil }
        position = next
        save()
        let location = locations[next]
        return BackendLocation(backend: location.backend, item: location.path.description)
    }

    func jump(to location: FileLocation) {
        if let index = locations.lastIndex(of: location) {
            position = index
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(locations: locations, position: position)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Bounded recursive search (no server-wide unbounded enumeration)

@MainActor
private final class RemoteFileSearchViewController: UIViewController, UISearchBarDelegate,
    UITableViewDataSource, UITableViewDelegate
{
    private struct Hit {
        let path: ServicePath
        let entry: FileEntry
    }

    private let backend: any FileBackend
    private let origin: ServicePath
    private let searchBar = UISearchBar()
    private let kindControl = UISegmentedControl(items: ["All", "Files", "Folders"])
    private let table = UITableView(frame: .zero, style: .plain)
    private var matches: [Hit] = []
    private var searchTask: Task<Void, Never>?
    private var newerThanDays: Int?
    private var minimumSize: Int64?
    private var maximumSize: Int64?
    private let maximumScanned = 5_000
    private let maximumDepth = 8
    private let maximumMatches = 250

    init(backend: any FileBackend, root: ServicePath) {
        self.backend = backend
        origin = root
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search Files", bundle: .module)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not supported") }
    deinit { searchTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        searchBar.placeholder = String(localized: "Filename contains…", bundle: .module)
        searchBar.delegate = self
        searchBar.returnKeyType = .search
        kindControl.selectedSegmentIndex = 0
        kindControl.addTarget(self, action: #selector(restartSearch), for: .valueChanged)
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        let stack = UIStackView(arrangedSubviews: [searchBar, kindControl, table])
        stack.axis = .vertical
        stack.spacing = 8
        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.bottom.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(8)
        }

        let sizeMenu = UIMenu(title: String(localized: "Size", bundle: .module), children: [
            UIAction(title: String(localized: "Any Size", bundle: .module)) { [weak self] _ in
                self?.minimumSize = nil; self?.maximumSize = nil; self?.restartSearch()
            },
            UIAction(title: String(localized: "Under 10 MB", bundle: .module)) { [weak self] _ in
                self?.minimumSize = nil; self?.maximumSize = 10_000_000; self?.restartSearch()
            },
            UIAction(title: String(localized: "Over 100 MB", bundle: .module)) { [weak self] _ in
                self?.minimumSize = 100_000_000; self?.maximumSize = nil; self?.restartSearch()
            },
        ])
        let dateMenu = UIMenu(title: String(localized: "Modified", bundle: .module), children: [
            UIAction(title: String(localized: "Any Date", bundle: .module)) { [weak self] _ in
                self?.newerThanDays = nil; self?.restartSearch()
            },
            UIAction(title: String(localized: "Last 7 Days", bundle: .module)) { [weak self] _ in
                self?.newerThanDays = 7; self?.restartSearch()
            },
            UIAction(title: String(localized: "Last 30 Days", bundle: .module)) { [weak self] _ in
                self?.newerThanDays = 30; self?.restartSearch()
            },
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            menu: UIMenu(children: [sizeMenu, dateMenu])
        )
        searchBar.becomeFirstResponder()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        restartSearch()
    }

    @objc private func restartSearch() {
        searchTask?.cancel()
        matches = []
        table.reloadData()
        guard let term = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else {
            title = String(localized: "Search Files", bundle: .module)
            return
        }
        let kind = kindControl.selectedSegmentIndex
        let days = newerThanDays
        let minBytes = minimumSize
        let maxBytes = maximumSize
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try await backend.fileService()
                var folders: [(path: ServicePath, depth: Int)] = [(origin, 0)]
                var index = 0
                var scanned = 0
                while index < folders.count, scanned < maximumScanned,
                      matches.count < maximumMatches {
                    try Task.checkCancellation()
                    let current = folders[index]
                    index += 1
                    for try await batch in try await service.list(current.path) {
                        try Task.checkCancellation()
                        for entry in batch {
                            scanned += 1
                            guard let child = try? current.path.appending(entry.name) else { continue }
                            if entry.kind == .directory, current.depth < maximumDepth {
                                folders.append((child, current.depth + 1))
                            }
                            let kindFits = kind == 0 ||
                                (kind == 1 && entry.kind == .file) ||
                                (kind == 2 && entry.entersDirectory)
                            let sizeFits = (minBytes == nil || (entry.size.map { $0 >= minBytes! } == true))
                                && (maxBytes == nil || (entry.size.map { $0 <= maxBytes! } == true))
                            let dateFits = days == nil || (entry.modified.map {
                                $0 >= Date().addingTimeInterval(-Double(days!) * 86_400)
                            } == true)
                            if kindFits && sizeFits && dateFits &&
                               entry.name.localizedStandardContains(term) {
                                matches.append(Hit(path: child, entry: entry))
                            }
                            if scanned >= maximumScanned || matches.count >= maximumMatches { break }
                        }
                        if scanned >= maximumScanned || matches.count >= maximumMatches { break }
                    }
                    if index % 4 == 0 || matches.count >= maximumMatches {
                        table.reloadData()
                        title = String(localized: "Found", bundle: .module) + " \(matches.count)"
                    }
                }
                table.reloadData()
                title = String(localized: "Found", bundle: .module) + " \(matches.count)"
                    + (scanned >= maximumScanned ? " (limited)" : "")
            } catch is CancellationError {
                // A new search replaces this one without an error card.
            } catch {
                BackendScreens.shell?.alert(
                    title: String(localized: "Search Failed", bundle: .module),
                    message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
                )
            }
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { matches.count }
    func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let hit = matches[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = hit.entry.name
        cell.detailTextLabel?.text = hit.path.description
        cell.imageView?.image = UIImage(systemName: hit.entry.entersDirectory ? "folder" : "doc")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let hit = matches[indexPath.row]
        let directory = hit.entry.entersDirectory ? hit.path : (hit.path.parent ?? origin)
        let browser = FileServiceBrowserViewController(backend: backend, path: directory)
        if !hit.entry.entersDirectory { browser.opensSavedFileNamed = hit.entry.name }
        navigationController?.pushViewController(browser, animated: true)
    }
}

// MARK: - Safe UTF-8 editor with remote conflict detection and backups

@MainActor
private final class RemoteTextEditorViewController: UIViewController {
    static let maximumBytes: Int64 = 2 * 1024 * 1024

    private let backend: any FileBackend
    private let path: ServicePath
    private let originalMetadata: FileEntry
    private let snapshot: URL
    private let original: Data
    private let onRelease: () -> Void
    private let editor = UITextView()
    private var saving = false
    private var workspaceReleased = false

    init?(backend: any FileBackend, path: ServicePath, metadata: FileEntry,
          snapshot: URL, released: @escaping () -> Void) {
        guard let data = try? Data(contentsOf: snapshot, options: .mappedIfSafe),
              data.count <= Int(Self.maximumBytes),
              String(data: data, encoding: .utf8) != nil else { return nil }
        self.backend = backend
        self.path = path
        originalMetadata = metadata
        self.snapshot = snapshot
        original = data
        onRelease = released
        super.init(nibName: nil, bundle: nil)
        title = path.name
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            guard !workspaceReleased else { return }
            workspaceReleased = true
            onRelease()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        editor.text = String(data: original, encoding: .utf8) ?? ""
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.alwaysBounceVertical = true
        view.addSubview(editor)
        editor.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .save,
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
    }

    private func save() {
        guard !saving, let contents = editor.text.data(using: .utf8),
              contents.count <= Int(Self.maximumBytes) else {
            BackendScreens.shell?.alert(
                title: String(localized: "Cannot Edit File", bundle: .module),
                message: String(localized: "Text is over the 2 MB editing limit.", bundle: .module)
            )
            return
        }
        guard contents != original else {
            dismiss(animated: true)
            return
        }
        saving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let backend = backend
        let path = path
        let baseline = originalMetadata
        let original = original
        let snapshot = snapshot
        Task { [weak self] in
            guard let self else { return }
            defer {
                saving = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                guard let shell = BackendScreens.shell else { return }
                let backupName = try await shell.withProgress(
                    title: String(localized: "Saving Text", bundle: .module),
                    message: String(localized: "Checking for changes and backing up…", bundle: .module),
                    cancellable: true, from: self
                ) { update -> String in
                    let service = try await backend.fileService()
                    guard let writable = service as? any WritableFileService else {
                        throw NSError(domain: "Fila.TextEditor", code: 405,
                                      userInfo: [NSLocalizedDescriptionKey: "Server is read-only."])
                    }
                    let current = try await service.details(path)
                    guard current.kind == .file, current.size == baseline.size,
                          current.modified == baseline.modified else {
                        throw NSError(domain: "Fila.TextEditor", code: 409,
                                      userInfo: [NSLocalizedDescriptionKey:
                                        "This file changed on the server. It was not overwritten."])
                    }

                    // Compare the actual bytes, even on servers without timestamps.
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("fila-edit-check-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let verifyFD = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                    guard verifyFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    do {
                        try await service.copyContents(of: path, to: verifyFD) { _ in }
                        close(verifyFD)
                    } catch {
                        close(verifyFD)
                        throw error
                    }
                    guard try Data(contentsOf: temp) == original else {
                        throw NSError(domain: "Fila.TextEditor", code: 409,
                                      userInfo: [NSLocalizedDescriptionKey:
                                        "The remote file changed. Refresh before saving."])
                    }
                    try Task.checkCancellation()
                    guard let parent = path.parent else {
                        throw NSError(domain: "Fila.TextEditor", code: 400)
                    }
                    // Backup is on the same server and never replaces another file.
                    let safePrefix = String((path.name ?? "text").prefix(90))
                    let suffix = ISO8601DateFormatter().string(from: Date())
                        .replacingOccurrences(of: ":", with: "-")
                    let backupName = "." + safePrefix + ".fila-backup-" + suffix
                    let backupPath = try parent.appending(backupName)
                    let sourceFD = Darwin.open(snapshot.path, O_RDONLY | O_CLOEXEC)
                    guard sourceFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    defer { close(sourceFD) }
                    try await writable.writeFile(from: sourceFD, size: Int64(original.count),
                                                 to: backupPath, policy: .failIfExists) { _ in }
                    let confirmed = try await service.details(backupPath)
                    guard confirmed.kind == .file, confirmed.size == Int64(original.count) else {
                        throw NSError(domain: "Fila.TextEditor", code: 500,
                                      userInfo: [NSLocalizedDescriptionKey:
                                        "Could not verify server backup; original left unchanged."])
                    }
                    try Task.checkCancellation()
                    update(String(localized: "Uploading changes…", bundle: .module))
                    let upload = FileManager.default.temporaryDirectory
                        .appendingPathComponent("fila-edit-new-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: upload) }
                    try contents.write(to: upload, options: .atomic)
                    let uploadFD = Darwin.open(upload.path, O_RDONLY | O_CLOEXEC)
                    guard uploadFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    defer { close(uploadFD) }
                    try await writable.writeFile(from: uploadFD, size: Int64(contents.count),
                                                 to: path, policy: .replace) { _ in }
                    let result = try await service.details(path)
                    guard result.kind == .file, result.size == Int64(contents.count) else {
                        throw NSError(domain: "Fila.TextEditor", code: 500,
                                      userInfo: [NSLocalizedDescriptionKey:
                                        "Remote save could not be verified. Check the file."])
                    }
                    backend.invalidate([parent])
                    return backupName
                }
                shell.toast(String(localized: "Saved. Backup:", bundle: .module) + " " + backupName)
                dismiss(animated: true)
            } catch is CancellationError {
                // The backup may already have been published; no source was
                // ever deleted and no unfinished file is exposed.
            } catch {
                BackendScreens.shell?.alert(
                    title: String(localized: "Could Not Save", bundle: .module),
                    message: BackendScreens.shell?.failureText(for: error) ?? error.localizedDescription
                )
            }
        }
    }
}
#endif
