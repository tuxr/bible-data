import Foundation

extension Versification {
    /// Each mapping file's mapping, in the direction its `<source>-<target>.json` name gives, in scheme order.
    /// `mapping(from:to:)` serves both directions, so it cannot say which one a file stores.
    public static func storedMappings() throws -> [VersificationMapping] {
        try VersificationScheme.allCases.flatMap { source in
            try VersificationScheme.allCases.compactMap { target -> VersificationMapping? in
                let name = "\(source.rawValue)-\(target.rawValue)"
                guard target != source,
                      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "versification") != nil
                else { return nil }
                return try mapping(from: source, to: target)
            }
        }
    }
}
