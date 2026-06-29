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
    private(set) var currentSpeechText: String?
    private var lastCompletedSpeechText: String?
    private var lastCompletedSpeechAt: TimeInterval = 0
    private let duplicateSpeechWindow: TimeInterval = 8

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        speechIsActive
    }

    func shouldSkipDuplicateSpeech(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if speechIsActive, currentSpeechText == trimmed {
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if lastCompletedSpeechText == trimmed, now - lastCompletedSpeechAt < duplicateSpeechWindow {
            return true
        }
        return false
    }

    func speak(_ text: String, preferredVoiceName: String?, completion: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion()
            return
        }

        if speechIsActive {
            synthesizer.stopSpeaking(at: .immediate)
            finishSpeaking(for: currentUtteranceID)
        }
        activateSpeechSessionIfNeeded()
        speechIsActive = true
        self.completion = completion
        currentSpeechText = trimmed
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
            finishSpeaking(for: currentUtteranceID)
            return
        }
        deactivateSpeechSession()
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

    private func activateSpeechSessionIfNeeded() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            fatalError("Could not configure audio session for speech output: \(error)")
        }
        #endif
    }

    private func deactivateSpeechSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            fatalError("Could not deactivate audio session for speech output: \(error)")
        }
        #endif
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
        let spokenText = currentSpeechText
        currentUtteranceID = nil
        currentSpeechText = nil
        speechIsActive = false
        if let spokenText {
            lastCompletedSpeechText = spokenText
            lastCompletedSpeechAt = ProcessInfo.processInfo.systemUptime
        }
        let callback = completion
        completion = nil
        deactivateSpeechSession()
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
