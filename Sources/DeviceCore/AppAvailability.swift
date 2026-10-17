import Foundation

public enum AppAvailability: Sendable {
    case checking, available, restricted, unknown
}

public enum AppAvailabilityProbe {
    // A failed connection or locked device is not evidence of app access denial.
    public static func evaluate(open: (Bool) throws -> Void) throws -> AppAvailability {
        var denied = 0
        for container in [true, false] {
            do {
                try open(container)
                return .available
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DeviceFilesError where error.isAccessDenied {
                denied += 1
            } catch { }
        }
        return denied == 2 ? .restricted : .unknown
    }
}

public enum AppListFilter {
    public static func includes(_ app: DeviceApp, availability: AppAvailability?, hideRestrictedApps: Bool,
                                sharingOnly: Bool = false, search: String = "") -> Bool {
        if hideRestrictedApps && (availability == .checking || availability == .restricted) { return false }
        if sharingOnly && !app.fileSharing { return false }
        return search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.id.localizedCaseInsensitiveContains(search)
    }
}
