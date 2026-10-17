import Foundation

public struct Device: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let model: String
    public let connectionError: String?
}

public struct DeviceApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let fileSharing: Bool
    public let applicationType: String
    // Use installation_proxy metadata, never a bundle identifier prefix.
    public var isSystem: Bool { applicationType.caseInsensitiveCompare("System") == .orderedSame }
    public init(id: String, name: String, version: String = "", fileSharing: Bool = false, applicationType: String = "") {
        self.id = id; self.name = name; self.version = version
        self.fileSharing = fileSharing; self.applicationType = applicationType
    }
}

public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let kind: Kind
    public let size: UInt64
    public let modified: Date?
    public let accessError: String?
    public var id: String { path }
    public enum Kind: String, Sendable { case file, directory, symbolicLink, other }
    public init(path: String, name: String, kind: Kind, size: UInt64 = 0, modified: Date? = nil, accessError: String? = nil) {
        self.path = path; self.name = name; self.kind = kind; self.size = size; self.modified = modified; self.accessError = accessError
    }
}

public struct DeviceFilesError: LocalizedError, Sendable {
    public let message: String
    public let code: Int?
    public var errorDescription: String? { message }
    public var isAccessDenied: Bool { code == -10001 || code == 10 || code == 15 }
    public init(_ message: String, code: Int? = nil) { self.message = message; self.code = code }
}

public enum RemoteDirectoryListing {
    public static func read(_ path: String, names: [String], stat: (String) throws -> RemoteEntry?) throws -> [RemoteEntry] {
        try RemotePath.validate(path)
        return try names.filter { $0 != "." && $0 != ".." }.compactMap { name -> RemoteEntry? in
            let child = try RemotePath.child(name, of: path)
            do { return try stat(child) }
            catch let error as DeviceFilesError where error.code == 10 || error.code == 15 {
                // One protected child must not hide readable sibling directories.
                return RemoteEntry(path: child, name: name, kind: .other, accessError: error.localizedDescription)
            }
        }.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public struct DeviceLibraryError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum RemotePath {
    public static func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              path == "/" || !path.hasSuffix("/"),
              !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw DeviceFilesError("无效的设备路径。")
        }
    }
    public static func child(_ name: String, of parent: String) throws -> String {
        try validate(parent)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw DeviceFilesError("文件名不能包含路径分隔符或上级目录。")
        }
        return parent == "/" ? "/" + name : parent + "/" + name
    }
    public static func parent(_ path: String) -> String {
        let value = (path as NSString).deletingLastPathComponent
        return value.isEmpty ? "/" : value
    }
}

public protocol RemoteFileSystem: AnyObject {
    func stat(_ path: String) throws -> RemoteEntry?
    func list(_ path: String) throws -> [RemoteEntry]
    func open(_ path: String, writing: Bool) throws -> UInt64
    func read(_ handle: UInt64, count: Int) throws -> Data
    func write(_ handle: UInt64, data: Data) throws -> Int
    func close(_ handle: UInt64) throws
    func move(_ from: String, to: String) throws
    func remove(_ path: String) throws
    func mkdir(_ path: String) throws
}

public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

public struct TransferProgress: Sendable {
    public let message: String
    public let completed: UInt64
    public let total: UInt64
    public init(_ message: String, completed: UInt64 = 0, total: UInt64 = 0) {
        self.message = message; self.completed = completed; self.total = total
    }
}

public struct UploadResult: Sendable {
    public let backup: URL?
    public let warning: String?
}

