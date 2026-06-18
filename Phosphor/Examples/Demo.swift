import Foundation

/// One demo: a name + a source string loaded from a `.metal.txt` resource in
/// the app bundle.
struct Demo: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var source: String

    /// All shipped demos, in display order.
    static let all: [Demo] = {
        let names = [
            "GameOfLife",
            "Plasma",
            "Bloom",
            "Accumulate",
            "Noise",
            "SolidColor",
        ]
        return names.compactMap { name in
            guard
                let url = Bundle.main.url(forResource: name, withExtension: "metal.txt"),
                let source = try? String(contentsOf: url, encoding: .utf8)
            else {
                return nil
            }
            return Demo(name: name, source: source)
        }
    }()
}
