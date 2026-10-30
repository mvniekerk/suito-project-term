import AppKit

/// One major tab: a project, its colour, its directory, and its own tabs.
struct Project: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var directory: String
    /// Index into `ProjectPalette.colors`, so projects stay visually distinct
    /// without the user having to pick anything.
    var colorIndex: Int = 0
    var tabs: [TabSpec] = []
    /// The tab last looked at, so reopening returns to it.
    var selectedTabID: UUID?

    var color: NSColor { ProjectPalette.color(at: colorIndex) }
}

extension Project {
    /// Tolerant decoding, for the same reason as `TabSpec`: a key added in a
    /// later build is absent from an older workspace file, and the synthesised
    /// decoder treats that as an error rather than falling back to the default.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "project"
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
            ?? NSHomeDirectory()
        colorIndex = try container.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        tabs = try container.decodeIfPresent([TabSpec].self, forKey: .tabs) ?? []
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
    }
}

/// Distinct, reasonably accessible accent colours for the project rows.
enum ProjectPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.36, green: 0.61, blue: 0.94, alpha: 1),  // blue
        NSColor(srgbRed: 0.42, green: 0.78, blue: 0.47, alpha: 1),  // green
        NSColor(srgbRed: 0.95, green: 0.60, blue: 0.27, alpha: 1),  // orange
        NSColor(srgbRed: 0.78, green: 0.47, blue: 0.87, alpha: 1),  // violet
        NSColor(srgbRed: 0.93, green: 0.38, blue: 0.45, alpha: 1),  // red
        NSColor(srgbRed: 0.31, green: 0.76, blue: 0.78, alpha: 1),  // teal
        NSColor(srgbRed: 0.90, green: 0.76, blue: 0.33, alpha: 1),  // amber
        NSColor(srgbRed: 0.58, green: 0.56, blue: 0.93, alpha: 1),  // indigo
        NSColor(srgbRed: 0.95, green: 0.50, blue: 0.70, alpha: 1),  // pink
        NSColor(srgbRed: 0.56, green: 0.72, blue: 0.36, alpha: 1),  // lime
    ]

    static func color(at index: Int) -> NSColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
