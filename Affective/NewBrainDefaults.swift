//
//  NewBrainDefaults.swift
//  Affective
//
//  Loaded from AffectiveCore/fixtures/new_brain_defaults.json (bundled via Resources symlink).
//

import Foundation

enum NewBrainDefaults {
    private struct Payload: Decodable {
        let wants: [String]
        let goals: [String]
    }

    private static let payload: Payload = {
        guard let url = Bundle.main.url(forResource: "new_brain_defaults", withExtension: "json") else {
            fatalError("missing bundled new_brain_defaults.json")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            fatalError("failed to decode new_brain_defaults.json: \(error)")
        }
    }()

    static var wantsLines: [String] { payload.wants }
    static var goalsLines: [String] { payload.goals }

    static var wantsCards: [BrainSeedCard] {
        wantsLines.map { BrainSeedCard(text: $0) }
    }

    static var goalsCards: [BrainSeedCard] {
        goalsLines.map { BrainSeedCard(text: $0) }
    }
}
