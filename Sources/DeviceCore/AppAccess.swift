import Foundation

public enum AppAccessMode: String, CaseIterable, Sendable {
    case automatic, container, documents
    public var title: String {
        switch self {
        case .automatic: "自动（优先容器根目录）"
        case .container: "容器根目录（含 Library、tmp）"
        case .documents: "仅 Documents"
        }
    }
}

public struct AppConnectionInfo: Sendable {
    public enum Scope: Sendable { case container, documents, media }
    public let root: String
    public let scope: Scope
    public let limitation: String?
    public init(root: String, scope: Scope, limitation: String? = nil) {
        self.root = root; self.scope = scope; self.limitation = limitation
    }
    public var title: String {
        switch scope {
        case .container: "App 容器根目录 · 以设备实际开放的目录为准"
        case .documents: "Documents · 未获得 Library、tmp 的访问权限"
        case .media: "设备共享媒体目录"
        }
    }
}

public enum AppAccessResolver {
    // Open a fresh AFC session for each attempt; a denied House Arrest session is never reused.
    public static func resolve<FS: RemoteFileSystem>(mode: AppAccessMode,
        open: (Bool) throws -> FS) throws -> (filesystem: FS, info: AppConnectionInfo, entries: [RemoteEntry]) {
        var entries: [RemoteEntry] = []
        func attempt(container: Bool) throws -> FS {
            let fs = try open(container)
            let root = container ? "/" : "/Documents"
            try FileTransfer(fs: fs).validateDirectory(root)
            entries = try fs.list(root)
            return fs
        }
        if mode == .documents {
            return (try attempt(container: false), AppConnectionInfo(root: "/Documents", scope: .documents), entries)
        }
        do {
            return (try attempt(container: true), AppConnectionInfo(root: "/", scope: .container), entries)
        } catch {
            let containerError = error.localizedDescription
            let containerDenied = (error as? DeviceFilesError)?.isAccessDenied == true
            if mode == .container {
                throw DeviceFilesError("设备未开放此 App 的容器根目录，无法读取 Library、tmp。\n\(containerError)")
            }
            do {
                return (try attempt(container: false), AppConnectionInfo(root: "/Documents", scope: .documents,
                    limitation: "容器根目录访问失败，当前仅能访问 Documents。Library、tmp 尚未获得权限。\n原因：\(containerError)"), entries)
            } catch {
                let bothDenied = containerDenied && (error as? DeviceFilesError)?.isAccessDenied == true
                throw DeviceFilesError("无法打开此 App 的目录。\n容器根目录：\(containerError)\nDocuments：\(error.localizedDescription)\n显示在应用列表中不代表 iOS 允许读取其私有沙盒。", code: bothDenied ? -10001 : nil)
            }
        }
    }
}
