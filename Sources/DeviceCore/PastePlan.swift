import Foundation

public struct PasteItem: Sendable {
    public let source: URL
    public let target: String
    public let isDirectory: Bool
    public let existing: RemoteEntry?
    public var canReplace: Bool { !isDirectory && existing?.kind == .file }
}

public enum PastePlan {
    // Preflight all names and types before uploading the first item.
    public static func make(urls: [URL], directory: String, entries: [RemoteEntry]) throws -> [PasteItem] {
        try RemotePath.validate(directory)
        var paths = Set<String>(); var names = Set<String>(); var result: [PasteItem] = []
        for url in urls {
            guard url.isFileURL else { throw DeviceFilesError("剪贴板包含非本地文件。") }
            let source = url.standardizedFileURL
            if !paths.insert(source.path).inserted { continue }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw DeviceFilesError("不支持粘贴符号链接或特殊文件：\(source.lastPathComponent)")
            }
            let target = try RemotePath.child(source.lastPathComponent, of: directory)
            guard names.insert(target).inserted else {
                throw DeviceFilesError("剪贴板中有来自不同位置的同名项目：\(source.lastPathComponent)。请分开粘贴。")
            }
            result.append(PasteItem(source: source, target: target, isDirectory: values.isDirectory == true,
                                    existing: entries.first { $0.path == target }))
        }
        guard !result.isEmpty else { throw DeviceFilesError("剪贴板中没有可粘贴的本地文件。") }
        return result
    }
}
