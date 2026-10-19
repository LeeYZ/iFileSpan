import SwiftUI
import Observation
import DeviceCore
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    let service = DeviceService()
    let sidebarService = DeviceSidebarService()
    var devices: [Device] = []
    var apps: [DeviceApp] = []
    var entries: [RemoteEntry] = []
    var deviceID = ""
    var selectedPaths: Set<String> = []
    var selectedPath: String? {
        get { selectedPaths.count == 1 ? selectedPaths.first : nil }
        set { selectedPaths = newValue.map { [$0] } ?? [] }
    }
    var activeBundle = ""
    var activeTitle = "选择一个 App"
    var root: String?
    var directory = "/"
    var search = ""
    var sharingOnly = false
    var hideRestrictedApps = true
    var appIcons: [String: NSImage] = [:]
    var appAvailability: [String: AppAvailability] = [:]
    var sidebarGeneration = UUID()
    var checkingAppAccess = false
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var failedIcons: Set<String> = []
    @ObservationIgnored private var iconRequestActive = false
    var accessMode: AppAccessMode = .automatic
    var connectionInfo: AppConnectionInfo?
    var manualBundle = ""
    var busy = false
    var status = "连接 iPhone 或 iPad，解锁后信任此电脑。"
    var progress: TransferProgress?
    var errorMessage: String?
    var lastBackup: URL?
    var newFolderSheet = false
    var folderName = "新建文件夹"
    var manualSheet = false
    var helpSheet = false
    var dependencyMissing = false
    @ObservationIgnored var cancellation = TransferCancellation()

    var currentDevice: Device? { devices.first { $0.id == deviceID } }
    var selected: RemoteEntry? { entries.first { $0.path == selectedPath } }
    var selectedEntries: [RemoteEntry] { entries.filter { selectedPaths.contains($0.path) } }
    var transferableSelection: [RemoteEntry] { selectedEntries.filter { $0.kind == .file || $0.kind == .directory } }
    var canCopy: Bool { !busy && !transferableSelection.isEmpty }
    var canDelete: Bool { !busy && !selectedEntries.isEmpty && selectedEntries.allSatisfy { $0.kind == .file } }
    var canInstallIPA: Bool { !busy && currentDevice != nil && currentDevice?.connectionError == nil }
    var visibleApps: [DeviceApp] {
        apps.filter { AppListFilter.includes($0, availability: appAvailability[$0.id],
            hideRestrictedApps: hideRestrictedApps, sharingOnly: sharingOnly, search: search) }
    }
    var restrictedAppCount: Int { apps.filter { appAvailability[$0.id] == .restricted }.count }
    var pendingAppCount: Int { apps.filter { appAvailability[$0.id] == .checking }.count }
    var unknownAppCount: Int { apps.filter { appAvailability[$0.id] == .unknown }.count }
    private func resetSidebar() {
        permissionTask?.cancel(); permissionTask = nil
        sidebarGeneration = UUID(); appIcons = [:]; failedIcons = []; appAvailability = [:]; checkingAppAccess = false
    }
    func loadIcon(_ app: DeviceApp) async {
        let generation = sidebarGeneration, udid = deviceID
        guard !udid.isEmpty, appIcons[app.id] == nil, !failedIcons.contains(app.id) else { return }
        // At most one icon request is queued; file operations take priority between requests.
        while busy || iconRequestActive {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard generation == sidebarGeneration, !Task.isCancelled else { return }
        }
        guard generation == sidebarGeneration, !Task.isCancelled,
              appIcons[app.id] == nil, !failedIcons.contains(app.id) else { return }
        iconRequestActive = true
        defer { iconRequestActive = false }
        do {
            let data = try await sidebarService.icon(device: udid, app: app)
            guard generation == sidebarGeneration, !Task.isCancelled else { return }
            if let image = NSImage(data: data), image.isValid { appIcons[app.id] = image }
            else { failedIcons.insert(app.id) }
        } catch {
            if generation == sidebarGeneration && !Task.isCancelled { failedIcons.insert(app.id) }
        }
    }
    private func checkAppAccess() {
        let candidates = apps.filter { self.appAvailability[$0.id] == nil }.sorted {
            if $0.fileSharing != $1.fileSharing { return $0.fileSharing }
            if $0.isSystem != $1.isSystem { return !$0.isSystem }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard !candidates.isEmpty else { return }
        let generation = self.sidebarGeneration, udid = deviceID
        for app in candidates { self.appAvailability[app.id] = .checking }
        self.checkingAppAccess = true
        permissionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.sidebarGeneration { self.checkingAppAccess = false }
                Task { await self.sidebarService.flush(device: udid) }
            }
            do {
                try await withThrowingTaskGroup(of: (String, AppAvailability).self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < candidates.count else { return }
                        let app = candidates[next]; next += 1
                        group.addTask { [self] in
                            let value = try await self.checkPermission(app, device: udid, generation: generation)
                            return (app.id, value)
                        }
                    }
                    for _ in 0..<min(DeviceSidebarService.parallelChecks, candidates.count) { enqueue() }
                    while let (id, result) = try await group.next() {
                        guard generation == self.sidebarGeneration, !Task.isCancelled else {
                            group.cancelAll(); return
                        }
                        self.appAvailability[id] = result
                        enqueue()
                    }
                }
            } catch {
                guard generation == self.sidebarGeneration, !Task.isCancelled else { return }
                for app in candidates where self.appAvailability[app.id] == .checking { self.appAvailability[app.id] = .unknown }
            }
        }
    }
    private func checkPermission(_ app: DeviceApp, device: String, generation: UUID) async throws -> AppAvailability {
        while busy {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == sidebarGeneration else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard generation == sidebarGeneration else { throw CancellationError() }
        if let known = appAvailability[app.id], known == .available || known == .restricted { return known }
        return try await sidebarService.availability(device: device, app: app)
    }
    var backupRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceFiles/Backups", isDirectory: true)
    }
    func perform(_ text: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = text; progress = nil; cancellation = TransferCancellation()
        Task {
            defer { busy = false; progress = nil }
            do { try await operation() }
            catch is CancellationError { status = "操作已取消；尚未提交的设备修改未执行。" }
            catch let error as IPAInstallationError where error.outcomeUnknown {
                errorMessage = error.localizedDescription
                status = "安装结果尚未确认，请先在设备上检查该 App。"
            }
            catch { errorMessage = error.localizedDescription; status = "操作失败，可查看错误详情。" }
        }
    }
    func resetFiles() { entries = []; selectedPath = nil; root = nil; connectionInfo = nil; activeBundle = ""; activeTitle = "选择一个 App" }
    func detect(refreshPermissions: Bool = true) {
        perform("正在检测设备…") { [self] in
            resetSidebar(); resetFiles(); apps = []; devices = []; deviceID = ""
            do { devices = try await service.detect(); dependencyMissing = false }
            catch { dependencyMissing = error is DeviceLibraryError; throw error }
            if let first = devices.first {
                deviceID = first.id; try await loadApps(refreshPermissions: refreshPermissions)
            } else { status = "未发现 USB 设备，请连接设备并点“重新检测”。" }
        }
    }
    func pickDevice(_ id: String) {
        perform("正在读取 App 列表…") { [self] in
            resetSidebar(); resetFiles(); apps = []; deviceID = id; try await loadApps()
        }
    }
    private func loadApps(refreshPermissions: Bool = false) async throws {
        guard let device = currentDevice else { return }
        if let message = device.connectionError { throw DeviceFilesError(message) }
        apps = try await service.apps(device.id)
        appAvailability = try await sidebarService.prepare(device: device, apps: apps, refreshPermissions: refreshPermissions)
        checkAppAccess()
        status = "已连接 \(device.name) · 设备返回 \(apps.count) 个 App，\(apps.filter(\.fileSharing).count) 个开启文件共享。"
    }
    func openApp(_ app: DeviceApp) { open(bundle: app.id, title: app.name) }
    func openMedia() { open(bundle: "", title: "共享媒体") }
    func open(bundle: String, title: String) {
        perform("正在打开 \(title)…") { [self] in
            resetFiles()
            activeBundle = bundle; activeTitle = title
            let opened: (info: AppConnectionInfo, entries: [RemoteEntry])
            do {
                opened = try await service.open(udid: deviceID, bundle: bundle, mode: accessMode)
            } catch {
                // In automatic mode this code means BOTH access attempts were denied.
                if !bundle.isEmpty, accessMode == .automatic,
                   (error as? DeviceFilesError)?.isAccessDenied == true {
                    appAvailability[bundle] = .restricted
                    recordAvailability(bundle: bundle, value: .restricted)
                    if hideRestrictedApps {
                        resetFiles()
                        status = "已隐藏“\(title)”：容器和 Documents 均未获授权。"
                        return
                    }
                }
                throw error
            }
            if !bundle.isEmpty {
                appAvailability[bundle] = .available
                recordAvailability(bundle: bundle, value: .available)
            }
            let info = opened.info
            let start = info.root
            connectionInfo = info; root = start; directory = start
            entries = opened.entries
            status = "\(entries.count) 个项目 · 替换前请关闭设备上的目标 App。"
        }
    }
    private func recordAvailability(bundle: String, value: AppAvailability) {
        guard let app = apps.first(where: { $0.id == bundle }) else { return }
        let udid = deviceID
        Task { await sidebarService.record(device: udid, app: app, value: value) }
    }
    func changeMode(_ value: AppAccessMode) {
        guard !busy else { return }
        accessMode = value
        if !activeBundle.isEmpty { open(bundle: activeBundle, title: activeTitle) }
    }
    func navigate(_ path: String) {
        perform("正在读取目录…") { [self] in
            guard let root, path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return }
            entries = try await service.list(path); directory = path; selectedPath = nil
            status = "\(entries.count) 个项目"
        }
    }
    func progressHandler() -> @Sendable (TransferProgress) -> Void {
        let token = cancellation
        return { [weak self] value in
            Task { @MainActor in
                guard let self, self.busy, self.cancellation === token else { return }
                self.progress = value
            }
        }
    }
    func download() {
        if selectedPaths.count > 1 { downloadSelection(); return }
        guard let item = selected, !busy else { return }
        let panel = NSSavePanel()
        panel.title = item.kind == .directory ? "导出文件夹" : "下载文件"
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("正在下载…") { [self] in
            try await service.download(item.path, to: url, cancellation: cancellation, progress: progressHandler())
            status = "已保存到 \(url.path)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    func upload(replacing: Bool) {
        guard root != nil, !busy else { return }
        let original = selected
        if replacing && original?.kind != .file { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = !replacing; panel.allowsMultipleSelection = !replacing
        panel.title = replacing ? "选择用来替换的本地文件" : "选择要上传的文件"
        guard panel.runModal() == .OK, let local = panel.url else { return }
        if !replacing { pasteFiles(panel.urls); return }
        let target: String
        do { target = replacing ? original!.path : try RemotePath.child(local.lastPathComponent, of: directory) }
        catch { errorMessage = error.localizedDescription; return }
        if replacing {
            let alert = NSAlert()
            alert.messageText = "替换“\(original!.name)”？"
            alert.informativeText = "将用“\(local.lastPathComponent)”替换设备文件。程序会先保存本地备份并校验上传内容。请先关闭设备上的目标 App。"
            alert.addButton(withTitle: "备份并替换"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        perform(replacing ? "正在备份并替换…" : "正在上传…") { [self] in
            let result = try await service.upload(local, to: target, replacing: replacing, backupRoot: backupRoot,
                                                  cancellation: cancellation, progress: progressHandler())
            lastBackup = result.backup
            status = result.warning ?? (replacing ? "替换成功，原文件已保存到本地备份。" : "上传成功。")
            if let warning = result.warning { errorMessage = warning }
            // A refresh failure does not turn a committed transfer into a reported failure.
            do { entries = try await service.list(directory) }
            catch { status += " 列表刷新失败，请重新连接设备。" }
            selectedPath = target
        }
    }
    func installIPA() {
        guard canInstallIPA, let device = currentDevice else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要安装的 IPA"
        panel.prompt = "检查安装包"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        perform("正在检查 IPA…") { [self] in
            let package = try await service.prepareIPA(source, cancellation: cancellation, progress: progressHandler())
            defer { package.discard() }
            try cancellation.check()
            progress = nil
            let alert = NSAlert()
            alert.messageText = "将“\(package.name)”安装到“\(device.name)”？"
            alert.informativeText = "版本：\(package.version)\n标识符：\(package.bundleID)\n大小：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: package.size), countStyle: .file))\n\n同标识符的已有 App 可能被更新。安装需要有效签名和设备授权，本程序不会重签名。上传阶段可以取消；提交安装后无法撤回，请保持设备连接。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "安装")
            guard alert.runModal() == .alertSecondButtonReturn else { status = "已取消安装，未向设备提交安装包。"; return }
            try cancellation.check()
            resetFiles()
            await service.disconnect()
            let warning = try await service.installIPA(package, udid: device.id, cancellation: cancellation, progress: progressHandler())
            cancellation = TransferCancellation() // Discard queued progress from the completed installation.
            progress = TransferProgress("安装已完成，正在刷新应用列表…", cancellable: false)
            resetSidebar()
            do {
                try await loadApps(refreshPermissions: true)
                status = "“\(package.name)”安装完成。" + (warning ?? "")
            } catch {
                status = "设备已确认“\(package.name)”安装完成；App 列表刷新失败，请重新检测。"
                errorMessage = status + "\n" + error.localizedDescription + (warning.map { "\n" + $0 } ?? "")
                return
            }
            if let warning { errorMessage = warning }
        }
    }
    func createFolder() {
        let name = folderName; newFolderSheet = false
        perform("正在创建文件夹…") { [self] in
            try await service.mkdir(name, in: directory)
            entries = try await service.list(directory); status = "已创建文件夹“\(name)”"
        }
    }
    func deleteFile() {
        let items = selectedEntries
        guard canDelete, root != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1 ? "删除“\(items[0].name)”？" : "删除选中的 \(items.count) 个文件？"
        let paths = items.prefix(8).map(\.path).joined(separator: "\n") + (items.count > 8 ? "\n（另有 \(items.count - 8) 个）" : "")
        alert.informativeText = "设备：\(currentDevice?.name ?? deviceID)\n目录：\(activeTitle)\n\(paths)\n\n确认后直接删除，不创建备份。删除后无法通过本程序恢复。请先关闭设备上的目标 App。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "直接删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform("正在删除…") { [self] in
            var deleted = 0; var failure: Error?
            do {
                for item in items {
                    try cancellation.check()
                    try await service.deleteFile(item.path, cancellation: cancellation, progress: progressHandler())
                    deleted += 1; selectedPaths.remove(item.path); entries.removeAll { $0.path == item.path }
                }
            } catch { failure = error }
            status = "已确认删除 \(deleted) 个文件。"
            do { entries = try await service.list(directory) }
            catch { status += " 列表刷新失败，请重新连接设备。" }
            if let failure {
                if failure is CancellationError { status += " 其余操作已取消。" }
                else { errorMessage = "已确认删除 \(deleted) 个文件，后续操作已停止。\n\(failure.localizedDescription)" }
            }
        }
    }

    func selectAllFiles() { if !busy { selectedPaths = Set(entries.map(\.path)) } }
    func openSelectedFolder() { if let selected, selected.kind == .directory, !busy { navigate(selected.path) } }
    func goUp() { if let root, directory != root, !busy { navigate(RemotePath.parent(directory)) } }

    private func checkTransferSelection() -> [RemoteEntry]? {
        let items = transferableSelection
        guard !items.isEmpty, !busy else { return nil }
        let skipped = selectedEntries.count - items.count
        if skipped > 0 {
            let alert = NSAlert(); alert.messageText = "跳过 \(skipped) 个无法复制的项目？"
            alert.informativeText = "权限受限项目、符号链接和特殊文件将被跳过，继续处理其余 \(items.count) 个项目。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "继续")
            guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        }
        return items
    }

    func copySelection() {
        guard let items = checkTransferSelection() else { return }
        // Claim the clipboard now, so Finder cannot paste stale URLs while downloads are pending.
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(UUID().uuidString, forType: NSPasteboard.PasteboardType("local.devicefiles.copy-in-progress"))
        let clipboardVersion = board.changeCount
        perform("正在准备复制的文件…") { [self] in
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeviceFiles/Clipboard/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at: cache) } }
            var ready: [URL] = []; var failures: [String] = []
            for item in items {
                try cancellation.check()
                let destination = cache.appendingPathComponent(item.name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    failures.append("\(item.name)：本地名称冲突，已跳过。"); continue
                }
                do {
                    try await service.download(item.path, to: destination, cancellation: cancellation, progress: progressHandler())
                    ready.append(destination)
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("\(item.name)：\(error.localizedDescription)") }
            }
            guard !ready.isEmpty else { throw DeviceFilesError(failures.joined(separator: "\n")) }
            guard board.changeCount == clipboardVersion else {
                status = "文件已下载，但剪贴板已被其他复制操作改变，请重新复制。"; return
            }
            board.clearContents()
            guard board.writeObjects(ready.map { $0 as NSURL }) else { throw DeviceFilesError("无法把文件写入剪贴板。") }
            published = true
            status = "已复制 \(ready.count) 个项目，可在 Finder 或其他设备目录中粘贴。"
            if !failures.isEmpty { errorMessage = "部分项目未复制：\n" + failures.joined(separator: "\n") }
        }
    }

    func pasteFromClipboard() {
        guard !busy, root != nil else { return }
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        pasteFiles(objects)
    }

    private func pasteFiles(_ urls: [URL]) {
        guard !busy, root != nil else { return }
        let plan: [PasteItem]
        do { plan = try PastePlan.make(urls: urls, directory: directory, entries: entries) }
        catch { errorMessage = error.localizedDescription; return }
        let conflicts = plan.filter { $0.existing != nil }
        var replaceFiles = false
        if !conflicts.isEmpty {
            let alert = NSAlert(); alert.messageText = "发现 \(conflicts.count) 个同名项目"
            alert.informativeText = "可跳过同名项目，或备份后替换同名普通文件。同名文件夹和权限受限项目将跳过。\n" + conflicts.prefix(8).map { $0.source.lastPathComponent }.joined(separator: "\n")
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "跳过同名项")
            if conflicts.contains(where: \.canReplace) { alert.addButton(withTitle: "替换同名文件") }
            let choice = alert.runModal()
            guard choice != .alertFirstButtonReturn else { return }
            replaceFiles = choice == .alertThirdButtonReturn
        }
        let work = plan.filter { $0.existing == nil || (replaceFiles && $0.canReplace) }
        let skipped = plan.count - work.count
        guard !work.isEmpty else { status = "已跳过全部同名项目。"; return }
        perform("正在粘贴 \(work.count) 个项目…") { [self] in
            var copied: Set<String> = []; var failures: [String] = []; var cancelled = false
            for item in work {
                do {
                    try cancellation.check()
                    let result = try await service.uploadItem(item.source, to: item.target, replacing: item.existing != nil,
                        backupRoot: backupRoot, cancellation: cancellation, progress: progressHandler())
                    if let backup = result.backup { lastBackup = backup }
                    copied.insert(item.target)
                    if let warning = result.warning { failures.append(warning) }
                } catch is CancellationError { cancelled = true; break }
                catch { failures.append("\(item.source.lastPathComponent)：\(error.localizedDescription)") }
            }
            status = "已粘贴 \(copied.count) 个项目，跳过 \(skipped) 个。" + (cancelled ? " 其余操作已取消。" : "")
            do { entries = try await service.list(directory); selectedPaths = copied }
            catch { status += " 列表刷新失败，请重新连接设备。" }
            if !failures.isEmpty { errorMessage = "部分项目处理失败：\n" + failures.joined(separator: "\n") }
        }
    }

    private func downloadSelection() {
        guard let items = checkTransferSelection() else { return }
        let panel = NSOpenPanel(); panel.title = "选择批量下载的目标文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        perform("正在批量下载…") { [self] in
            var completed = 0; var failures: [String] = []; var cancelled = false
            for item in items {
                let destination = folder.appendingPathComponent(item.name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    failures.append("\(item.name)：目标已存在，已跳过。"); continue
                }
                do {
                    try cancellation.check()
                    try await service.download(item.path, to: destination, cancellation: cancellation, progress: progressHandler())
                    completed += 1
                } catch is CancellationError { cancelled = true; break }
                catch { failures.append("\(item.name)：\(error.localizedDescription)") }
            }
            status = "已下载 \(completed) 个项目。" + (cancelled ? " 其余操作已取消。" : "")
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            if completed > 0 { NSWorkspace.shared.open(folder) }
        }
    }
    func revealBackups() {
        do {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(backupRoot)
        } catch { errorMessage = error.localizedDescription }
    }
}
