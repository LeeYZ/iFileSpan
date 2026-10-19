import XCTest
@testable import DeviceCore

private final class FakeInstallationSession: IPAInstallationSession {
    var responses: [[String: Any]?] = [["Status": "Complete"]]
    var submittedPath: String?
    var submittedBundle: String?
    var onSubmit: ((String) -> Void)?
    var receiveCount = 0
    var disconnectWhenEmpty = true
    func submit(_ path: String, bundleID: String) { submittedPath = path; submittedBundle = bundleID; onSubmit?(path) }
    func receive() throws -> [String: Any]? {
        receiveCount += 1
        if !responses.isEmpty { return responses.removeFirst() }
        if disconnectWhenEmpty { throw DeviceFilesError("Disconnected") }
        return nil
    }
}

final class IPAInstallationTests: XCTestCase {
    var temp: URL!
    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["DEVICEFILES_TEST_TEMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        temp = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }
    private var info: [String: Any] {
        ["CFBundleIdentifier": "local.test.example", "CFBundleExecutable": "Example", "CFBundleDisplayName": "示例应用",
         "CFBundleShortVersionString": "1.2.3", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
    }
    private func makeIPA(entries: [(String, Data)]? = nil, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
        let url = temp.appendingPathComponent("Example.ipa")
        try zip(entries ?? [("Payload/Example.app/Info.plist", data), ("Payload/Example.app/Example", Data("executable".utf8))]).write(to: url)
        return url
    }
    private var snapshots: URL { temp.appendingPathComponent("snapshots", isDirectory: true) }
    private func package() throws -> IPAPackage {
        let source = temp.appendingPathComponent("Package.ipa")
        try Data("verified package snapshot".utf8).write(to: source)
        return IPAPackage(name: "Example", bundleID: "local.test.example", version: "1", size: 25, snapshot: source)
    }
    private func assertStagingClean(_ fs: MemoryFS, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fs.files.keys.contains { $0.contains("iFileSpan-") }, file: file, line: line)
        XCTAssertFalse(fs.directories.contains { $0.contains("iFileSpan-") }, file: file, line: line)
    }

    func testPreparesXMLIPAAndKeepsAnIndependentSnapshot() throws {
        let source = try makeIPA()
        let original = try Data(contentsOf: source)
        let package = try IPAPackage.prepare(source, workingDirectory: snapshots)
        XCTAssertEqual(package.name, "示例应用"); XCTAssertEqual(package.bundleID, "local.test.example")
        XCTAssertEqual(package.version, "1.2.3"); XCTAssertEqual(package.size, UInt64(original.count))
        try Data("changed".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: package.snapshot), original)
        package.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.snapshot.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("changed".utf8))
    }
    func testPreparesBinaryPlistIPA() throws {
        let package = try IPAPackage.prepare(makeIPA(format: .binary), workingDirectory: snapshots)
        XCTAssertEqual(package.bundleID, "local.test.example"); package.discard()
    }
    func testPreparesUnicodeAppPath() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        let source = try makeIPA(entries: [("Payload/示例.app/Info.plist", data)])
        let package = try IPAPackage.prepare(source, workingDirectory: snapshots)
        XCTAssertEqual(package.name, "示例应用"); package.discard()
    }
    func testRejectsCorruptArchiveChecksum() throws {
        let source = try makeIPA()
        var data = try Data(contentsOf: source)
        // First entry begins with XML; mutate its contents while retaining the original CRC.
        let offset = 30 + Data("Payload/Example.app/Info.plist".utf8).count
        data[offset + 3] ^= 1
        try data.write(to: source)
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots))
    }
    func testCancellationDuringPreparationCleansPartialSnapshot() throws {
        let source = try makeIPA(); let cancellation = TransferCancellation()
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots, cancellation: cancellation,
                                                   progress: { _ in cancellation.cancel() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshots.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testRejectsNonZIPAndCleansSnapshot() throws {
        let source = temp.appendingPathComponent("bad.ipa"); try Data("not a zip".utf8).write(to: source)
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshots.path), [])
    }
    func testRejectsMissingMainPlist() throws {
        let source = try makeIPA(entries: [("Info.plist", Data("invalid".utf8))])
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots))
    }
    func testRejectsMultipleMainApps() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        let source = try makeIPA(entries: [("Payload/A.app/Info.plist", data), ("Payload/B.app/Info.plist", data)])
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots))
    }
    func testRejectsTraversalPathsWithoutExtractingFiles() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let source = try makeIPA(entries: [("Payload/A.app/Info.plist", data), ("../escaped", Data("bad".utf8))])
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("escaped").path))
    }
    func testRejectsSimulatorPackageAndMissingIdentifier() throws {
        var values = info; values["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        XCTAssertThrowsError(try IPAPackage.parseInfo(PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)))
        values = info; values.removeValue(forKey: "CFBundleIdentifier")
        XCTAssertThrowsError(try IPAPackage.parseInfo(PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)))
    }
    func testRejectsOversizedInfoPlist() throws {
        let source = try makeIPA(entries: [("Payload/A.app/Info.plist", Data(repeating: 0, count: 4 * 1024 * 1024 + 1))])
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots))
    }
    func testRejectsSymbolicLinkSource() throws {
        let source = try makeIPA(); let link = temp.appendingPathComponent("link.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try IPAPackage.prepare(link, workingDirectory: snapshots))
    }
    func testCancelledPreparationDoesNotCreateSnapshot() throws {
        let source = try makeIPA(); let cancellation = TransferCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try IPAPackage.prepare(source, workingDirectory: snapshots, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshots.path))
    }
    func testSuccessfulInstallationCleansOnlyItsOwnStagingFiles() throws {
        let fs = MemoryFS(); fs.directories.insert("/PublicStaging")
        fs.files["/PublicStaging/unrelated.ipa"] = Data("leave intact".utf8)
        let session = FakeInstallationSession()
        let result = try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { session })
        XCTAssertNil(result); XCTAssertTrue(session.submittedPath?.hasPrefix("PublicStaging/iFileSpan-") == true)
        XCTAssertEqual(session.submittedBundle, "local.test.example")
        XCTAssertEqual(fs.files["/PublicStaging/unrelated.ipa"], Data("leave intact".utf8))
        XCTAssertEqual(fs.files["/Documents/state.db"], Data("old database".utf8)); assertStagingClean(fs)
    }
    func testUploadVerificationFailureNeverSubmitsInstallation() throws {
        let fs = MemoryFS(); fs.corruptStagingRead = true; let session = FakeInstallationSession()
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { session }))
        XCTAssertNil(session.submittedPath); assertStagingClean(fs)
    }
    func testCancellationDuringUploadCleansStagingWithoutInstalling() throws {
        let fs = MemoryFS(); let cancellation = TransferCancellation(); let session = FakeInstallationSession()
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: cancellation, progress: { _ in cancellation.cancel() }, makeSession: { session }))
        XCTAssertNil(session.submittedPath); assertStagingClean(fs)
    }
    func testPrecancelledInstallationDoesNotTouchDevice() throws {
        let fs = MemoryFS(); let cancellation = TransferCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: cancellation, progress: { _ in }, makeSession: { FakeInstallationSession() }))
        XCTAssertFalse(fs.directories.contains("/PublicStaging")); XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testRejectsSymbolicLinkStagingParent() throws {
        let fs = MemoryFS(); fs.links.insert("/PublicStaging")
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { FakeInstallationSession() }))
        XCTAssertTrue(fs.removalAttempts.isEmpty)
    }
    func testInstallationServiceConnectionFailureCleansUploadedPackage() throws {
        let fs = MemoryFS()
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { throw DeviceFilesError("Cannot connect") }))
        assertStagingClean(fs)
    }
    func testDeviceErrorWinsOverCompleteAndCleansPackage() throws {
        let fs = MemoryFS(); let session = FakeInstallationSession()
        session.responses = [["Status": "Complete", "Error": "ApplicationVerificationFailed", "ErrorDescription": "Invalid signature", "ErrorDetail": NSNumber(value: 0xe8008015)]]
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { session })) {
            XCTAssertEqual(($0 as? IPAInstallationError)?.outcomeUnknown, false)
            XCTAssertTrue($0.localizedDescription.contains("ApplicationVerificationFailed"))
        }
        assertStagingClean(fs)
    }
    func testPercent100IsNotSuccessAndDisconnectRetainsPackage() throws {
        let fs = MemoryFS(); let session = FakeInstallationSession()
        session.responses = [["Status": "Installing", "PercentComplete": 100]]
        XCTAssertThrowsError(try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { session })) {
            XCTAssertEqual(($0 as? IPAInstallationError)?.outcomeUnknown, true)
        }
        XCTAssertEqual(session.receiveCount, 2)
        XCTAssertNotNil(fs.files["/" + session.submittedPath!])
    }
    func testTimeoutRetainsPackageAndReportsUnknownOutcome() throws {
        let fs = MemoryFS(); let session = FakeInstallationSession(); session.responses = []; session.disconnectWhenEmpty = false
        var ticks = 0.0
        let installer = IPAInstaller(fs: fs, now: { ticks += 1; return ticks }, idleTimeout: 5, totalTimeout: 100)
        XCTAssertThrowsError(try installer.install(package(), cancellation: .init(), progress: { _ in }, makeSession: { session })) {
            XCTAssertEqual(($0 as? IPAInstallationError)?.outcomeUnknown, true)
            XCTAssertTrue($0.localizedDescription.contains("超时"))
        }
        XCTAssertNotNil(fs.files["/" + session.submittedPath!])
    }
    func testCancellationAfterSubmissionDoesNotAbandonDeviceResult() throws {
        let fs = MemoryFS(); let session = FakeInstallationSession(); let cancellation = TransferCancellation()
        session.onSubmit = { _ in cancellation.cancel() }
        XCTAssertNil(try IPAInstaller(fs: fs).install(package(), cancellation: cancellation, progress: { value in
            if !value.cancellable { XCTAssertEqual(value.total, 0) }
        }, makeSession: { session }))
        XCTAssertEqual(session.receiveCount, 1); assertStagingClean(fs)
    }
    func testSuccessfulInstallWithCleanupFailureReturnsWarning() throws {
        let fs = MemoryFS(); let session = FakeInstallationSession()
        session.onSubmit = { path in fs.deniedRemovals.insert("/" + path) }
        let warning = try IPAInstaller(fs: fs).install(package(), cancellation: .init(), progress: { _ in }, makeSession: { session })
        XCTAssertTrue(warning?.contains("已确认安装完成") == true)
    }
    func testMalformedStatusCannotReportSuccess() {
        XCTAssertThrowsError(try IPAInstallationStatus.parse(["PercentComplete": 100])) {
            XCTAssertEqual(($0 as? IPAInstallationError)?.outcomeUnknown, true)
        }
    }

    // Minimal stored ZIP fixtures, so parser tests need no external programs or downloads.
    private func zip(_ entries: [(String, Data)]) -> Data {
        func little(_ value: UInt32, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func crc(_ data: Data) -> UInt32 {
            var result: UInt32 = 0xffffffff
            for byte in data {
                result ^= UInt32(byte)
                for _ in 0..<8 { result = result & 1 == 0 ? result >> 1 : (result >> 1) ^ 0xedb88320 }
            }
            return result ^ 0xffffffff
        }
        var body = Data(), central = Data()
        for (name, data) in entries {
            let filename = Data(name.utf8), checksum = crc(data), offset = UInt32(body.count), size = UInt32(data.count)
            body += little(0x04034b50, 4) + little(20, 2) + little(0x800, 2) + Data(repeating: 0, count: 6)
            body += little(checksum, 4) + little(size, 4) + little(size, 4) + little(UInt32(filename.count), 2) + little(0, 2) + filename + data
            central += little(0x02014b50, 4) + little(0x314, 2) + little(20, 2) + little(0x800, 2) + Data(repeating: 0, count: 6)
            central += little(checksum, 4) + little(size, 4) + little(size, 4) + little(UInt32(filename.count), 2)
            central += Data(repeating: 0, count: 8) + little(0o100644 << 16, 4) + little(offset, 4) + filename
        }
        let end = little(0x06054b50, 4) + little(0, 4) + little(UInt32(entries.count), 2) + little(UInt32(entries.count), 2)
            + little(UInt32(central.count), 4) + little(UInt32(body.count), 4) + little(0, 2)
        return body + central + end
    }
}
