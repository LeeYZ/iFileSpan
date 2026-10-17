import Foundation
import DeviceBridge

func bridgeError() -> DeviceFilesError { DeviceFilesError(String(cString: df_error()), code: Int(df_error_code())) }
func check(_ result: Int32) throws {
    if result != 0 { throw DeviceFilesError(String(cString: df_error()), code: Int(result)) }
}
private func strings(_ pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
    guard let pointer else { return [] }
    var result: [String] = []; var index = 0
    while let value = pointer[index] { result.append(String(cString: value)); index += 1 }
    return result
}
func plist(_ value: UnsafeMutablePointer<CChar>?) throws -> Any {
    guard let value else { throw bridgeError() }
    defer { df_free(value) }
    return try PropertyListSerialization.propertyList(from: Data(String(cString: value).utf8), format: nil)
}

final class AFCFileSystem: RemoteFileSystem {
    let session: OpaquePointer
    init(udid: String, bundle: String, container: Bool) throws {
        guard let session = df_connect(udid, bundle, container ? 1 : 0) else { throw bridgeError() }
        self.session = session
    }
    init(session: OpaquePointer) { self.session = session }
    deinit { df_disconnect(session) }
    func stat(_ path: String) throws -> RemoteEntry? {
        try RemotePath.validate(path)
        var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        let result = df_stat(session, path, &pointer)
        defer { df_dictionary_free(pointer) }
        if result == 8 { return nil }
        try check(result)
        let values = strings(pointer)
        guard values.count.isMultiple(of: 2) else { throw DeviceFilesError("设备返回的文件属性格式错误。") }
        var attrs: [String: String] = [:]
        for i in stride(from: 0, to: values.count, by: 2) { attrs[values[i]] = values[i + 1] }
        let kind: RemoteEntry.Kind
        switch attrs["st_ifmt"] {
        case "S_IFDIR": kind = .directory
        case "S_IFREG": kind = .file
        case "S_IFLNK": kind = .symbolicLink
        default: kind = .other
        }
        return RemoteEntry(path: path, name: (path as NSString).lastPathComponent, kind: kind,
                           size: UInt64(attrs["st_size"] ?? "") ?? 0,
                           modified: Double(attrs["st_mtime"] ?? "").map { Date(timeIntervalSince1970: $0 / 1_000_000_000) })
    }
    func list(_ path: String) throws -> [RemoteEntry] {
        var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        try check(df_list(session, path, &pointer))
        defer { df_dictionary_free(pointer) }
        return try RemoteDirectoryListing.read(path, names: strings(pointer), stat: stat)
    }
    func open(_ path: String, writing: Bool) throws -> UInt64 {
        var handle: UInt64 = 0; try check(df_open(session, path, writing ? 1 : 0, &handle)); return handle
    }
    func read(_ handle: UInt64, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count); var actual: UInt32 = 0
        try bytes.withUnsafeMutableBytes { p in
            try check(df_read(session, handle, p.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32(count), &actual))
        }
        guard actual <= count else { throw DeviceFilesError("设备返回的数据长度错误。") }
        return Data(bytes.prefix(Int(actual)))
    }
    func write(_ handle: UInt64, data: Data) throws -> Int {
        var actual: UInt32 = 0
        try data.withUnsafeBytes { p in
            try check(df_write(session, handle, p.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32(data.count), &actual))
        }
        return Int(actual)
    }
    func close(_ handle: UInt64) throws { try check(df_close(session, handle)) }
    func move(_ from: String, to: String) throws { try check(df_move(session, from, to)) }
    func remove(_ path: String) throws { try check(df_remove(session, path)) }
    func mkdir(_ path: String) throws { try check(df_mkdir(session, path)) }
}

// File operations share this actor; read-only sidebar requests use a separate actor/connection.
public actor DeviceService {
    private var filesystem: AFCFileSystem?
    private var identity = ""
    private var ready = false
    public init() {}
    public func detect() throws -> [Device] {
        filesystem = nil
        if df_load(Bundle.main.privateFrameworksPath ?? "") != 0 { throw DeviceLibraryError(String(cString: df_error())) }
        ready = true
        var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?; var count: Int32 = 0
        try check(df_devices(&pointer, &count))
        defer { df_devices_free(pointer) }
        return strings(pointer).map { udid in
            do {
                guard let info = try plist(df_device_info(udid)) as? [String: Any] else { throw DeviceFilesError("设备信息格式错误") }
                return Device(id: udid, name: info["DeviceName"] as? String ?? "iPhone / iPad",
                              version: info["ProductVersion"] as? String ?? "", model: info["ProductType"] as? String ?? "", connectionError: nil)
            } catch {
                return Device(id: udid, name: "待解锁或信任的设备", version: "", model: "", connectionError: error.localizedDescription)
            }
        }
    }
    public func apps(_ udid: String) throws -> [DeviceApp] {
        guard ready else { throw DeviceFilesError("请先检测设备。") }
        filesystem = nil
        guard let values = try plist(df_apps(udid)) as? [[String: Any]] else { throw DeviceFilesError("App 列表格式错误。") }
        return values.compactMap { info in
            guard let id = info["CFBundleIdentifier"] as? String else { return nil }
            return DeviceApp(id: id, name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? id,
                             version: info["CFBundleShortVersionString"] as? String ?? "", fileSharing: info["UIFileSharingEnabled"] as? Bool ?? false,
                             applicationType: info["ApplicationType"] as? String ?? "")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func appIcon(udid: String, bundle: String) throws -> Data {
        try Task.checkCancellation()
        guard ready else { throw DeviceFilesError("请先检测设备。") }
        var pointer: UnsafeMutablePointer<CChar>?
        var size: UInt64 = 0
        try check(df_app_icon(udid, bundle, &pointer, &size))
        defer { df_free(pointer) }
        guard let pointer, size > 0, size <= 8 * 1024 * 1024 else { throw DeviceFilesError("图标数据无效。") }
        return Data(bytes: pointer, count: Int(size))
    }
    public func appAvailability(udid: String, bundle: String) throws -> AppAvailability {
        try Task.checkCancellation()
        guard ready else { throw DeviceFilesError("请先检测设备。") }
        // Independent, read-only sessions. Never replace the user's active filesystem.
        let result = try AppAvailabilityProbe.evaluate { container in
            try Task.checkCancellation()
            let fs = try AFCFileSystem(udid: udid, bundle: bundle, container: container)
            let root = container ? "/" : "/Documents"
            try FileTransfer(fs: fs).validateDirectory(root)
            var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            defer { df_dictionary_free(names) }
            try check(df_list(fs.session, root, &names))
        }
        // An app-specific unknown error should not prevent checking the other apps.
        // Pause the batch only if a fresh device handshake/info read also fails.
        if result == .unknown { _ = try plist(df_device_info(udid)) }
        return result
    }
    public func connect(udid: String, bundle: String, container: Bool) throws -> String {
        try connect(udid: udid, bundle: bundle, mode: container ? .container : .documents).root
    }
    public func connect(udid: String, bundle: String, mode: AppAccessMode) throws -> AppConnectionInfo {
        try open(udid: udid, bundle: bundle, mode: mode).info
    }
    public func open(udid: String, bundle: String, mode: AppAccessMode) throws -> (info: AppConnectionInfo, entries: [RemoteEntry]) {
        filesystem = nil
        let info: AppConnectionInfo
        let entries: [RemoteEntry]
        if bundle.isEmpty {
            let fs = try AFCFileSystem(udid: udid, bundle: bundle, container: false)
            try FileTransfer(fs: fs).validateDirectory("/")
            entries = try fs.list("/")
            filesystem = fs; info = AppConnectionInfo(root: "/", scope: .media)
        } else {
            let result = try AppAccessResolver.resolve(mode: mode) { container in
                try AFCFileSystem(udid: udid, bundle: bundle, container: container)
            }
            filesystem = result.filesystem; info = result.info; entries = result.entries
        }
        identity = "\(udid)/\(bundle.isEmpty ? "Media" : bundle)"
        return (info, entries)
    }
    public func disconnect() { filesystem = nil }
    private func connected() throws -> AFCFileSystem {
        guard let filesystem else { throw DeviceFilesError("请先选择设备和目录。") }; return filesystem
    }
    public func list(_ path: String) throws -> [RemoteEntry] {
        let fs = try connected(); try FileTransfer(fs: fs).validateDirectory(path); return try fs.list(path)
    }
    public func download(_ path: String, to destination: URL, cancellation: TransferCancellation,
                         progress: @escaping @Sendable (TransferProgress) -> Void) throws {
        try FileTransfer(fs: connected()).download(path, to: destination, cancellation: cancellation, progress: progress)
    }
    public func upload(_ local: URL, to path: String, replacing: Bool, backupRoot: URL,
                       cancellation: TransferCancellation, progress: @escaping @Sendable (TransferProgress) -> Void) throws -> UploadResult {
        try FileTransfer(fs: connected()).upload(local, to: path, replacing: replacing, backupRoot: backupRoot,
                                               identity: identity, cancellation: cancellation, progress: progress)
    }
    public func deleteFile(_ path: String, cancellation: TransferCancellation,
                           progress: @escaping @Sendable (TransferProgress) -> Void) throws {
        try FileTransfer(fs: connected()).deleteFile(path, cancellation: cancellation, progress: progress)
    }
    public func uploadItem(_ local: URL, to path: String, replacing: Bool, backupRoot: URL,
                           cancellation: TransferCancellation, progress: @escaping @Sendable (TransferProgress) -> Void) throws -> UploadResult {
        try FileTransfer(fs: connected()).uploadItem(local, to: path, replacing: replacing, backupRoot: backupRoot,
                                                   identity: identity, cancellation: cancellation, progress: progress)
    }
    public func mkdir(_ name: String, in path: String) throws {
        let fs = try connected(); try FileTransfer(fs: fs).validateDirectory(path)
        let target = try RemotePath.child(name, of: path)
        guard try fs.stat(target) == nil else { throw DeviceFilesError("同名项目已存在。") }
        try fs.mkdir(target)
    }
}
