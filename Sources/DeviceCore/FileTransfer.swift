import Foundation
import CryptoKit
import Darwin

public struct FileTransfer {
    public let fs: any RemoteFileSystem
    private let chunk = 256 * 1024
    public init(fs: any RemoteFileSystem) { self.fs = fs }

    public func validateDirectory(_ path: String) throws {
        try RemotePath.validate(path)
        var current = "/"
        guard try fs.stat(current)?.kind == .directory else { throw DeviceFilesError("设备根目录不可用。") }
        for name in path.split(separator: "/") {
            current = try RemotePath.child(String(name), of: current)
            guard try fs.stat(current)?.kind == .directory else {
                throw DeviceFilesError("目录不可用，或路径包含符号链接：\(current)")
            }
        }
    }

    private func regular(_ path: String) throws -> RemoteEntry {
        try RemotePath.validate(path)
        try validateDirectory(RemotePath.parent(path))
        guard let value = try fs.stat(path), value.kind == .file else {
            throw DeviceFilesError("只允许操作普通文件，不支持符号链接或特殊文件：\(path)")
        }
        return value
    }

    private func stream(_ path: String, cancellation: TransferCancellation,
                        receive: (Data, UInt64, UInt64) throws -> Void) throws -> (String, UInt64) {
        let before = try regular(path)
        let handle = try fs.open(path, writing: false)
        var closed = false
        defer { if !closed { try? fs.close(handle) } }
        var hasher = SHA256(); var count: UInt64 = 0
        while true {
            try cancellation.check()
            let data = try fs.read(handle, count: chunk)
            if data.isEmpty { break }
            count += UInt64(data.count); hasher.update(data: data)
            try receive(data, count, before.size)
        }
        try fs.close(handle); closed = true
        let after = try regular(path)
        guard count == before.size, after.size == before.size, after.modified == before.modified else {
            throw DeviceFilesError("文件在读取时发生变化，请关闭设备上的 App 后重试：\(path)")
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    private func createLocalFile(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw DeviceFilesError("无法创建本地文件：\(url.path)（\(String(cString: strerror(errno)))）")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func copyFile(_ path: String, to url: URL, cancellation: TransferCancellation,
                          progress: @Sendable (TransferProgress) -> Void) throws -> String {
        let output = try createLocalFile(url)
        do {
            let (hash, _) = try stream(path, cancellation: cancellation) { data, bytes, total in
                try output.write(contentsOf: data)
                progress(TransferProgress("下载 \((path as NSString).lastPathComponent)", completed: bytes, total: total))
            }
            try output.synchronize(); try output.close()
            return hash
        } catch {
            try? output.close(); try? FileManager.default.removeItem(at: url); throw error
        }
    }

    public func download(_ path: String, to destination: URL, cancellation: TransferCancellation = .init(),
                         progress: @Sendable (TransferProgress) -> Void = { _ in }) throws {
        try RemotePath.validate(path); try validateDirectory(RemotePath.parent(path))
        guard let entry = try fs.stat(path), entry.kind == .file || entry.kind == .directory else {
            throw DeviceFilesError("无法导出符号链接或特殊文件。")
        }
        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".devicefiles-download-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        if entry.kind == .directory {
            guard !fm.fileExists(atPath: destination.path) else { throw DeviceFilesError("导出文件夹时请选择一个尚不存在的名称。") }
            try copyDirectory(path, to: temporary, depth: 0, cancellation: cancellation, progress: progress)
        } else {
            _ = try copyFile(path, to: temporary, cancellation: cancellation, progress: progress)
        }
        try cancellation.check()
        // Both paths share a parent: POSIX rename commits a completed file atomically.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw DeviceFilesError("保存下载结果失败：\(String(cString: strerror(errno)))")
        }
    }

    private func copyDirectory(_ path: String, to url: URL, depth: Int, cancellation: TransferCancellation,
                               progress: @Sendable (TransferProgress) -> Void) throws {
        guard depth < 128 else { throw DeviceFilesError("目录层级过深，已停止导出。") }
        try cancellation.check(); try validateDirectory(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for entry in try fs.list(path) {
            try cancellation.check()
            let expectedPath = try RemotePath.child(entry.name, of: path)
            guard expectedPath == entry.path else { throw DeviceFilesError("设备返回了无效的目录项。") }
            let local = url.appendingPathComponent(entry.name)
            // A case-insensitive Mac volume may not represent all device file names.
            guard !FileManager.default.fileExists(atPath: local.path) else {
                throw DeviceFilesError("本地磁盘存在名称冲突（可能仅大小写不同）：\(entry.name)")
            }
            if entry.kind == .directory {
                try copyDirectory(entry.path, to: local, depth: depth + 1, cancellation: cancellation, progress: progress)
            } else if entry.kind == .file {
                _ = try copyFile(entry.path, to: local, cancellation: cancellation, progress: progress)
            } else { throw DeviceFilesError("目录包含符号链接或特殊文件，已停止导出：\(entry.path)") }
        }
    }

    private func backupFile(_ path: String, backupRoot: URL, identity: String, operation: String,
                            cancellation: TransferCancellation,
                            progress: @Sendable (TransferProgress) -> Void) throws -> (url: URL, hash: String) {
        let folder = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = folder.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        let url = payload.appendingPathComponent((path as NSString).lastPathComponent)
        let hash = try copyFile(path, to: url, cancellation: cancellation, progress: progress)
        let metadata: [String: String] = ["deviceAndApp": identity, "remotePath": path,
            "createdAt": ISO8601DateFormatter().string(from: Date()), "sha256": hash, "operation": operation]
        let output = try createLocalFile(folder.appendingPathComponent("metadata.json"))
        defer { try? output.close() }
        try output.write(contentsOf: JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]))
        try output.synchronize(); try output.close()
        return (url, hash)
    }

    public func deleteFile(_ path: String, cancellation: TransferCancellation = .init(),
                           progress: @Sendable (TransferProgress) -> Void = { _ in }) throws {
        _ = try regular(path)
        try cancellation.check()
        progress(TransferProgress("正在删除文件，请勿断开设备…"))
        try cancellation.check()
        do { try fs.remove(path) }
        catch {
            // A disconnect may occur after unlink succeeded; do not promise the file still exists.
            throw DeviceFilesError("未能确认设备文件的删除结果，请刷新目录检查。\n\(error.localizedDescription)")
        }
    }

    public func upload(_ local: URL, to path: String, replacing: Bool, backupRoot: URL,
                       identity: String = "device/app", cancellation: TransferCancellation = .init(),
                       progress: @Sendable (TransferProgress) -> Void = { _ in }) throws -> UploadResult {
        try RemotePath.validate(path); try validateDirectory(RemotePath.parent(path))
        let attributes = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw DeviceFilesError("请选择一个普通的本地文件。") }
        let initial = try fs.stat(path)
        if replacing {
            guard initial?.kind == .file else { throw DeviceFilesError("原文件已不存在或不是普通文件，请刷新列表。") }
        } else if initial != nil { throw DeviceFilesError("同名项目已存在，请使用“替换”功能。") }
        let parent = RemotePath.parent(path)
        let token = UUID().uuidString
        let staging = try RemotePath.child(".devicefiles-upload-" + token, of: parent)
        let rollback = try RemotePath.child(".devicefiles-original-" + token, of: parent)
        var committed = false
        defer { if !committed { try? fs.remove(staging) } }
        var backup: URL?; var originalHash: String?
        if replacing {
            progress(TransferProgress("备份原文件…"))
            let result = try backupFile(path, backupRoot: backupRoot, identity: identity, operation: "replace",
                                        cancellation: cancellation, progress: progress)
            originalHash = result.hash; backup = result.url
        }
        try cancellation.check()
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let output = try fs.open(staging, writing: true)
        var outputClosed = false
        defer { if !outputClosed { try? fs.close(output) } }
        var hasher = SHA256(); var total: UInt64 = 0
        while true {
            try cancellation.check()
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            var offset = 0
            while offset < data.count {
                try cancellation.check()
                let written = try fs.write(output, data: Data(data.dropFirst(offset)))
                guard written > 0, written <= data.count - offset else { throw DeviceFilesError("设备写入没有进展，已终止上传。") }
                offset += written
            }
            total += UInt64(data.count)
            progress(TransferProgress("上传 \(local.lastPathComponent)", completed: total, total: UInt64(attributes.fileSize ?? 0)))
        }
        try fs.close(output); outputClosed = true
        let localHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        progress(TransferProgress("回读并校验上传内容…"))
        let (remoteHash, remoteCount) = try stream(staging, cancellation: cancellation) { _, count, size in
            progress(TransferProgress("校验上传内容…", completed: count, total: size))
        }
        guard remoteHash == localHash, remoteCount == total else { throw DeviceFilesError("上传校验失败，原文件未被替换。") }
        if replacing {
            progress(TransferProgress("确认原文件未变化…"))
            let (currentHash, _) = try stream(path, cancellation: cancellation) { _, _, _ in }
            guard currentHash == originalHash else { throw DeviceFilesError("设备上的原文件已变化，已取消替换。请关闭 App 并重新操作。") }
        } else {
            guard try fs.stat(path) == nil else { throw DeviceFilesError("设备上出现同名文件，已取消上传。") }
        }
        try cancellation.check()
        progress(TransferProgress("提交文件，请勿断开设备…"))
        // No cancellation between these renames: complete or roll back the transaction.
        if replacing { try fs.move(path, to: rollback) }
        do { try fs.move(staging, to: path) }
        catch {
            let commitError = error
            if replacing {
                do { try fs.move(rollback, to: path) }
                catch {
                    throw DeviceFilesError("提交失败且设备回滚失败。设备原文件位于 \(rollback)。本地备份：\(backup?.path ?? "")。请重新连接设备后恢复。提交错误：\(commitError.localizedDescription)；回滚错误：\(error.localizedDescription)")
                }
            }
            throw commitError
        }
        committed = true
        var warning: String?
        if replacing {
            do { try fs.remove(rollback) }
            catch { warning = "文件已替换，但设备上的旧文件副本未能清理：\(rollback)" }
        }
        return UploadResult(backup: backup, warning: warning)
    }

    public func uploadItem(_ local: URL, to path: String, replacing: Bool, backupRoot: URL,
                           identity: String = "device/app", cancellation: TransferCancellation = .init(),
                           progress: @Sendable (TransferProgress) -> Void = { _ in }) throws -> UploadResult {
        let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw DeviceFilesError("不支持上传符号链接。") }
        if values.isDirectory != true {
            return try upload(local, to: path, replacing: replacing, backupRoot: backupRoot, identity: identity,
                              cancellation: cancellation, progress: progress)
        }
        try RemotePath.validate(path); try validateDirectory(RemotePath.parent(path))
        guard !replacing, try fs.stat(path) == nil else {
            throw DeviceFilesError("同名文件夹或其他项目已存在，不能直接覆盖：\(path)")
        }
        struct Item { let source: URL; let relative: [String]; let directory: Bool }
        var items: [Item] = []
        func collect(_ folder: URL, relative: [String]) throws {
            guard relative.count < 128 else { throw DeviceFilesError("文件夹层级过深。") }
            try cancellation.check()
            for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let attributes = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isSymbolicLink != true, attributes.isDirectory == true || attributes.isRegularFile == true else {
                    throw DeviceFilesError("文件夹包含符号链接或特殊文件：\(child.lastPathComponent)")
                }
                _ = try RemotePath.child(child.lastPathComponent, of: "/")
                let components = relative + [child.lastPathComponent]
                items.append(Item(source: child, relative: components, directory: attributes.isDirectory == true))
                if attributes.isDirectory == true { try collect(child, relative: components) }
            }
        }
        try collect(local, relative: [])
        let staging = try RemotePath.child(".devicefiles-folder-" + UUID().uuidString, of: RemotePath.parent(path))
        try fs.mkdir(staging)
        var created = [staging]; var committed = false
        defer { if !committed { for item in created.reversed() { try? fs.remove(item) } } }
        for item in items {
            try cancellation.check()
            let target = try item.relative.reduce(staging) { try RemotePath.child($1, of: $0) }
            if item.directory { try fs.mkdir(target) }
            else {
                _ = try upload(item.source, to: target, replacing: false, backupRoot: backupRoot, identity: identity,
                               cancellation: cancellation, progress: progress)
            }
            created.append(target)
        }
        guard try fs.stat(path) == nil else { throw DeviceFilesError("上传期间出现同名项目，已取消文件夹提交。") }
        try cancellation.check()
        progress(TransferProgress("提交文件夹 \(local.lastPathComponent)…"))
        try cancellation.check()
        try fs.move(staging, to: path); committed = true
        return UploadResult(backup: nil, warning: nil)
    }
}
