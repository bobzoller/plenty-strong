import Foundation
@testable import TrainingCore

/// Full authored JSON values, never captured resolver output.
enum BranchResolutionFixtureLoader {
    struct Fixture: Codable { var input: BranchResolutionInput; var expected: BranchResolution }
    static func load(named: String) throws -> (input: BranchResolutionInput, expected: BranchResolution) {
        let url = Bundle.module.url(forResource: named, withExtension: "json")!
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return (fixture.input, fixture.expected)
    }
}
