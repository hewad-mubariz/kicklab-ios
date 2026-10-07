import Foundation

/// Background selection is independent of the prepared person/ball cache.
nonisolated enum PreviewEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case classicStadium, indoorArena, urbanCourt, forestCourt, snowField, beachField
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classicStadium: "Classic Stadium"
        case .indoorArena: "Indoor Arena"
        case .urbanCourt: "Urban Court"
        case .forestCourt: "Forest Court"
        case .snowField: "Snow Field"
        case .beachField: "Beach Field"
        }
    }
    var caption: String {
        switch self {
        case .classicStadium: "Floodlights, open sky, and a full-size pitch"
        case .indoorArena: "Warm wall lights and a polished training court"
        case .urbanCourt: "Wet asphalt, teal graffiti, and city lights after dark"
        case .forestCourt: "Worn grass, woodland shade, and warm mountain light"
        case .snowField: "Alpine dusk, powder snow, and bright floodlights"
        case .beachField: "Golden sand, palms, and sunset surf"
        }
    }
    var imageName: String {
        switch self {
        case .classicStadium: "environment-classic"
        case .indoorArena: "environment-indoor"
        case .urbanCourt: "environment-urban"
        case .forestCourt: "environment-forest"
        case .snowField: "environment-snow"
        case .beachField: "environment-beach"
        }
    }
    var accessibilityID: String {
        switch self {
        case .classicStadium: "preview-classic-stadium"
        case .indoorArena: "preview-indoor-arena"
        case .urbanCourt: "preview-urban-court"
        case .forestCourt: "preview-forest-court"
        case .snowField: "preview-snow-field"
        case .beachField: "preview-beach-field"
        }
    }
    var shaderIndex: Float {
        switch self {
        case .classicStadium: 0
        case .indoorArena: 1
        case .urbanCourt: 2
        case .forestCourt: 3
        case .snowField: 4
        case .beachField: 5
        }
    }
}
