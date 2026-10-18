import Foundation

/// Timing diagnostics use infinity to mean "no observation yet". JSON does not.
/// Preserve those entries as null and list their paths; never change counter data.
nonisolated enum RFDiagnosticJSON {
    static func data(_ report: [String: Any]) throws -> Data {
        var paths = [String]()
        func clean(_ value: Any, path: String) -> Any {
            if let number = value as? NSNumber, !number.doubleValue.isFinite {
                paths.append(path); return NSNull()
            }
            if let values = value as? [String: Any] {
                return values.reduce(into: [String: Any]()) { result, item in
                    result[item.key] = clean(item.value, path: path+"."+item.key)
                }
            }
            if let values = value as? [Any] { return values.enumerated().map { clean($0.element, path: path+"[\($0.offset)]") } }
            return value
        }
        var object = clean(report, path: "report") as! [String: Any]
        object["nonfinite_diagnostic_paths"] = paths.sorted()
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NSError(domain: "RFDiagnosticJSON", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid diagnostic value"])
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
