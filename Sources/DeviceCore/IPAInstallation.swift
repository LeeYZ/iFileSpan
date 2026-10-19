import Foundation
import Darwin
import DeviceBridge

public struct IPAPackage: Sendable {
    public let name: String
    public let bundleID: String
    public let version: String
    public let size: UInt64
    let snapshot: URL

    public func discard() { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }

    public static func prepare(_ source: URL, workingDirectory: URL? = nil,
                               cancellation: TransferCancellation = .init(),
                               progress: @Sendable (TransferProgress) -> Void = { _ in }) throws -> IPAPackage {
        guard source.isFileURL, source.pathExtension.lowercased() == "ipa" else {
            throw DeviceFilesError("请选择 .ipa 安装包。")
        }
        try cancellation.check()
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DeviceFilesError("无法打开 IPA，请选择可读取的普通文件。") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_size > 0 else {
            throw DeviceFilesError("IPA 必须是非空的普通文件，不能是文件夹或符号链接。")
        }
        let base = workingDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceFiles/Installations", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: folder) } }
        let snapshot = folder.appendingPathComponent("Package.ipa")
        let outputFD = Darwin.open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard outputFD >= 0 else { throw DeviceFilesError("无法创建安装包临时副本，请检查本地磁盘空间。") }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while true {
            try cancellation.check()
            let data = try input.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            copied += UInt64(data.count)
            guard copied <= UInt64(before.st_size) else { throw DeviceFilesError("IPA 在读取时发生变化，请重新选择。") }
            try output.write(contentsOf: data)
            progress(TransferProgress("正在准备 IPA…", completed: copied, total: UInt64(before.st_size)))
        }
        try output.close()
        var after = stat()
        guard fstat(fd, &after) == 0, copied == UInt64(before.st_size), after.st_size == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw DeviceFilesError("IPA 在读取时发生变化，请重新选择。")
        }
        try cancellation.check()
        progress(TransferProgress("正在检查 IPA…"))
        var pointer: UnsafeMutablePointer<CChar>?
        var count: UInt64 = 0
        try check(df_ipa_info(snapshot.path, &pointer, &count))
        defer { df_free(pointer) }
        guard let pointer, count > 0, count <= 4 * 1024 * 1024 else { throw DeviceFilesError("IPA 应用信息无效。") }
        let metadata = try parseInfo(Data(bytes: pointer, count: Int(count)))
        try cancellation.check()
        prepared = true
        return IPAPackage(name: metadata.name, bundleID: metadata.bundleID, version: metadata.version,
                          size: copied, snapshot: snapshot)
    }

    static func parseInfo(_ data: Data) throws -> (name: String, bundleID: String, version: String) {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty, identifier.count <= 255,
              !identifier.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), !executable.contains("\\"), executable != ".", executable != ".." else {
            throw DeviceFilesError("IPA 的 Info.plist 无效，缺少应用标识符或可执行文件名称。")
        }
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String], !platforms.contains("iPhoneOS") {
            throw DeviceFilesError("该安装包不适用于 iPhone / iPad，可能是模拟器或其他平台的构建。")
        }
        if let type = info["CFBundlePackageType"] as? String, type != "APPL" {
            throw DeviceFilesError("IPA 的主项目不是应用程序。")
        }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? identifier
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "未知版本"
        return (name, identifier, version)
    }
}

public struct IPAInstallationError: LocalizedError, Sendable {
    public let message: String
    public let outcomeUnknown: Bool
    public var errorDescription: String? { message }
}

enum IPAInstallationStatus {
    case progress(String, Int?)
    case complete

    static func parse(_ value: [String: Any]) throws -> IPAInstallationStatus {
        // A terminal error wins even if the same response also says Complete or 100%.
        if let error = value["Error"] {
            let name = error as? String ?? "UnknownInstallError"
            let description = value["ErrorDescription"] as? String ?? "设备拒绝安装此 IPA。"
            let code = (value["ErrorDetail"] as? NSNumber).map { String(format: "（0x%08llX）", $0.uint64Value) } ?? ""
            let lower = (name + description).lowercased()
            let hint = lower.contains("verif") || lower.contains("sign") || lower.contains("provision")
                ? "\n请确认 IPA 的签名与描述文件有效，并允许安装到此设备。" : ""
            throw IPAInstallationError(message: "安装失败：\(name)\(code)\n\(description)\(hint)", outcomeUnknown: false)
        }
        guard let status = value["Status"] as? String, !status.isEmpty else {
            throw IPAInstallationError(message: "设备返回了无效的安装状态。安装结果尚未确认，请在设备上检查。", outcomeUnknown: true)
        }
        if status == "Complete" { return .complete }
        let percent = (value["PercentComplete"] as? NSNumber).map { min(100, max(0, $0.intValue)) }
        return .progress(status, percent)
    }
}

protocol IPAInstallationSession: AnyObject {
    func submit(_ relativePath: String, bundleID: String) throws
    func receive() throws -> [String: Any]?
}

private final class DeviceIPAInstallationSession: IPAInstallationSession {
    let handle: OpaquePointer
    init(udid: String) throws {
        guard let handle = df_installer_new(udid) else { throw bridgeError() }
        self.handle = handle
    }
    deinit { df_installer_free(handle) }
    func submit(_ relativePath: String, bundleID: String) throws { try check(df_installer_start(handle, relativePath, bundleID)) }
    func receive() throws -> [String: Any]? {
        var pointer: UnsafeMutablePointer<CChar>?
        let result = df_installer_receive(handle, &pointer)
        if result == 1 { return nil }
        try check(result)
        guard let value = try plist(pointer) as? [String: Any] else { throw DeviceFilesError("安装状态格式错误。") }
        return value
    }
}

struct IPAInstaller {
    let fs: any RemoteFileSystem
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var idleTimeout: TimeInterval = 300
    var totalTimeout: TimeInterval = 1800

    func install(_ package: IPAPackage, cancellation: TransferCancellation,
                 progress: @Sendable (TransferProgress) -> Void,
                 makeSession: () throws -> any IPAInstallationSession) throws -> String? {
        try cancellation.check()
        let transfer = FileTransfer(fs: fs)
        try transfer.validateDirectory("/")
        if try fs.stat("/PublicStaging") == nil { try fs.mkdir("/PublicStaging") }
        try transfer.validateDirectory("/PublicStaging")
        let folder = "/PublicStaging/iFileSpan-" + UUID().uuidString
        // A collision is never reused or removed.
        guard try fs.stat(folder) == nil else { throw DeviceFilesError("安装暂存目录已存在，请重试。") }
        try fs.mkdir(folder)
        let path = folder + "/Package.ipa"
        var submitted = false
        func cleanup() throws {
            if try fs.stat(path) != nil { try fs.remove(path) }
            if try fs.stat(folder) != nil { try fs.remove(folder) }
        }
        do {
            _ = try transfer.upload(package.snapshot, to: path, replacing: false,
                                    backupRoot: package.snapshot.deletingLastPathComponent(),
                                    cancellation: cancellation, progress: progress)
            let session = try makeSession()
            try cancellation.check()
            progress(TransferProgress("正在提交安装，请保持设备连接…", cancellable: false))
            submitted = true // Even a failed send may have reached the device.
            try session.submit(String(path.dropFirst()), bundleID: package.bundleID)
            let start = now()
            var lastResponse = start
            while true {
                guard now() - lastResponse < idleTimeout, now() - start < totalTimeout else {
                    throw IPAInstallationError(message: "等待设备安装结果超时，结果尚未确认。请在设备上检查该 App 后再操作。", outcomeUnknown: true)
                }
                guard let response = try session.receive() else { continue }
                lastResponse = now()
                switch try IPAInstallationStatus.parse(response) {
                case .complete:
                    do { try cleanup(); return nil }
                    catch { return "设备已确认安装完成，但暂存文件清理失败：\(folder)。请稍后通过共享媒体目录检查。" }
                case .progress(_, let percent):
                    progress(TransferProgress("设备正在安装“\(package.name)”；请勿断开连接…",
                        completed: UInt64(percent ?? 0), total: percent == nil ? 0 : 100,
                        unit: .percent, cancellable: false))
                }
            }
        } catch {
            let uncertain = submitted && (error as? IPAInstallationError)?.outcomeUnknown != false
            if uncertain {
                // The device might still be reading the package. Do not remove it underneath installd.
                throw IPAInstallationError(message: "\(error.localizedDescription)\n安装结果尚未确认，暂存包保留于 \(path)。请先在设备上确认安装结果。", outcomeUnknown: true)
            }
            do { try cleanup() }
            catch let cleanupError {
                throw DeviceFilesError("\(error.localizedDescription)\n安装暂存目录未能清理：\(folder)。\(cleanupError.localizedDescription)")
            }
            throw error
        }
    }
}

extension DeviceService {
    public func prepareIPA(_ source: URL, cancellation: TransferCancellation,
                           progress: @escaping @Sendable (TransferProgress) -> Void) throws -> IPAPackage {
        try IPAPackage.prepare(source, cancellation: cancellation, progress: progress)
    }

    public func installIPA(_ package: IPAPackage, udid: String, cancellation: TransferCancellation,
                           progress: @escaping @Sendable (TransferProgress) -> Void) throws -> String? {
        let fs = try installationFileSystem(udid)
        return try IPAInstaller(fs: fs).install(package, cancellation: cancellation, progress: progress) {
            try DeviceIPAInstallationSession(udid: udid)
        }
    }
}
