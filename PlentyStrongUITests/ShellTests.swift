import XCTest
final class ShellTests: XCTestCase {
    @MainActor func testShellLaunches() { let app = XCUIApplication(); app.launch(); XCTAssertTrue(app.staticTexts["Plenty Strong"].exists) }
}
