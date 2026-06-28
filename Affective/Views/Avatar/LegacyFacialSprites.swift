//
//  Grid positions for the shared facial-expression sprite vocabulary.
//  Matches AffectiveCore src/core/port_facial_expression.zig.
//

import Foundation

nonisolated enum LegacyFacialSprites {
    struct GridPosition: Equatable {
        let column: Int
        let row: Int
    }

    static let eyeGrid: [String: GridPosition] = [
        "neutral": .init(column: 1, row: 3),
        "stern": .init(column: 1, row: 0),
        "narrow": .init(column: 0, row: 1),
        "surprised": .init(column: 1, row: 1),
        "upward": .init(column: 0, row: 2),
        "concerned": .init(column: 1, row: 2),
        "unfocused": .init(column: 0, row: 3),
        "focused": .init(column: 0, row: 0),
    ]

    static let mouthGrid: [String: GridPosition] = [
        "smile_closed": .init(column: 0, row: 0),
        "smile_teeth": .init(column: 1, row: 0),
        "frown": .init(column: 2, row: 0),
        "kiss": .init(column: 0, row: 1),
        "grimace": .init(column: 1, row: 1),
        "open": .init(column: 2, row: 1),
        "disgust": .init(column: 0, row: 2),
        "smirk": .init(column: 1, row: 2),
        "uneasy_right": .init(column: 2, row: 2),
        "flat": .init(column: 0, row: 3),
        "parted": .init(column: 1, row: 3),
        "neutral_closed": .init(column: 2, row: 3),
    ]
}
