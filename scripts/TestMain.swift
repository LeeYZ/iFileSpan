import XCTest
import Darwin

@main
enum TestMain {
    static func main() {
        let suite = XCTestSuite(name: "iFileSpan Core")
        suite.addTest(XCTestSuite(forTestCaseClass: TransferTests.self))
        suite.addTest(XCTestSuite(forTestCaseClass: IPAInstallationTests.self))
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(2) }
        print("Executed \(result.executionCount) tests; failures: \(result.totalFailureCount)")
        exit(result.hasSucceeded ? 0 : 1)
    }
}
