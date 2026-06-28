//
//  BrainNotificationSounds.swift
//  Affective
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation

@MainActor
final class BrainNotificationSounds {
    static let shared = BrainNotificationSounds()

    private var speechPlayer: AVAudioPlayer?
    private var botActionPlayer: AVAudioPlayer?
    private var speechSoundURL: URL?
    private var botActionSoundURL: URL?
    private var audioSessionConfigured = false
    private var lastBotActionClickPlayedAt: TimeInterval = 0
    private let minimumBotActionClickInterval: TimeInterval = 0.08

    func playSpeechNotification() {
        playSound(named: "speech_notification", player: &speechPlayer, urlCache: &speechSoundURL)
    }

    func playBotActionClick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBotActionClickPlayedAt >= minimumBotActionClickInterval else { return }
        lastBotActionClickPlayedAt = now
        playSound(named: "bot_action_click", player: &botActionPlayer, urlCache: &botActionSoundURL)
    }

    private func activatePlaybackSessionIfNeeded() {
        guard !audioSessionConfigured else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            fatalError("Could not configure audio session for bundled sounds: \(error)")
        }
        #else
        audioSessionConfigured = true
        #endif
    }

    private func bundledSoundURL(named name: String, urlCache: inout URL?) -> URL {
        if let urlCache {
            return urlCache
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            fatalError("Missing bundled sound resource: \(name).mp3")
        }
        urlCache = url
        return url
    }

    private func playSound(named name: String, player: inout AVAudioPlayer?, urlCache: inout URL?) {
        let url = bundledSoundURL(named: name, urlCache: &urlCache)
        activatePlaybackSessionIfNeeded()

        if let existing = player, existing.url == url {
            if existing.isPlaying {
                existing.stop()
            }
            existing.currentTime = 0
            existing.prepareToPlay()
            if existing.play() {
                return
            }
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            player = audioPlayer
            audioPlayer.prepareToPlay()
            guard audioPlayer.play() else {
                fatalError("Could not play bundled sound resource: \(name).mp3")
            }
        } catch {
            fatalError("Could not initialize bundled sound resource \(name).mp3: \(error)")
        }
    }
}
#else
@MainActor
final class BrainNotificationSounds {
    static let shared = BrainNotificationSounds()

    func playSpeechNotification() {}
    func playBotActionClick() {}
}
#endif
