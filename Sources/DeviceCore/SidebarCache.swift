import Foundation
import CryptoKit

// Accessed only by DeviceSidebarService. Keys include device, OS and app revision.
public final class SidebarCache {
    private struct Entry: Codable { let fingerprint: String; let value: String; let date: Date }
    private let root: URL
    private let scope: String
    private var values: [String: Entry] = [:]
    private var dirty = 0
    public static let permissionLifetime: TimeInterval = 600
    public init(root: URL, device: String, systemVersion: String) {
        self.root = root
        scope = Self.hash(device + "|" + systemVersion)
        if let data = try? Data(contentsOf: permissionURL), data.count <= 4 * 1024 * 1024,
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) { values = stored }
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func fingerprint(_ app: DeviceApp) -> String { Self.hash("\(app.id)|\(app.version)|\(app.applicationType)|\(app.fileSharing)") }
    private var permissionURL: URL { root.appendingPathComponent(scope + ".json") }
    private func iconURL(_ app: DeviceApp) -> URL { root.appendingPathComponent(scope + "-" + fingerprint(app) + ".png") }
    public func availability(_ app: DeviceApp, now: Date = Date()) -> AppAvailability? {
        guard let entry = values[app.id], entry.fingerprint == fingerprint(app),
              now.timeIntervalSince(entry.date) >= 0, now.timeIntervalSince(entry.date) < Self.permissionLifetime else { return nil }
        switch entry.value { case "available": return .available; case "restricted": return .restricted; default: return nil }
    }
    public func record(_ value: AppAvailability, app: DeviceApp, now: Date = Date()) {
        guard value == .available || value == .restricted else { return }
        values[app.id] = Entry(fingerprint: fingerprint(app), value: value == .available ? "available" : "restricted", date: now)
        dirty += 1
        if dirty >= 16 { flush() }
    }
    public func invalidatePermissions() { values = [:]; dirty += 1; flush() }
    public func flush() {
        guard dirty > 0 else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: permissionURL, options: .atomic)
            dirty = 0
        } catch { } // A cache failure never prevents device browsing.
    }
    public func icon(_ app: DeviceApp, now: Date = Date()) -> Data? {
        let url = iconURL(app)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              now.timeIntervalSince(modified) >= 0, now.timeIntervalSince(modified) < 7 * 86400,
              let size = attrs[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url), Self.isPNG(data) else { return nil }
        return data
    }
    public func storeIcon(_ data: Data, app: DeviceApp) {
        guard data.count <= 8 * 1024 * 1024, Self.isPNG(data) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: iconURL(app), options: .atomic)
    }
    public static func isPNG(_ data: Data) -> Bool { data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) }
}
