import Foundation
import DeviceBridge

// Each worker owns separate device connections. The manager serializes cache access only.
public actor DeviceSidebarService {
    private actor Connection {
        private final class Browser {
            let pointer: OpaquePointer
            init(udid: String) throws {
                guard let value = df_browser_new(udid) else { throw bridgeError() }
                pointer = value
            }
            deinit { df_browser_free(pointer) }
        }
        private var current: Browser?
        private var deviceID = ""
        private func browser(_ udid: String) throws -> Browser {
            try Task.checkCancellation()
            if deviceID != udid || current == nil {
                current = nil; current = try Browser(udid: udid); deviceID = udid
            }
            return current!
        }
        func availability(device: String, app: DeviceApp) throws -> AppAvailability {
            let connection = try browser(device)
            let value = try AppAvailabilityProbe.evaluate { container in
                try Task.checkCancellation()
                guard let session = df_browser_connect(connection.pointer, app.id, container ? 1 : 0) else { throw bridgeError() }
                let fs = AFCFileSystem(session: session)
                let root = container ? "/" : "/Documents"
                try FileTransfer(fs: fs).validateDirectory(root)
                var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                defer { df_dictionary_free(names) }
                try check(df_list(session, root, &names))
            }
            if value == .unknown { _ = try plist(df_device_info(device)) }
            return value
        }
        func icon(device: String, app: DeviceApp) throws -> Data {
            let connection = try browser(device)
            var pointer: UnsafeMutablePointer<CChar>?
            var size: UInt64 = 0
            try check(df_browser_icon(connection.pointer, app.id, &pointer, &size))
            defer { df_free(pointer) }
            guard let pointer, size > 0, size <= 8 * 1024 * 1024 else { throw DeviceFilesError("图标数据无效。") }
            let data = Data(bytes: pointer, count: Int(size))
            guard SidebarCache.isPNG(data) else { throw DeviceFilesError("图标数据无效。") }
            return data
        }
    }
    public static let parallelChecks = 3
    private let connections = (0..<parallelChecks).map { _ in Connection() }
    private let iconConnection = Connection()
    private var loads = [Int](repeating: 0, count: parallelChecks)
    private var deviceID = ""
    private var generation = UUID()
    private var cache: SidebarCache?
    private let cacheRoot: URL
    public init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceFiles/Sidebar", isDirectory: true)
    }
    public func prepare(device: Device, apps: [DeviceApp], refreshPermissions: Bool = false) throws -> [String: AppAvailability] {
        try Task.checkCancellation()
        cache?.flush()
        // The foreground service has already initialized the dynamic library before this call.
        guard df_load(Bundle.main.privateFrameworksPath ?? "") == 0 else { throw bridgeError() }
        deviceID = device.id; generation = UUID()
        cache = SidebarCache(root: cacheRoot, device: device.id, systemVersion: device.version)
        if refreshPermissions { cache?.invalidatePermissions(); return [:] }
        return Dictionary(uniqueKeysWithValues: apps.compactMap { app in cache?.availability(app).map { (app.id, $0) } })
    }
    private func validate(_ udid: String) throws {
        try Task.checkCancellation()
        guard udid == deviceID else { throw CancellationError() }
    }
    public func availability(device: String, app: DeviceApp) async throws -> AppAvailability {
        try validate(device)
        let token = generation
        let index = loads.indices.min { loads[$0] < loads[$1] }!
        loads[index] += 1
        defer { loads[index] -= 1 }
        let value = try await connections[index].availability(device: device, app: app)
        try validate(device)
        guard generation == token else { throw CancellationError() }
        cache?.record(value, app: app)
        return value
    }
    public func icon(device: String, app: DeviceApp) async throws -> Data {
        try validate(device)
        if let stored = cache?.icon(app) { return stored }
        let token = generation
        let data = try await iconConnection.icon(device: device, app: app)
        try validate(device)
        guard generation == token else { throw CancellationError() }
        cache?.storeIcon(data, app: app)
        return data
    }
    public func record(device: String, app: DeviceApp, value: AppAvailability) {
        guard device == deviceID else { return }
        cache?.record(value, app: app); cache?.flush()
    }
    public func flush(device: String) { if device == deviceID { cache?.flush() } }
}
