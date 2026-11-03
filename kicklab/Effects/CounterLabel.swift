import Foundation

/// Presentation only: never part of a detection, scoring or analysis-cache key.
nonisolated enum CounterLabel {
    static let defaultText = "Touches"
    static let maximumLength = 24

    static func editable(_ text: String) -> String {
        // Keep a trailing space while typing, but turn pasted paragraphs into one line.
        let singleLine = text.components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        let printable = String(singleLine.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(printable.prefix(maximumLength))
    }

    static func display(_ text: String?) -> String {
        let value = editable(text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? defaultText : value
    }
}
