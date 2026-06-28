//
//  AppleSpeechSpeaker.swift
//  Affective
//
//  Created by OpenAI Codex on 6/24/26.
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation

enum AppleSpeechVoiceCatalog {
    static var names: [String] {
        let availableNames = AVSpeechSynthesisVoice.speechVoices()
            .map(\.name)
            .uniqued()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return availableNames.isEmpty ? builtInVoiceNames : availableNames
    }

    private static let builtInVoiceNames = [
        "Alex",
        "Fred",
        "Samantha",
        "Victoria",
    ]
}

@MainActor
final class AppleSpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private var currentUtteranceID: ObjectIdentifier?
    private var speechIsActive = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        speechIsActive
    }

    func speak(_ text: String, preferredVoiceName: String?, completion: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion()
            return
        }

        if speechIsActive {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speechIsActive = true
        self.completion = completion
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice(named: preferredVoiceName) ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        currentUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        if speechIsActive {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishSpeaking(for: currentUtteranceID)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.finishSpeaking(for: utteranceID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.finishSpeaking(for: utteranceID)
        }
    }

    private func voice(named preferredVoiceName: String?) -> AVSpeechSynthesisVoice? {
        let trimmedName = preferredVoiceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedName.isEmpty else { return nil }

        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            voice.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
                || voice.identifier.localizedCaseInsensitiveContains(trimmedName)
        }
    }

    private func finishSpeaking(for utteranceID: ObjectIdentifier?) {
        guard utteranceID == nil || utteranceID == currentUtteranceID else { return }
        currentUtteranceID = nil
        speechIsActive = false
        let callback = completion
        completion = nil
        callback?()
    }
}
#else
enum AppleSpeechVoiceCatalog {
    static let names = [
        "System Voice",
    ]
}

@MainActor
final class AppleSpeechSpeaker {
    var isSpeaking: Bool { false }

    func speak(_ text: String, preferredVoiceName: String?, completion: @escaping () -> Void) {
        completion()
    }

    func stop() {}
}
#endif

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
