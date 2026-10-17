import XCTest
import Darwin

@main
enum TestMain {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: TransferTests.self)
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(2) }
        print("Executed \(result.executionCount) tests; failures: \(result.totalFailureCount)")
        exit(result.hasSucceeded ? 0 : 1)
    }
}
