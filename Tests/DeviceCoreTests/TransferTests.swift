import XCTest
@testable import DeviceCore

final class MemoryFS: RemoteFileSystem {
    var files: [String: Data] = ["/Documents/state.db": Data("old database".utf8)]
    var directories: Set<String> = ["/", "/Documents"]
    var links: Set<String> = []
    var handles: [UInt64: (String, Int)] = [:]
    var next: UInt64 = 0
    var listingRequests: [String] = []
    var maximumWrite = 7
    var failCommit = false
    var failRollback = false
    var failFolderCommit = false
    var corruptStagingRead = false
    var deniedListings: Set<String> = []
    var deniedRemovals: Set<String> = []
    var removalAttempts: [String] = []
    var deniedStats: Set<String> = []
    var lostRemoveResponses: Set<String> = []
    var onReadOpen: ((String) -> Void)?
    func stat(_ path: String) throws -> RemoteEntry? {
        if deniedStats.contains(path) { throw DeviceFilesError("MetadataDenied", code: 10) }
        let name = (path as NSString).lastPathComponent
        if links.contains(path) { return RemoteEntry(path: path, name: name, kind: .symbolicLink) }
        if directories.contains(path) { return RemoteEntry(path: path, name: name, kind: .directory) }
        if let data = files[path] { return RemoteEntry(path: path, name: name, kind: .file, size: UInt64(data.count)) }
        return nil
    }
    func list(_ path: String) throws -> [RemoteEntry] {
        listingRequests.append(path)
        if deniedListings.contains(path) { throw DeviceFilesError("listing denied: \(path)") }
        return try Set(Array(files.keys) + Array(directories) + Array(links))
            .filter { $0 != path && RemotePath.parent($0) == path }.sorted().compactMap { try stat($0) }
    }
    func open(_ path: String, writing: Bool) throws -> UInt64 {
        if writing { files[path] = Data() } else { onReadOpen?(path) }
        guard files[path] != nil else { throw DeviceFilesError("missing") }
        next += 1; handles[next] = (path, 0); return next
    }
    func read(_ handle: UInt64, count: Int) throws -> Data {
        guard let (path, offset) = handles[handle], let data = files[path] else { throw DeviceFilesError("invalid handle") }
        var result = Data(data.dropFirst(offset).prefix(count))
        handles[handle] = (path, offset + result.count)
        if corruptStagingRead && path.contains(".devicefiles-upload-") && !result.isEmpty { result[0] ^= 1 }
        return result
    }
    func write(_ handle: UInt64, data: Data) throws -> Int {
        guard let (path, offset) = handles[handle] else { throw DeviceFilesError("invalid handle") }
        let n = min(data.count, maximumWrite)
        files[path]!.append(data.prefix(n)); handles[handle] = (path, offset + n); return n
    }
    func close(_ handle: UInt64) throws { handles.removeValue(forKey: handle) }
    func move(_ from: String, to: String) throws {
        if failCommit && from.contains(".devicefiles-upload-") { throw DeviceFilesError("commit failed") }
        if failRollback && from.contains(".devicefiles-original-") { throw DeviceFilesError("rollback failed") }
        if failFolderCommit && (from as NSString).lastPathComponent.hasPrefix(".devicefiles-folder-") { throw DeviceFilesError("folder commit failed") }
        if directories.contains(from) {
            guard files[to] == nil, !directories.contains(to) else { throw DeviceFilesError("target exists") }
            let movedFiles = files.filter { $0.key.hasPrefix(from + "/") }
            let movedDirectories = directories.filter { $0 == from || $0.hasPrefix(from + "/") }
            for (old, data) in movedFiles { files.removeValue(forKey: old); files[to + old.dropFirst(from.count)] = data }
            for old in movedDirectories { directories.remove(old); directories.insert(to + old.dropFirst(from.count)) }
            return
        }
        guard files[to] == nil, let data = files.removeValue(forKey: from) else { throw DeviceFilesError("rename failed") }
        files[to] = data
    }
    func remove(_ path: String) throws {
        removalAttempts.append(path)
        if deniedRemovals.contains(path) { throw DeviceFilesError("DeleteDenied", code: 10) }
        if directories.contains(path) {
            guard !files.keys.contains(where: { $0.hasPrefix(path + "/") }),
                  !directories.contains(where: { $0 != path && $0.hasPrefix(path + "/") }) else { throw DeviceFilesError("directory not empty") }
            directories.remove(path)
        }
        files.removeValue(forKey: path)
        if lostRemoveResponses.contains(path) { throw DeviceFilesError("Disconnected", code: 11) }
    }
    func mkdir(_ path: String) throws {
        guard files[path] == nil, !directories.contains(path), directories.contains(RemotePath.parent(path)) else { throw DeviceFilesError("mkdir failed") }
        directories.insert(path)
    }
}

final class TransferTests: XCTestCase {
    func testAppOpeningReturnsInitialEntriesWithoutSecondDirectoryRead() throws {
        let fs = MemoryFS()
        let opened = try AppAccessResolver.resolve(mode: .documents) { _ in fs }
        XCTAssertEqual(opened.entries.map(\.path), ["/Documents/state.db"])
        XCTAssertEqual(fs.listingRequests, ["/Documents"])
    }
    func testForcedPermissionRefreshInvalidatesDiskCacheAndRetainsIcon() {
        let app = DeviceApp(id: "example.app", name: "App")
        let cache = SidebarCache(root: temp, device: "a", systemVersion: "27")
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        cache.record(.restricted, app: app); cache.storeIcon(png, app: app); cache.flush()
        cache.invalidatePermissions()
        let next = SidebarCache(root: temp, device: "a", systemVersion: "27")
        XCTAssertNil(next.availability(app))
        XCTAssertEqual(next.icon(app), png)
    }

    func testSidebarPermissionCacheSurvivesReopening() {
        let root = temp.appendingPathComponent("Sidebar")
        let app = DeviceApp(id: "example.app", name: "App", version: "1")
        let first = SidebarCache(root: root, device: "device-a", systemVersion: "27")
        first.record(.restricted, app: app); first.flush()
        let reopened = SidebarCache(root: root, device: "device-a", systemVersion: "27")
        XCTAssertEqual(reopened.availability(app), .restricted)
        reopened.record(.available, app: app); reopened.flush()
        XCTAssertEqual(SidebarCache(root: root, device: "device-a", systemVersion: "27").availability(app), .available)
    }
    func testSidebarPermissionCacheExpiresAndRejectsFutureDate() {
        let app = DeviceApp(id: "example.app", name: "App")
        let cache = SidebarCache(root: temp, device: "a", systemVersion: "27")
        let now = Date(timeIntervalSince1970: 10000)
        cache.record(.restricted, app: app, now: now)
        XCTAssertEqual(cache.availability(app, now: now.addingTimeInterval(599)), .restricted)
        XCTAssertNil(cache.availability(app, now: now.addingTimeInterval(600)))
        XCTAssertNil(cache.availability(app, now: now.addingTimeInterval(-1)))
    }
    func testSidebarCacheSeparatesDeviceSystemAndAppRevision() {
        let app = DeviceApp(id: "example.app", name: "App", version: "1", fileSharing: false)
        let cache = SidebarCache(root: temp, device: "a", systemVersion: "27")
        cache.record(.available, app: app); cache.flush()
        XCTAssertNil(SidebarCache(root: temp, device: "b", systemVersion: "27").availability(app))
        XCTAssertNil(SidebarCache(root: temp, device: "a", systemVersion: "28").availability(app))
        XCTAssertNil(cache.availability(DeviceApp(id: app.id, name: app.name, version: "2")))
        XCTAssertNil(cache.availability(DeviceApp(id: app.id, name: app.name, version: "1", fileSharing: true)))
        XCTAssertNil(cache.availability(DeviceApp(id: app.id, name: app.name, version: "1", applicationType: "System")))
    }
    func testSidebarCacheDoesNotPersistUnknownOrPendingPermissions() {
        let app = DeviceApp(id: "example.app", name: "App")
        let cache = SidebarCache(root: temp, device: "a", systemVersion: "27")
        cache.record(.checking, app: app); cache.record(.unknown, app: app); cache.flush()
        XCTAssertNil(SidebarCache(root: temp, device: "a", systemVersion: "27").availability(app))
    }
    func testSidebarPermissionCacheFlushesBatchAndToleratesCorruption() throws {
        let root = temp.appendingPathComponent("Sidebar")
        let cache = SidebarCache(root: root, device: "a", systemVersion: "27")
        let apps = (0..<16).map { DeviceApp(id: "app.\($0)", name: "App") }
        for app in apps { cache.record(.available, app: app) }
        let second = SidebarCache(root: root, device: "a", systemVersion: "27")
        XCTAssertEqual(apps.compactMap { second.availability($0) }.count, 16)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertNil(SidebarCache(root: root, device: "a", systemVersion: "27").availability(apps[0]))
    }
    func testSidebarIconCacheSurvivesReopeningAndSeparatesRevision() {
        let app = DeviceApp(id: "example.app", name: "App", version: "1")
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        let cache = SidebarCache(root: temp, device: "a", systemVersion: "27")
        cache.storeIcon(png, app: app)
        XCTAssertEqual(SidebarCache(root: temp, device: "a", systemVersion: "27").icon(app), png)
        XCTAssertNil(SidebarCache(root: temp, device: "b", systemVersion: "27").icon(app))
        XCTAssertNil(cache.icon(DeviceApp(id: app.id, name: app.name, version: "2")))
    }
    func testSidebarIconCacheRejectsInvalidAndExpiredData() throws {
        let app = DeviceApp(id: "example.app", name: "App")
        let cache = SidebarCache(root: temp, device: "a", systemVersion: "27")
        cache.storeIcon(Data("not PNG".utf8), app: app)
        XCTAssertNil(cache.icon(app))
        cache.storeIcon(Data([137, 80, 78, 71, 13, 10, 26, 10, 0]), app: app)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first { $0.pathExtension == "png" })
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: file.path)
        XCTAssertNil(cache.icon(app))
    }
    func testSidebarCacheWriteFailureDoesNotBlockBrowsing() throws {
        let file = temp.appendingPathComponent("file")
        try Data().write(to: file)
        let app = DeviceApp(id: "example.app", name: "App")
        let cache = SidebarCache(root: file, device: "a", systemVersion: "27")
        cache.record(.available, app: app); cache.flush()
        XCTAssertEqual(cache.availability(app), .available)
        XCTAssertNil(cache.icon(app))
    }

    func testBothInstallationLookupFailuresHideEveryAppType() {
        for kind in ["System", "User", ""] {
            for sharing in [true, false] {
                let app = DeviceApp(id: "example.app", name: "Example", fileSharing: sharing, applicationType: kind)
                XCTAssertThrowsError(try AppAccessResolver.resolve(mode: .automatic) { (_: Bool) throws -> MemoryFS in
                    throw DeviceFilesError("InstallationLookupFailed", code: -10001)
                }) { error in
                    let denied = (error as? DeviceFilesError)?.isAccessDenied == true
                    XCTAssertTrue(denied)
                    XCTAssertFalse(AppListFilter.includes(app, availability: denied ? .restricted : .unknown, hideRestrictedApps: true))
                    XCTAssertTrue(AppListFilter.includes(app, availability: .restricted, hideRestrictedApps: false))
                }
            }
        }
    }
    func testMixedDenialAndConnectionFailureDoNotHideApp() {
        for deniedContainer in [true, false] {
            XCTAssertThrowsError(try AppAccessResolver.resolve(mode: .automatic) { (container: Bool) throws -> MemoryFS in
                throw DeviceFilesError("failed", code: container == deniedContainer ? -10001 : -3)
            }) { error in
                XCTAssertFalse((error as? DeviceFilesError)?.isAccessDenied == true)
            }
        }
    }
    func testDeniedContainerWithReadableDocumentsRemainsVisible() throws {
        let result = try AppAccessResolver.resolve(mode: .automatic) { container in
            if container { throw DeviceFilesError("InstallationLookupFailed", code: -10001) }
            return MemoryFS()
        }
        XCTAssertEqual(result.info.scope, .documents)
        let app = DeviceApp(id: "example.nonsharing", name: "Example", fileSharing: false)
        XCTAssertTrue(AppListFilter.includes(app, availability: .available, hideRestrictedApps: true))
    }
    func testExplicitContainerErrorDoesNotImplyBothScopesDenied() {
        XCTAssertThrowsError(try AppAccessResolver.resolve(mode: .container) { (_: Bool) throws -> MemoryFS in
            throw DeviceFilesError("InstallationLookupFailed", code: -10001)
        }) { error in
            XCTAssertFalse((error as? DeviceFilesError)?.isAccessDenied == true)
        }
    }

    func testSystemTypeUsesMetadataRatherThanBundlePrefix() {
        XCTAssertTrue(DeviceApp(id: "vendor.system", name: "System", applicationType: "System").isSystem)
        XCTAssertTrue(DeviceApp(id: "vendor.system", name: "System", applicationType: "system").isSystem)
        XCTAssertFalse(DeviceApp(id: "com.apple.userapp", name: "User", applicationType: "User").isSystem)
        XCTAssertFalse(DeviceApp(id: "com.apple.unknown", name: "Unknown").isSystem)
    }
    func testSystemFilterHidesDeniedAndPendingButKeepsUnverifiedApps() {
        let app = DeviceApp(id: "test.system", name: "System", applicationType: "System")
        for value in [AppAvailability.restricted, .checking] {
            XCTAssertFalse(AppListFilter.includes(app, availability: value, hideRestrictedApps: true))
            XCTAssertTrue(AppListFilter.includes(app, availability: value, hideRestrictedApps: false))
        }
        for value in [AppAvailability.available, .unknown] {
            XCTAssertTrue(AppListFilter.includes(app, availability: value, hideRestrictedApps: true))
        }
        XCTAssertTrue(AppListFilter.includes(app, availability: nil, hideRestrictedApps: true))
    }
    func testAppFilterUsesPermissionInsteadOfFileSharingOrVendor() {
        let app = DeviceApp(id: "com.apple.userapp", name: "User", applicationType: "User")
        XCTAssertFalse(AppListFilter.includes(app, availability: .restricted, hideRestrictedApps: true))
        XCTAssertTrue(AppListFilter.includes(app, availability: .available, hideRestrictedApps: true))
        XCTAssertFalse(AppListFilter.includes(app, availability: nil, hideRestrictedApps: true, sharingOnly: true))
        XCTAssertTrue(AppListFilter.includes(app, availability: nil, hideRestrictedApps: true, search: "USER"))
        XCTAssertFalse(AppListFilter.includes(app, availability: nil, hideRestrictedApps: true, search: "missing"))
    }
    func testAvailabilityUsesAccessibleContainerWithoutDocumentsRequest() throws {
        var attempts: [Bool] = []
        let value = try AppAvailabilityProbe.evaluate { attempts.append($0) }
        XCTAssertEqual(value, .available)
        XCTAssertEqual(attempts, [true])
    }
    func testAvailabilityKeepsDocumentsOnlySystemApp() throws {
        var attempts: [Bool] = []
        let value = try AppAvailabilityProbe.evaluate { container in
            attempts.append(container)
            if container { throw DeviceFilesError("denied", code: -10001) }
        }
        XCTAssertEqual(value, .available)
        XCTAssertEqual(attempts, [true, false])
    }
    func testAvailabilityRequiresBothModesExplicitlyDenied() throws {
        XCTAssertEqual(try AppAvailabilityProbe.evaluate { _ in throw DeviceFilesError("denied", code: -10001) }, .restricted)
        XCTAssertEqual(try AppAvailabilityProbe.evaluate { _ in throw DeviceFilesError("AFC denied", code: 10) }, .restricted)
        XCTAssertEqual(try AppAvailabilityProbe.evaluate { _ in throw DeviceFilesError("AFC forbidden", code: 15) }, .restricted)
    }
    func testAvailabilityDoesNotHideSystemAppsOnConnectionFailure() throws {
        XCTAssertEqual(try AppAvailabilityProbe.evaluate { _ in throw DeviceFilesError("Disconnected", code: -3) }, .unknown)
        XCTAssertEqual(try AppAvailabilityProbe.evaluate { container in
            throw DeviceFilesError("error", code: container ? -10001 : -3)
        }, .unknown)
    }
    func testAvailabilityPropagatesCancellationWithoutSecondRequest() {
        var attempts = 0
        XCTAssertThrowsError(try AppAvailabilityProbe.evaluate { _ in
            attempts += 1; throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }

    private var temp: URL!
    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["DEVICEFILES_TEST_TEMP"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        temp = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }
    private func source(_ data: Data = Data("new database with more content".utf8)) throws -> URL {
        let file = temp.appendingPathComponent("replacement.db"); try data.write(to: file); return file
    }
    private var backups: URL { temp.appendingPathComponent("backups") }

    private func sourceFolder() throws -> URL {
        let folder = temp.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent("nested/.hidden"))
        return folder
    }
    func testFolderUploadCommitsAllChildrenAndHiddenFiles() throws {
        let fs = MemoryFS(); let folder = try sourceFolder()
        _ = try FileTransfer(fs: fs).uploadItem(folder, to: "/Documents/Folder", replacing: false, backupRoot: backups)
        XCTAssertEqual(fs.files["/Documents/Folder/a.txt"], Data("hello".utf8))
        XCTAssertEqual(fs.files["/Documents/Folder/nested/.hidden"], Data("hidden".utf8))
        XCTAssertTrue(fs.directories.contains("/Documents/Folder/nested"))
        XCTAssertFalse(fs.directories.contains { $0.contains(".devicefiles-folder-") })
        XCTAssertFalse(fs.files.keys.contains { $0.contains(".devicefiles-") })
    }
    func testEmptyFolderUpload() throws {
        let fs = MemoryFS(); let folder = temp.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        _ = try FileTransfer(fs: fs).uploadItem(folder, to: "/Documents/Empty", replacing: false, backupRoot: backups)
        XCTAssertTrue(fs.directories.contains("/Documents/Empty"))
    }
    func testCancelledFolderUploadCleansOnlyItsStagingTree() throws {
        let fs = MemoryFS(); let original = fs.files; let directories = fs.directories
        let token = TransferCancellation()
        XCTAssertThrowsError(try FileTransfer(fs: fs).uploadItem(sourceFolder(), to: "/Documents/Folder", replacing: false,
            backupRoot: backups, cancellation: token, progress: { if $0.message.hasPrefix("上传") { token.cancel() } }))
        XCTAssertEqual(fs.files, original); XCTAssertEqual(fs.directories, directories)
    }
    func testFolderCommitFailureCleansStaging() throws {
        let fs = MemoryFS(); fs.failFolderCommit = true
        let original = fs.files; let directories = fs.directories
        XCTAssertThrowsError(try FileTransfer(fs: fs).uploadItem(sourceFolder(), to: "/Documents/Folder", replacing: false, backupRoot: backups))
        XCTAssertEqual(fs.files, original); XCTAssertEqual(fs.directories, directories)
    }
    func testFolderUploadDoesNotOverwriteExistingFolder() throws {
        let fs = MemoryFS(); fs.directories.insert("/Documents/Folder")
        let original = fs.files; let directories = fs.directories
        XCTAssertThrowsError(try FileTransfer(fs: fs).uploadItem(sourceFolder(), to: "/Documents/Folder", replacing: true, backupRoot: backups))
        XCTAssertEqual(fs.files, original); XCTAssertEqual(fs.directories, directories)
    }
    func testFolderSymlinkPreflightRejectsBeforeCreatingRemoteTree() throws {
        let fs = MemoryFS(); let original = fs.files; let directories = fs.directories
        let folder = try sourceFolder()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder.appendingPathComponent("a.txt"))
        XCTAssertThrowsError(try FileTransfer(fs: fs).uploadItem(folder, to: "/Documents/Folder", replacing: false, backupRoot: backups))
        XCTAssertEqual(fs.files, original); XCTAssertEqual(fs.directories, directories)
        XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testPastePlanHandlesMultipleFilesAndFolder() throws {
        let file = try source(); let folder = try sourceFolder()
        let plan = try PastePlan.make(urls: [file, folder], directory: "/Documents", entries: [])
        XCTAssertEqual(plan.map(\.target), ["/Documents/replacement.db", "/Documents/Folder"])
        XCTAssertFalse(plan[0].isDirectory); XCTAssertTrue(plan[1].isDirectory)
    }
    func testPastePlanDeduplicatesSameURL() throws {
        let file = try source()
        XCTAssertEqual(try PastePlan.make(urls: [file, file], directory: "/Documents", entries: []).count, 1)
    }
    func testPastePlanRejectsDifferentSourcesWithSameName() throws {
        let folder = try sourceFolder()
        let other = temp.appendingPathComponent("a.txt"); try Data().write(to: other)
        XCTAssertThrowsError(try PastePlan.make(urls: [folder.appendingPathComponent("a.txt"), other], directory: "/Documents", entries: []))
    }
    func testPastePlanOnlyAllowsReplacingPlainFiles() throws {
        let file = try source(); let folder = try sourceFolder()
        let entries = [RemoteEntry(path: "/Documents/replacement.db", name: "replacement.db", kind: .file),
                       RemoteEntry(path: "/Documents/Folder", name: "Folder", kind: .directory)]
        let plan = try PastePlan.make(urls: [file, folder], directory: "/Documents", entries: entries)
        XCTAssertTrue(plan[0].canReplace); XCTAssertFalse(plan[1].canReplace)
    }
    func testPastePlanRejectsRemoteURLsAndSymlinks() throws {
        XCTAssertThrowsError(try PastePlan.make(urls: [URL(string: "https://example.com/file")!], directory: "/Documents", entries: []))
        let file = try source(); let link = temp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try PastePlan.make(urls: [link], directory: "/Documents", entries: []))
    }

    func testDeleteIsDirectWithoutReadingOrCreatingBackup() throws {
        let fs = MemoryFS(); var reads = 0
        fs.onReadOpen = { _ in reads += 1 }
        fs.files["/Documents/keep.txt"] = Data("keep".utf8)
        try FileTransfer(fs: fs).deleteFile("/Documents/state.db")
        XCTAssertNil(fs.files["/Documents/state.db"])
        XCTAssertEqual(fs.files["/Documents/keep.txt"], Data("keep".utf8))
        XCTAssertEqual(fs.removalAttempts, ["/Documents/state.db"])
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
        XCTAssertTrue(fs.handles.isEmpty)
    }
    func testDeleteCancelledBeforeStartingKeepsFile() throws {
        let fs = MemoryFS(); let original = fs.files
        let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try FileTransfer(fs: fs).deleteFile("/Documents/state.db", cancellation: token)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fs.files, original); XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testDeleteMetadataDenialNeverRemovesFile() throws {
        let fs = MemoryFS(); let original = fs.files
        fs.deniedStats = ["/Documents/state.db"]
        XCTAssertThrowsError(try FileTransfer(fs: fs).deleteFile("/Documents/state.db"))
        XCTAssertEqual(fs.files, original); XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testDeleteCancellationBeforeCommitKeepsFile() throws {
        let fs = MemoryFS(); let original = fs.files; let token = TransferCancellation()
        XCTAssertThrowsError(try FileTransfer(fs: fs).deleteFile("/Documents/state.db",
            cancellation: token, progress: { if $0.message.hasPrefix("正在删除") { token.cancel() } })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fs.files, original); XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testDeleteLostResponseReportsUncertainResult() throws {
        let fs = MemoryFS(); fs.lostRemoveResponses = ["/Documents/state.db"]
        XCTAssertThrowsError(try FileTransfer(fs: fs).deleteFile("/Documents/state.db")) { error in
            XCTAssertTrue(error.localizedDescription.contains("未能确认"))
            XCTAssertTrue(error.localizedDescription.contains("刷新"))
        }
        XCTAssertNil(fs.files["/Documents/state.db"])
    }
    func testDeleteDeniedReportsFailureWithoutBackup() throws {
        let fs = MemoryFS(); let original = fs.files
        fs.deniedRemovals = ["/Documents/state.db"]
        XCTAssertThrowsError(try FileTransfer(fs: fs).deleteFile("/Documents/state.db")) { error in
            XCTAssertTrue(error.localizedDescription.contains("DeleteDenied"))
            XCTAssertFalse(error.localizedDescription.contains("备份"))
        }
        XCTAssertEqual(fs.files, original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }
    func testDeleteRejectsDirectoriesRootAndSymlinks() throws {
        let fs = MemoryFS(); fs.links = ["/Documents/link"]
        for path in ["/", "/Documents", "/Documents/link", "/Documents/../x", "/Documents/missing"] {
            XCTAssertThrowsError(try FileTransfer(fs: fs).deleteFile(path))
        }
        XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testDeleteEmptyFile() throws {
        let fs = MemoryFS(); fs.files["/Documents/empty"] = Data()
        try FileTransfer(fs: fs).deleteFile("/Documents/empty")
        XCTAssertNil(fs.files["/Documents/empty"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
    }

    func testProtectedChildDoesNotHideLibraryAndTmp() throws {
        let entries = try RemoteDirectoryListing.read("/", names: [".", "..", "Library", "tmp", "protected"]) { path in
            if path == "/protected" { throw DeviceFilesError("Permission denied", code: 10) }
            return RemoteEntry(path: path, name: (path as NSString).lastPathComponent, kind: .directory)
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first { $0.name == "Library" }?.kind, .directory)
        XCTAssertEqual(entries.first { $0.name == "tmp" }?.kind, .directory)
        XCTAssertNotNil(entries.first { $0.name == "protected" }?.accessError)
    }
    func testDirectoryListingStillReportsConnectionFailure() throws {
        XCTAssertThrowsError(try RemoteDirectoryListing.read("/", names: ["Library"]) { _ in
            throw DeviceFilesError("Disconnected", code: 11)
        })
    }
    func testDirectoryListingRejectsInvalidReturnedNames() throws {
        XCTAssertThrowsError(try RemoteDirectoryListing.read("/", names: ["../escape"]) { path in
            RemoteEntry(path: path, name: "escape", kind: .directory)
        })
    }

    func testAutomaticAccessOpensContainerRootAndIncludesPrivateDirectories() throws {
        let fs = MemoryFS(); fs.directories.formUnion(["/Library", "/tmp"])
        var attempts: [Bool] = []
        let result = try AppAccessResolver.resolve(mode: .automatic) { container in attempts.append(container); return fs }
        XCTAssertEqual(attempts, [true]); XCTAssertEqual(result.info.root, "/")
        XCTAssertEqual(result.info.scope, .container); XCTAssertNil(result.info.limitation)
        XCTAssertTrue(try result.filesystem.list("/").contains { $0.name == "Library" })
        XCTAssertTrue(try result.filesystem.list("/").contains { $0.name == "tmp" })
    }
    func testAutomaticFallbackPreservesReasonAndDocumentsScope() throws {
        let fs = MemoryFS(); var attempts: [Bool] = []
        let result = try AppAccessResolver.resolve(mode: .automatic) { container in
            attempts.append(container)
            if container { throw DeviceFilesError("PermissionDenied") }
            return fs
        }
        XCTAssertEqual(attempts, [true, false]); XCTAssertEqual(result.info.root, "/Documents")
        XCTAssertEqual(result.info.scope, .documents)
        XCTAssertTrue(result.info.limitation?.contains("PermissionDenied") == true)
        XCTAssertTrue(result.info.limitation?.contains("Library、tmp") == true)
    }
    func testExplicitContainerFailureNeverSilentlyFallsBack() throws {
        var attempts: [Bool] = []
        XCTAssertThrowsError(try AppAccessResolver.resolve(mode: .container) { (container: Bool) throws -> MemoryFS in
            attempts.append(container); throw DeviceFilesError("PermissionDenied")
        })
        XCTAssertEqual(attempts, [true])
    }
    func testExplicitDocumentsOnlyRequestsDocuments() throws {
        var attempts: [Bool] = []
        let result = try AppAccessResolver.resolve(mode: .documents) { container in attempts.append(container); return MemoryFS() }
        XCTAssertEqual(attempts, [false]); XCTAssertEqual(result.info.scope, .documents)
    }
    func testDeniedRootListingTriggersFreshDocumentsSession() throws {
        let rootFS = MemoryFS(); rootFS.deniedListings = ["/"]
        let documentsFS = MemoryFS(); var attempts: [Bool] = []
        let result = try AppAccessResolver.resolve(mode: .automatic) { container in
            attempts.append(container); return container ? rootFS : documentsFS
        }
        XCTAssertEqual(attempts, [true, false]); XCTAssertTrue(result.filesystem === documentsFS)
        XCTAssertTrue(result.info.limitation?.contains("listing denied") == true)
    }
    func testBothAccessFailuresRemainVisible() throws {
        XCTAssertThrowsError(try AppAccessResolver.resolve(mode: .automatic) { (container: Bool) throws -> MemoryFS in
            throw DeviceFilesError(container ? "ContainerDenied" : "DocumentsDenied")
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("ContainerDenied"))
            XCTAssertTrue(error.localizedDescription.contains("DocumentsDenied"))
        }
    }

    func testReplacementBacksUpVerifiesAndHandlesPartialWrites() throws {
        let fs = MemoryFS(); let local = try source(); let original = fs.files["/Documents/state.db"]!
        let result = try FileTransfer(fs: fs).upload(local, to: "/Documents/state.db", replacing: true, backupRoot: backups)
        XCTAssertEqual(fs.files["/Documents/state.db"], try Data(contentsOf: local))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backup)), original)
        XCTAssertEqual(fs.files.count, 1); XCTAssertTrue(fs.handles.isEmpty)
        let metadata = result.backup!.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("metadata.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }
    func testCommitFailureRestoresOriginal() throws {
        let fs = MemoryFS(); fs.failCommit = true; let original = fs.files
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: true, backupRoot: backups))
        XCTAssertEqual(fs.files, original); XCTAssertTrue(fs.handles.isEmpty)
    }
    func testRollbackFailureReportsRecoverablePathsAndPreservesOriginalCopy() throws {
        let fs = MemoryFS(); fs.failCommit = true; fs.failRollback = true
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: true, backupRoot: backups)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".devicefiles-original-"))
            XCTAssertTrue(error.localizedDescription.contains("本地备份"))
        }
        XCTAssertEqual(fs.files.count, 1)
        XCTAssertTrue(fs.files.keys.first!.contains(".devicefiles-original-"))
    }
    func testCorruptionRejectsReplacement() throws {
        let fs = MemoryFS(); fs.corruptStagingRead = true; let original = fs.files
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: true, backupRoot: backups))
        XCTAssertEqual(fs.files, original)
    }
    func testCancellationDuringUploadKeepsOriginalAndRemovesStaging() throws {
        let fs = MemoryFS(); let original = fs.files; let token = TransferCancellation()
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: true, backupRoot: backups,
                                                            cancellation: token, progress: { if $0.message.hasPrefix("上传") { token.cancel() } }))
        XCTAssertEqual(fs.files, original); XCTAssertTrue(fs.handles.isEmpty)
    }
    func testOriginalChangedAfterBackupIsNotOverwritten() throws {
        let fs = MemoryFS(); var count = 0
        fs.onReadOpen = { path in
            if path == "/Documents/state.db" {
                count += 1
                if count == 2 { fs.files[path] = Data("changed data".utf8) }
            }
        }
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: true, backupRoot: backups))
        XCTAssertEqual(fs.files["/Documents/state.db"], Data("changed data".utf8)); XCTAssertEqual(fs.files.count, 1)
    }
    func testUploadDoesNotOverwriteExistingFile() throws {
        let fs = MemoryFS(); let original = fs.files
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: false, backupRoot: backups))
        XCTAssertEqual(fs.files, original)
    }
    func testNewAndEmptyFiles() throws {
        let fs = MemoryFS()
        _ = try FileTransfer(fs: fs).upload(source(Data()), to: "/Documents/empty", replacing: false, backupRoot: backups)
        XCTAssertEqual(fs.files["/Documents/empty"], Data())
    }
    func testZeroByteWriteDoesNotLoopOrOverwrite() throws {
        let fs = MemoryFS(); fs.maximumWrite = 0; let original = fs.files
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/state.db", replacing: true, backupRoot: backups))
        XCTAssertEqual(fs.files, original)
    }
    func testDownloadReplacesLocalFileOnlyAfterCompleteTransfer() throws {
        let fs = MemoryFS(); let out = temp.appendingPathComponent("download.db")
        try Data("local original".utf8).write(to: out)
        try FileTransfer(fs: fs).download("/Documents/state.db", to: out)
        XCTAssertEqual(try Data(contentsOf: out), fs.files["/Documents/state.db"])
    }
    func testCancelledDownloadKeepsExistingLocalFile() throws {
        let fs = MemoryFS(); let out = temp.appendingPathComponent("download.db"); let token = TransferCancellation()
        let local = Data("local original".utf8); try local.write(to: out)
        XCTAssertThrowsError(try FileTransfer(fs: fs).download("/Documents/state.db", to: out, cancellation: token, progress: { _ in token.cancel() }))
        XCTAssertEqual(try Data(contentsOf: out), local)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), ["download.db"])
    }
    func testRecursiveDownload() throws {
        let fs = MemoryFS(); fs.directories.insert("/Documents/sub"); fs.files["/Documents/sub/a.txt"] = Data("hello".utf8)
        let out = temp.appendingPathComponent("Documents")
        try FileTransfer(fs: fs).download("/Documents", to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("sub/a.txt")), Data("hello".utf8))
    }
    func testTraversalAndSymlinkAreRejected() throws {
        let fs = MemoryFS(); fs.links.insert("/Documents/link")
        XCTAssertThrowsError(try RemotePath.child("../x", of: "/Documents"))
        XCTAssertThrowsError(try RemotePath.validate("/Documents/../secret"))
        XCTAssertThrowsError(try RemotePath.validate("/Documents\0/secret"))
        XCTAssertThrowsError(try FileTransfer(fs: fs).download("/Documents/link", to: temp.appendingPathComponent("link")))
        XCTAssertThrowsError(try FileTransfer(fs: fs).upload(source(), to: "/Documents/link/file", replacing: false, backupRoot: backups))
    }
}
