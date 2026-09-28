import Foundation

/// The project's public links. Gauge itself never opens these on its own — only
/// when you click one.
enum Links {
    static let repository = URL(string: "https://github.com/lightwaslost/gauge")!
    static let issues = URL(string: "https://github.com/lightwaslost/gauge/issues/new")!
    static let licence = URL(string: "https://github.com/lightwaslost/gauge/blob/main/LICENSE")!
}
